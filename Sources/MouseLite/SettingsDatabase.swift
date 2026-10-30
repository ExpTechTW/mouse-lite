import Foundation

/// Device settings in SQLite, with reads and writes kept apart.
///
/// SQLite's WAL mode allows one writer and any number of readers at the same time, so this keeps a single writer
/// connection on its own serial queue and a small pool of read-only connections, each on its own queue. Every write
/// is a transaction on the writer queue; every read takes the next reader in turn. Readers never block on the writer
/// (they read the last committed snapshot), and the writer never waits for a reader to finish.
final class SettingsDatabase {
    static let schemaVersion: Int32 = 2
    static let defaultReaderCount = min(max(2, ProcessInfo.processInfo.activeProcessorCount / 2), 4)

    let url: URL
    private let writer: SQLiteConnection
    private let writerQueue = DispatchQueue(label: "studio.exptech.mouselite.settings.writer")
    private let readers: [SQLiteConnection]
    private let readerQueues: [DispatchQueue]
    private let lock = NSLock()
    private var nextReader = 0

    init(url: URL, readerCount: Int = SettingsDatabase.defaultReaderCount) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        writer = try SQLiteConnection(path: url.path, readOnly: false)
        do {
            try writer.execute("PRAGMA journal_mode = WAL")
            try writer.execute("PRAGMA synchronous = NORMAL")
            try writer.execute("PRAGMA foreign_keys = ON")
            try writer.execute("PRAGMA wal_autocheckpoint = 512")
            try writer.execute("PRAGMA temp_store = MEMORY")
            try SettingsDatabase.migrate(writer)
        } catch {
            throw error
        }

        let count = max(1, readerCount)
        var readers: [SQLiteConnection] = []
        do {
            for _ in 0..<count {
                readers.append(try SQLiteConnection(path: url.path, readOnly: true))
            }
        } catch {
            throw error
        }
        self.readers = readers
        readerQueues = (0..<count).map { DispatchQueue(label: "studio.exptech.mouselite.settings.reader.\($0)") }
    }

    /// `~/Library/Application Support/MouseLite/settings.sqlite3`.
    static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("MouseLite", isDirectory: true)
        return folder.appendingPathComponent("settings.sqlite3")
    }

    // MARK: - Reads

    /// Runs `body` on the next reader connection. Reads see everything committed before the call; they never wait for
    /// the writer and never block it.
    func read<T>(_ body: (SQLiteConnection) throws -> T) rethrows -> T {
        lock.lock()
        let index = nextReader
        nextReader = (nextReader + 1) % readers.count
        lock.unlock()
        return try readerQueues[index].sync { try body(self.readers[index]) }
    }

    /// Reads the whole settings store. One statement, so devices and their buttons come from the same snapshot.
    func loadDevices() throws -> [String: DeviceSettings] {
        try read { database in
            try database.query("""
                SELECT d.id, d.name, d.vertical, d.horizontal, d.scroll_speed, d.hardware_dpi, d.pointer_dpi,
                       d.disable_acceleration, b.button, b.action
                FROM devices d
                LEFT JOIN button_actions b ON b.device_id = d.id
                ORDER BY d.id, b.button
                """) { row in
                (
                    id: row.string(0) ?? "",
                    name: row.string(1) ?? "",
                    vertical: row.string(2) ?? ScrollMode.system.rawValue,
                    horizontal: row.string(3) ?? ScrollMode.system.rawValue,
                    speed: row.double(4),
                    hardwareDPI: Int(row.int(5)),
                    pointerDPI: row.optionalInt(6),
                    acceleration: row.bool(7),
                    button: row.optionalInt(8),
                    action: row.string(9)
                )
            }
            .reduce(into: [String: DeviceSettings]()) { devices, row in
                var settings = devices[row.id] ?? DeviceSettings(name: row.name)
                settings.name = row.name
                settings.vertical = row.vertical
                settings.horizontal = row.horizontal
                settings.scrollSpeed = row.speed
                settings.hardwareDPI = row.hardwareDPI
                settings.pointerDPI = row.pointerDPI
                settings.disableAcceleration = row.acceleration
                if let button = row.button, let action = row.action {
                    settings.buttonActions[String(button)] = action
                }
                settings.sanitize()
                devices[row.id] = settings
            }
        }
    }

    func value(forSetting key: String) throws -> String? {
        try read { database in
            try database.query("SELECT value FROM settings WHERE key = ?", [.text(key)]) { $0.string(0) ?? "" }.first
        }
    }

    func isEnabled() throws -> Bool {
        try value(forSetting: "enabled").map { $0 == "1" } ?? true
    }

    // MARK: - Writes

    func saveDevice(_ settings: DeviceSettings, id: String) throws {
        try write { database in
            try database.transaction {
                let now = Date().timeIntervalSince1970
                try Self.upsert(database, id: id, settings: settings, at: now)
                // Saving settings is using the device, so it moves to the front of the menu's recent list.
                try Self.touchUsage(database, id: id, name: settings.name, at: now)
            }
        }
    }

    func deleteDevice(id: String) throws {
        try write { database in
            try database.transaction {
                try database.run("DELETE FROM device_usage WHERE id = ?", [.text(id)])
                try database.run("DELETE FROM devices WHERE id = ?", [.text(id)])
            }
        }
    }

    /// Records that a device was used (physical input, or opening it in the app). Usage is separate from settings: a
    /// device that was plugged in once shouldn't keep a settings row, but it should order the recent list.
    func markUsed(id: String, name: String, at date: Date = Date()) throws {
        try write { database in
            try Self.touchUsage(database, id: id, name: name, at: date.timeIntervalSince1970)
        }
    }

    /// Device ids, most recently used first. Read through the reader pool, never the writer.
    func usageOrder() throws -> [String] {
        try read { database in
            try database.query("SELECT id FROM device_usage ORDER BY last_used_at DESC, name") { $0.string(0) ?? "" }
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        try write { database in
            try database.run("INSERT INTO settings (key, value) VALUES ('enabled', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                             [.text(enabled ? "1" : "0")])
        }
    }

    /// Moves the pre-SQLite `deviceSettings` JSON into the database once. Returns true when it imported something.
    @discardableResult
    func importLegacyDevices(_ legacy: [String: DeviceSettings]) throws -> Bool {
        guard !legacy.isEmpty else { return false }
        return try write { database in
            let imported = try database.query("SELECT value FROM settings WHERE key = 'legacyImported'") { $0.string(0) }
                .first == "1"
            let existing = try database.query("SELECT COUNT(*) FROM devices") { $0.int(0) }.first ?? 0
            guard !imported, existing == 0 else { return false }
            try database.transaction {
                let now = Date().timeIntervalSince1970
                for (id, settings) in legacy {
                    try Self.upsert(database, id: id, settings: settings, at: now)
                    try Self.touchUsage(database, id: id, name: settings.name, at: now)
                }
                try database.run("INSERT OR REPLACE INTO settings (key, value) VALUES ('legacyImported', '1')")
            }
            return true
        }
    }

    /// The journal mode, for tests and diagnostics: `wal` once this database has been opened.
    var journalMode: String {
        (try? read { try $0.query("PRAGMA journal_mode") { $0.string(0) ?? "" }.first ?? "" }) ?? ""
    }

    // MARK: - Internals

    @discardableResult
    private func write<T>(_ body: (SQLiteConnection) throws -> T) rethrows -> T {
        try writerQueue.sync { try body(writer) }
    }

    private static func upsert(_ database: SQLiteConnection, id: String, settings: DeviceSettings, at time: TimeInterval) throws {
        try database.run("""
            INSERT INTO devices (id, name, vertical, horizontal, scroll_speed, hardware_dpi, pointer_dpi,
                                 disable_acceleration, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name, vertical = excluded.vertical, horizontal = excluded.horizontal,
                scroll_speed = excluded.scroll_speed, hardware_dpi = excluded.hardware_dpi,
                pointer_dpi = excluded.pointer_dpi, disable_acceleration = excluded.disable_acceleration,
                updated_at = excluded.updated_at
            """, [
                .text(id), .text(settings.name), .text(settings.vertical), .text(settings.horizontal),
                .real(settings.scrollSpeed), .integer(Int64(settings.hardwareDPI)),
                settings.pointerDPI.map { SQLiteValue.integer(Int64($0)) } ?? .null,
                .integer(settings.disableAcceleration ? 1 : 0), .real(time),
            ])
        try database.run("DELETE FROM button_actions WHERE device_id = ?", [.text(id)])
        for (button, action) in settings.buttonActions.sorted(by: { $0.key < $1.key }) {
            guard let number = Int(button) else { continue }
            try database.run("INSERT INTO button_actions (device_id, button, action) VALUES (?, ?, ?)",
                             [.text(id), .integer(Int64(number)), .text(action)])
        }
    }

    private static func touchUsage(_ database: SQLiteConnection, id: String, name: String, at time: TimeInterval) throws {
        try database.run("""
            INSERT INTO device_usage (id, name, last_used_at) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, last_used_at = excluded.last_used_at
            """, [.text(id), .text(name), .real(time)])
    }

    private static func migrate(_ database: SQLiteConnection) throws {
        let version = try database.query("PRAGMA user_version") { $0.int(0) }.first ?? 0
        guard version <= Int64(schemaVersion) else {
            throw SQLiteError(message: "settings database is version \(version), newer than this MouseLite understands (\(schemaVersion))")
        }

        if version < 1 {
            try database.execute("""
                CREATE TABLE IF NOT EXISTS devices (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    vertical TEXT NOT NULL DEFAULT 'system',
                    horizontal TEXT NOT NULL DEFAULT 'system',
                    scroll_speed REAL NOT NULL DEFAULT 1,
                    hardware_dpi INTEGER NOT NULL DEFAULT 800,
                    pointer_dpi INTEGER,
                    disable_acceleration INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS button_actions (
                    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
                    button INTEGER NOT NULL,
                    action TEXT NOT NULL,
                    PRIMARY KEY (device_id, button)
                );
                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                PRAGMA user_version = 1;
                """)
        }

        if version < 2 {
            // Usage lives apart from settings: every device that was ever used orders the menu, while only devices the
            // user configured keep a settings row. Existing settings get the time they were last changed.
            try database.execute("""
                CREATE TABLE IF NOT EXISTS device_usage (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    last_used_at REAL NOT NULL
                );
                INSERT OR IGNORE INTO device_usage (id, name, last_used_at)
                    SELECT id, name, updated_at FROM devices;
                PRAGMA user_version = 2;
                """)
        }
    }
}
