import Combine
import Foundation

enum ScrollMode: String, CaseIterable {
    case system, natural, traditional

    var title: String {
        switch self {
        case .system: return "跟隨系統"
        case .natural: return "自然滑動：開"
        case .traditional: return "自然滑動：關"
        }
    }
}

struct DeviceSettings: Codable, Equatable {
    var name: String
    var vertical: String = ScrollMode.system.rawValue
    var horizontal: String = ScrollMode.system.rawValue
    var scrollSpeed: Double = 1
    // macOS can't read or change a mouse's hardware DPI. The user states what the mouse is set to
    // (hardwareDPI) and the DPI they want (pointerDPI); the ratio is applied in software.
    var hardwareDPI: Int = 800
    var pointerDPI: Int?               // nil = leave the pointer speed alone
    var disableAcceleration: Bool = false
    var buttonActions: [String: String] = [:]

    var effectiveDPI: Int { pointerDPI ?? hardwareDPI }
    var pointerMultiplier: Double { pointerDPI.map { Double($0) / Double(max(hardwareDPI, 1)) } ?? 1 }

    func buttonAction(_ button: Int) -> ButtonAction {
        buttonActions[String(button)].flatMap(ButtonAction.init(rawValue:)) ?? .none
    }

    var verticalMode: ScrollMode { ScrollMode(rawValue: vertical) ?? .system }
    var horizontalMode: ScrollMode { ScrollMode(rawValue: horizontal) ?? .system }

    init(name: String) { self.name = name }

    // Hand-written so settings saved by earlier versions (without the new keys) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        vertical = try c.decodeIfPresent(String.self, forKey: .vertical) ?? ScrollMode.system.rawValue
        horizontal = try c.decodeIfPresent(String.self, forKey: .horizontal) ?? ScrollMode.system.rawValue
        scrollSpeed = try c.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? 1
        hardwareDPI = try c.decodeIfPresent(Int.self, forKey: .hardwareDPI) ?? 800
        pointerDPI = try c.decodeIfPresent(Int.self, forKey: .pointerDPI)
        disableAcceleration = try c.decodeIfPresent(Bool.self, forKey: .disableAcceleration) ?? false
        buttonActions = try c.decodeIfPresent([String: String].self, forKey: .buttonActions) ?? [:]
        sanitize()
    }

    static let scrollSpeedRange = 0.1...10.0
    static let hardwareDPIRange = 100...30_000

    /// Reachable pointer DPI. The OS-side resolution can only be scaled so far (0.2x ... 16x).
    static func pointerDPIRange(hardware: Int) -> ClosedRange<Int> {
        max(50, hardware / 5)...min(hardware * 16, 30_000)
    }

    mutating func sanitize() {
        let s = scrollSpeed.isFinite ? scrollSpeed : 1
        scrollSpeed = min(max(s, Self.scrollSpeedRange.lowerBound), Self.scrollSpeedRange.upperBound)
        hardwareDPI = min(max(hardwareDPI, Self.hardwareDPIRange.lowerBound), Self.hardwareDPIRange.upperBound)
        if let dpi = pointerDPI {
            let r = Self.pointerDPIRange(hardware: hardwareDPI)
            let clamped = min(max(dpi, r.lowerBound), r.upperBound)
            pointerDPI = clamped == hardwareDPI ? nil : clamped
        }
    }

    var isCustomised: Bool {
        verticalMode != .system || horizontalMode != .system || scrollSpeed != 1 || pointerMultiplier != 1
            || disableAcceleration || RemappableButton.all.contains { buttonAction($0.number) != .none }
    }

    var summary: String {
        guard isCustomised else { return "跟隨系統" }
        var parts: [String] = []
        if verticalMode != .system || horizontalMode != .system {
            parts.append(verticalMode == horizontalMode ? verticalMode.title
                         : "垂直 \(verticalMode.title)／水平 \(horizontalMode.title)")
        }
        if scrollSpeed != 1 { parts.append("捲動 \(String(format: "%g×", scrollSpeed))") }
        if pointerMultiplier != 1 { parts.append("指標 \(effectiveDPI) DPI") }
        if disableAcceleration { parts.append("無加速") }
        if RemappableButton.all.contains(where: { buttonAction($0.number) != .none }) { parts.append("按鍵已自訂") }
        return parts.joined(separator: "・")
    }
}

/// The device settings the UI observes. Writes are coalesced per device and run off the main thread on one serial
/// queue; reads always go through the database's read-only pool. After a batch commits, the store reloads the rows and
/// replaces `devices` only if no newer edit is waiting, so the UI never shows a value older than the one just typed.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    /// The JSON key the pre-SQLite versions used.
    private static let legacyKey = "deviceSettings"

    private enum PendingChange {
        case save(DeviceSettings)
        case delete
    }

    private let database: SettingsDatabase?
    @Published private(set) var devices: [String: DeviceSettings]
    var onDeviceChanged: ((String) -> Void)?
    private var enabledCache = true
    private(set) var storageError: String?

    private let ioQueue = DispatchQueue(label: "studio.exptech.mouselite.settings.store", qos: .utility)
    private let stateLock = NSLock()
    // The event tap reads settings from its own thread now, so `devices` is only touched under this lock.
    private let devicesLock = NSLock()
    private var pending: [String: PendingChange] = [:]
    private var drainScheduled = false
    private var generation = 0

    init(database: SettingsDatabase? = nil, defaults: UserDefaults = .standard) {
        let database = database ?? Self.openDefaultDatabase()
        self.database = database

        var loaded: [String: DeviceSettings] = [:]
        var failure: String?
        if let database {
            do {
                // One-time import of settings saved by earlier versions.
                if let data = defaults.data(forKey: Self.legacyKey),
                   let legacy = try? JSONDecoder().decode([String: DeviceSettings].self, from: data) {
                    try database.importLegacyDevices(legacy)
                }
                // The old app kept the on/off switch next to the JSON, not inside it.
                if let legacyEnabled = defaults.object(forKey: "enabled") as? Bool,
                   try database.value(forSetting: "enabled") == nil {
                    try database.setEnabled(legacyEnabled)
                }
                loaded = try database.loadDevices()
                enabledCache = try database.isEnabled()
            } catch {
                failure = error.localizedDescription
                NSLog("MouseLite: settings database failed: %@", error.localizedDescription)
            }
        } else {
            failure = "無法開啟設定資料庫"
        }
        devices = loaded
        storageError = failure
    }

    var enabled: Bool {
        get {
            stateLock.lock(); defer { stateLock.unlock() }
            return enabledCache
        }
        set {
            stateLock.lock()
            enabledCache = newValue
            stateLock.unlock()
            guard let database else { return }
            do {
                try database.setEnabled(newValue)
                storageError = nil
            } catch {
                storageError = error.localizedDescription
                NSLog("MouseLite: writing enabled failed: %@", error.localizedDescription)
            }
        }
    }

    func settings(for id: String) -> DeviceSettings? {
        devicesLock.lock(); defer { devicesLock.unlock() }
        return devices[id]
    }

    func update(_ id: String, name: String, _ change: (inout DeviceSettings) -> Void) {
        devicesLock.lock()
        var s = devices[id] ?? DeviceSettings(name: name)
        s.name = name
        change(&s)
        s.sanitize()
        devices[id] = s
        devicesLock.unlock()
        enqueue(.save(s), for: id)
        onDeviceChanged?(id)
    }

    func forget(_ id: String) {
        devicesLock.lock()
        devices[id] = nil
        devicesLock.unlock()
        enqueue(.delete, for: id)
        onDeviceChanged?(id)
    }

    /// Marks a device used (physical input, or opening it in the app), which orders the menu's recent list.
    func markUsed(_ id: String, name: String) {
        guard let database else { return }
        do {
            try database.markUsed(id: id, name: name)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            NSLog("MouseLite: marking a device used failed: %@", error.localizedDescription)
        }
    }

    /// Device ids, most recently used first, read through a reader connection.
    func usageOrder() -> [String] {
        guard let database, let order = try? database.usageOrder() else { return [] }
        return order
    }

    /// Waits for queued writes. Call before the process exits, and in tests before reading the database.
    func flush() {
        ioQueue.sync {}
    }

    private func enqueue(_ change: PendingChange, for id: String) {
        guard database != nil else { return }
        stateLock.lock()
        pending[id] = change
        generation += 1
        let schedule = !drainScheduled
        if schedule { drainScheduled = true }
        stateLock.unlock()
        if schedule { ioQueue.async { [weak self] in self?.drain() } }
    }

    private func drain() {
        stateLock.lock()
        let changes = pending
        pending.removeAll()
        let batch = generation
        drainScheduled = false
        stateLock.unlock()

        guard let database else { return }
        var failure: String?
        for (id, change) in changes {
            do {
                switch change {
                case .save(let settings): try database.saveDevice(settings, id: id)
                case .delete: try database.deleteDevice(id: id)
                }
            } catch {
                failure = error.localizedDescription
            }
        }

        var loaded: [String: DeviceSettings]?
        do {
            loaded = try database.loadDevices()
        } catch {
            failure = failure ?? error.localizedDescription
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let current = self.pending.isEmpty && self.generation == batch
            self.stateLock.unlock()
            // A newer edit is already on screen; its drain publishes the reloaded rows instead.
            if current, let loaded {
                self.devicesLock.lock()
                self.devices = loaded
                self.devicesLock.unlock()
            }
            if let failure {
                self.storageError = failure
                NSLog("MouseLite: saving settings failed: %@", failure)
            } else {
                self.storageError = nil
            }
        }
    }

    private static func openDefaultDatabase() -> SettingsDatabase? {
        do {
            return try SettingsDatabase(url: SettingsDatabase.defaultURL())
        } catch {
            NSLog("MouseLite: cannot open settings database: %@", error.localizedDescription)
            return nil
        }
    }
}

func systemNaturalScrolling() -> Bool {
    let v = CFPreferencesCopyValue("com.apple.swipescrolldirection" as CFString,
                                   kCFPreferencesAnyApplication,
                                   kCFPreferencesCurrentUser,
                                   kCFPreferencesAnyHost)
    return (v as? Bool) ?? true
}
