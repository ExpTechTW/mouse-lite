import Foundation
import CoreGraphics
import ApplicationServices

final class EventTap {
    private let monitor: DeviceMonitor
    private let store = SettingsStore.shared
    private var tap: CFMachPort?
    private var tapThread: Thread?
    private var systemNatural = systemNaturalScrolling()
    private let naturalLock = NSLock()
    private var timer: Timer?
    private var swallowed = Set<Int>()
    private let debug = ProcessInfo.processInfo.environment["MOUSELITE_DEBUG"] != nil

    init(monitor: DeviceMonitor) { self.monitor = monitor }

    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: { _, type, event, ctx in
            Unmanaged<EventTap>.fromOpaque(ctx!).takeUnretainedValue().handle(type: type, event: event)
        }, userInfo: me) else {
            if debug { NSLog("MouseLite: tapCreate failed, AXTrusted=%d", AXIsProcessTrusted() ? 1 : 0) }
            return
        }
        if debug { NSLog("MouseLite: tap created") }
        tap = port
        // The tap gets its own run loop: a busy main thread (menu, SQLite, SwiftUI) must never delay the callback,
        // because macOS disables a tap that times out mid-gesture and can then leave clicks and keys stuck.
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "MouseLite event tap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let value = systemNaturalScrolling()
            self.naturalLock.lock()
            self.systemNatural = value
            self.naturalLock.unlock()
        }
    }

    private var natural: Bool {
        naturalLock.lock(); defer { naturalLock.unlock() }
        return systemNatural
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        switch type {
        case .scrollWheel:
            handleScroll(event)
            return pass
        case .otherMouseDown:
            return handleButtonDown(event) ? nil : pass
        case .otherMouseUp, .otherMouseDragged:
            let n = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard swallowed.contains(n) else { return pass }
            if type == .otherMouseUp { swallowed.remove(n) }
            return nil
        default:
            return pass
        }
    }

    private func handleButtonDown(_ event: CGEvent) -> Bool {
        let n = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        // Not recentDevice(): a trackpad scrolled a moment ago must not hide the mouse whose button this is.
        let device = monitor.buttonDevice()
        let action = device.flatMap { store.settings(for: $0.id) }?.buttonAction(n) ?? .none
        if debug { NSLog("MouseLite button %d: device=%@ action=%@", n, device?.name ?? "nil", action.rawValue) }
        guard store.enabled, action != .none else { return false }
        swallowed.insert(n)
        DispatchQueue.main.async { action.perform() }
        return true
    }

    private func handleScroll(_ event: CGEvent) {
        let device = monitor.recentDevice()
        if debug {
            NSLog("MouseLite scroll: device=%@ continuous=%d dy=%d system=%@ settings=%@",
                  device?.name ?? "nil", event.getIntegerValueField(.scrollWheelEventIsContinuous),
                  event.getIntegerValueField(.scrollWheelEventDeltaAxis1), natural ? "natural" : "traditional",
                  device.flatMap { store.settings(for: $0.id) }.map { "\($0.vertical)/\($0.horizontal)" } ?? "none")
        }
        guard store.enabled, let device, let s = store.settings(for: device.id) else { return }

        let speed = s.scrollSpeed
        let v = (flips(s.verticalMode) ? -1.0 : 1.0) * speed
        let h = (flips(s.horizontalMode) ? -1.0 : 1.0) * speed
        if v != 1 { scale(event, v, .scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1) }
        if h != 1 { scale(event, h, .scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2) }
    }

    private func flips(_ mode: ScrollMode) -> Bool {
        switch mode {
        case .system: return false
        case .natural: return !natural
        case .traditional: return natural
        }
    }

    /// The three delta fields are linked (writing one updates the others), so read all
    /// before writing. A non-zero wheel tick never rounds down to zero, so slowing the
    /// wheel can't swallow single ticks.
    private func scale(_ e: CGEvent, _ factor: Double, _ delta: CGEventField, _ point: CGEventField, _ fixed: CGEventField) {
        let d = e.getIntegerValueField(delta)
        let p = e.getIntegerValueField(point)
        let f = e.getDoubleValueField(fixed)
        func scaled(_ v: Int64) -> Int64 {
            guard v != 0 else { return 0 }
            let r = Int64((Double(v) * factor).rounded(.toNearestOrAwayFromZero))
            return r != 0 ? r : (factor < 0 ? -v.signum() : v.signum())
        }
        e.setIntegerValueField(delta, value: scaled(d))
        e.setIntegerValueField(point, value: scaled(p))
        e.setDoubleValueField(fixed, value: f * factor)
        if debug { NSLog("MouseLite scaled x%.2f: delta %lld -> %lld", factor, d, e.getIntegerValueField(delta)) }
    }
}
