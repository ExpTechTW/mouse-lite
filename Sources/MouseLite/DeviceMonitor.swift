import Foundation
import IOKit.hid

struct PointerDevice {
    let id: String
    let name: String
    let isTrackpad: Bool
}

final class DeviceMonitor {
    private var manager: IOHIDManager?
    private var thread: Thread?
    private var running = false
    private let lock = NSLock()
    private var connected: [String: PointerDevice] = [:]
    private var lastActive: [String: CFAbsoluteTime] = [:]
    // Cache the descriptor by the IOHIDDevice object. `touched` runs for every HID report (a 1000 Hz mouse, every
    // trackpad tick); reading six IOHID properties each time starves the main run loop and makes the event tap time
    // out mid-gesture, which leaves macOS ignoring clicks and keys. The descriptor only changes on reconnect.
    private var known: [UnsafeMutableRawPointer: PointerDevice] = [:]
    private var lastMarked: [String: CFAbsoluteTime] = [:]
    var onChange: (() -> Void)?
    /// Called when a device is actually used, throttled to once a minute per device (the receiver writes to SQLite).
    var onUse: ((PointerDevice) -> Void)?

    func start() {
        lock.lock()
        let already = running
        if !already { running = true }
        lock.unlock()
        guard !already else { return }

        // HID callbacks run for every report, including a 1000 Hz mouse. Keep them off the main run loop so a burst of
        // input can never starve the event tap or the UI.
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "MouseLite HID"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    private func run() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let matching: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
            [kIOHIDDeviceUsagePageKey: kHIDPage_Digitizer, kIOHIDDeviceUsageKey: kHIDUsage_Dig_TouchPad],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<DeviceMonitor>.fromOpaque(ctx!).takeUnretainedValue().added(device)
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<DeviceMonitor>.fromOpaque(ctx!).takeUnretainedValue().removed(device)
        }, me)
        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            let device = IOHIDElementGetDevice(IOHIDValueGetElement(value))
            Unmanaged<DeviceMonitor>.fromOpaque(ctx!).takeUnretainedValue().touched(device)
        }, me)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        CFRunLoopRun()
    }

    var devices: [PointerDevice] {
        lock.lock(); defer { lock.unlock() }
        return connected.values.sorted { ($0.isTrackpad ? 1 : 0, $0.name) < ($1.isTrackpad ? 1 : 0, $1.name) }
    }

    func recentDevice(within window: CFTimeInterval = 0.6) -> PointerDevice? {
        lock.lock(); defer { lock.unlock() }
        return recentDeviceLocked(within: window)
    }

    /// The device a middle/side button belongs to.
    ///
    /// A trackpad must not shadow a mouse just because it was scrolled a moment ago: trackpads have no remappable
    /// buttons, and the button that just went down is on the mouse. Pick the most recently active mouse instead.
    func buttonDevice() -> PointerDevice? {
        lock.lock(); defer { lock.unlock() }
        return Self.buttonTarget(among: Array(connected.values), lastActive: lastActive) ?? recentDeviceLocked()
    }

    /// Picks a mouse for a middle/side button, never the trackpad that was just scrolled. Split out so it can be
    /// tested without IOKit.
    static func buttonTarget(among devices: [PointerDevice], lastActive: [String: CFAbsoluteTime]) -> PointerDevice? {
        let mice = devices.filter { !$0.isTrackpad }
        guard !mice.isEmpty else { return nil }
        return mice.max { (lastActive[$0.id] ?? 0) < (lastActive[$1.id] ?? 0) }
    }

    private func recentDeviceLocked(within window: CFTimeInterval = 0.6) -> PointerDevice? {
        let now = CFAbsoluteTimeGetCurrent()
        guard let best = lastActive.filter({ now - $0.value <= window }).max(by: { $0.value < $1.value }) else { return nil }
        return connected[best.key]
    }

    /// Keyboards often expose a secondary mouse collection (macros, media keys), so only
    /// interfaces whose *primary* usage is pointer-like count as pointing devices.
    private func isPointer(_ device: IOHIDDevice) -> Bool {
        let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
        if page == kHIDPage_GenericDesktop { return usage == kHIDUsage_GD_Mouse || usage == kHIDUsage_GD_Pointer }
        return page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_TouchPad
    }

    private func descriptor(_ device: IOHIDDevice) -> PointerDevice {
        func int(_ k: String) -> Int { IOHIDDeviceGetProperty(device, k as CFString) as? Int ?? 0 }
        let raw = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "未知裝置"
        let trackpad = raw.localizedCaseInsensitiveContains("trackpad")
        // Built-in trackpad reports "Apple Internal Keyboard / Trackpad" with no vendor/product ID.
        let name = raw == "Apple Internal Keyboard / Trackpad" ? "內建觸控板" : raw
        let vendor = int(kIOHIDVendorIDKey), product = int(kIOHIDProductIDKey)
        let id = vendor == 0 && product == 0 ? "builtin:\(raw)" : "\(vendor):\(product)"
        return PointerDevice(id: id, name: name, isTrackpad: trackpad)
    }

    private func added(_ device: IOHIDDevice) {
        guard isPointer(device) else { return }
        let d = descriptor(device)
        let key = Unmanaged.passUnretained(device).toOpaque()
        lock.lock(); connected[d.id] = d; known[key] = d; lock.unlock()
        DispatchQueue.main.async { self.onChange?() }
    }

    private func removed(_ device: IOHIDDevice) {
        guard isPointer(device) else { return }
        let d = descriptor(device)
        let key = Unmanaged.passUnretained(device).toOpaque()
        lock.lock()
        connected[d.id] = nil
        lastActive[d.id] = nil
        known[key] = nil
        // A device can expose more than one interface; drop every cached object for this id.
        known = known.filter { $0.value.id != d.id }
        lock.unlock()
        DispatchQueue.main.async { self.onChange?() }
    }

    private func touched(_ device: IOHIDDevice) {
        // No descriptor()/IOHID property reads here: this is the hot path for every HID report.
        let key = Unmanaged.passUnretained(device).toOpaque()
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard let d = known[key] else { lock.unlock(); return }
        lastActive[d.id] = now
        // Usage is persisted, so don't write on every HID report: once a minute per device is plenty for the menu.
        let mark = now - (lastMarked[d.id] ?? 0) >= 60
        if mark { lastMarked[d.id] = now }
        lock.unlock()
        if mark { DispatchQueue.main.async { self.onUse?(d) } }
    }
}
