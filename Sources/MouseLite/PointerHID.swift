import Foundation

// Private IOKit SPI (same entry points LinearMouse uses): lets us change pointer properties
// on one HID service instead of the whole system. Property changes last until the device
// reconnects, so we restore baselines on quit.
@_silgen_name("IOHIDEventSystemClientCreate")
private func hidClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatchingMultiple")
private func hidClientSetMatching(_ client: AnyObject, _ matching: CFArray)
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func hidClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func serviceCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientSetProperty")
private func serviceSetProperty(_ service: AnyObject, _ key: CFString, _ value: AnyObject) -> Bool
@_silgen_name("IOHIDServiceClientGetRegistryID")
private func serviceRegistryID(_ service: AnyObject) -> Unmanaged<AnyObject>?

final class PointerHID {
    private static let resolutionKey = "HIDPointerResolution"
    private static let accelTypeKey = "HIDPointerAccelerationType"
    private static let pointerAccelKey = "HIDPointerAcceleration"
    private static let mouseAccelKey = "HIDMouseAcceleration"
    private static let linearKey = "HIDUseLinearScalingMouseAcceleration"

    private struct Baseline {
        var resolution: Int?
        var accel: Int?
        var linear: Int?
    }

    private let client: AnyObject?
    private var baselines: [UInt64: Baseline] = [:]
    // Resolution/linear-scaling are device properties that outlive this process if it is killed,
    // so the originals are remembered per vendor:product and survive a crash.
    private let persistKey = "pointerBaselines"
    private var persisted: [String: [String: Int]]
    private let debug = ProcessInfo.processInfo.environment["MOUSELITE_DEBUG"] != nil

    init() {
        persisted = UserDefaults.standard.dictionary(forKey: "pointerBaselines") as? [String: [String: Int]] ?? [:]
        client = hidClientCreate(kCFAllocatorDefault)?.takeRetainedValue()
        if let client {
            let matching: [[String: Int]] = [
                ["PrimaryUsagePage": 1, "PrimaryUsage": 2],
                ["PrimaryUsagePage": 1, "PrimaryUsage": 1],
            ]
            hidClientSetMatching(client, matching as CFArray)
        }
    }

    private func services(vendor: Int, product: Int) -> [AnyObject] {
        guard let client, let list = hidClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }
        return list.filter {
            property($0, "VendorID") as? Int == vendor && property($0, "ProductID") as? Int == product
                && property($0, Self.resolutionKey) != nil
        }
    }

    private func property(_ s: AnyObject, _ key: String) -> Any? {
        serviceCopyProperty(s, key as CFString)?.takeRetainedValue()
    }

    private func set(_ s: AnyObject, _ key: String, _ value: Int) -> Bool {
        serviceSetProperty(s, key as CFString, value as NSNumber)
    }

    private func accelKey(_ s: AnyObject) -> String {
        if let t = property(s, Self.accelTypeKey) as? String { return t }
        return property(s, Self.pointerAccelKey) != nil ? Self.pointerAccelKey : Self.mouseAccelKey
    }

    func apply(deviceID id: String, speed: Double, disableAcceleration: Bool) {
        let parts = id.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        for s in services(vendor: parts[0], product: parts[1]) {
            guard let reg = serviceRegistryID(s)?.takeUnretainedValue() as? UInt64 else { continue }
            let key = accelKey(s)
            if baselines[reg] == nil {
                let saved = persisted[id]
                let base = Baseline(resolution: saved?["resolution"] ?? property(s, Self.resolutionKey) as? Int,
                                    accel: property(s, key) as? Int,
                                    linear: saved?["linear"] ?? property(s, Self.linearKey) as? Int)
                baselines[reg] = base
                if saved == nil {
                    var entry: [String: Int] = [:]
                    if let r = base.resolution { entry["resolution"] = r }
                    if let l = base.linear { entry["linear"] = l }
                    persisted[id] = entry
                    UserDefaults.standard.set(persisted, forKey: persistKey)
                }
            }
            let base = baselines[reg]!

            if let r = base.resolution {
                let target = speed == 1 ? r : Int((Double(r) / speed).clamped(10 * 65_536, 1995 * 65_536))
                let ok = set(s, Self.resolutionKey, target)
                if debug { NSLog("MouseLite: resolution %d -> %d ok=%d", r, target, ok ? 1 : 0) }
            }

            // Re-write acceleration so a new resolution takes effect (as LinearMouse does).
            if disableAcceleration {
                if base.linear != nil { _ = set(s, Self.linearKey, 1) }
                else { _ = set(s, key, -1 * 65_536) }
            } else {
                if let l = base.linear { _ = set(s, Self.linearKey, l) }
                if let a = base.accel { _ = set(s, key, a) }
            }
            if debug {
                NSLog("MouseLite: now resolution=%@ linear=%@ accel=%@", "\(property(s, Self.resolutionKey) ?? "nil")",
                      "\(property(s, Self.linearKey) ?? "nil")", "\(property(s, key) ?? "nil")")
            }
        }
    }

    func restoreAll() {
        guard let client, let list = hidClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] else { return }
        for s in list {
            guard let reg = serviceRegistryID(s)?.takeUnretainedValue() as? UInt64, let base = baselines[reg] else { continue }
            if let r = base.resolution { _ = set(s, Self.resolutionKey, r) }
            if let l = base.linear { _ = set(s, Self.linearKey, l) }
            if let a = base.accel { _ = set(s, accelKey(s), a) }
        }
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
