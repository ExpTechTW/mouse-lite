import XCTest
@testable import MouseLite

final class SettingsDatabaseTests: XCTestCase {
    private var folder: URL!
    private var database: SettingsDatabase!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MouseLiteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        database = try SettingsDatabase(url: folder.appendingPathComponent("settings.sqlite3"), readerCount: 3)
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func databaseURL() -> URL { folder.appendingPathComponent("settings.sqlite3") }

    func testUsesWAL() {
        XCTAssertEqual(database.journalMode, "wal")
    }

    func testRoundTripKeepsEverySetting() throws {
        var settings = DeviceSettings(name: "MX Master 3S")
        settings.vertical = ScrollMode.traditional.rawValue
        settings.horizontal = ScrollMode.natural.rawValue
        settings.scrollSpeed = 2.5
        settings.hardwareDPI = 1_600
        settings.pointerDPI = 3_200
        settings.disableAcceleration = true
        settings.buttonActions = ["2": ButtonAction.copy.rawValue, "3": ButtonAction.back.rawValue]

        try database.saveDevice(settings, id: "vendor-1-product-2")

        let loaded = try XCTUnwrap(try database.loadDevices()["vendor-1-product-2"])
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.buttonAction(2), .copy)
        XCTAssertEqual(loaded.buttonAction(3), .back)
    }

    func testSavingReplacesRemovedButtonActions() throws {
        var settings = DeviceSettings(name: "Mouse")
        settings.buttonActions = ["2": ButtonAction.copy.rawValue, "3": ButtonAction.paste.rawValue]
        try database.saveDevice(settings, id: "mouse")

        settings.buttonActions = ["2": ButtonAction.copy.rawValue]
        try database.saveDevice(settings, id: "mouse")

        XCTAssertEqual(try XCTUnwrap(try database.loadDevices()["mouse"]).buttonActions, ["2": ButtonAction.copy.rawValue])
    }

    func testDeletingADeviceAlsoDeletesItsButtons() throws {
        var settings = DeviceSettings(name: "Mouse")
        settings.buttonActions = ["2": ButtonAction.copy.rawValue]
        try database.saveDevice(settings, id: "mouse")

        try database.deleteDevice(id: "mouse")

        XCTAssertTrue(try database.loadDevices().isEmpty)
        let orphans = try database.read { try $0.query("SELECT COUNT(*) FROM button_actions") { $0.int(0) } }
        XCTAssertEqual(orphans.first, 0)
    }

    func testEnabledDefaultsToTrueAndPersists() throws {
        XCTAssertTrue(try database.isEnabled())

        try database.setEnabled(false)
        XCTAssertFalse(try database.isEnabled())

        // A new process reads the same file.
        let reopened = try SettingsDatabase(url: databaseURL(), readerCount: 2)
        XCTAssertFalse(try reopened.isEnabled())
    }

    func testReadersAreReadOnly() {
        XCTAssertThrowsError(try database.read { try $0.run("DELETE FROM devices") })
    }

    func testLegacyImportRunsOnce() throws {
        var legacy = DeviceSettings(name: "Old Mouse")
        legacy.scrollSpeed = 1.5
        XCTAssertTrue(try database.importLegacyDevices(["old": legacy]))

        var replacement = DeviceSettings(name: "Other")
        replacement.scrollSpeed = 3
        XCTAssertFalse(try database.importLegacyDevices(["other": replacement]))

        let loaded = try database.loadDevices()
        XCTAssertEqual(loaded.keys.sorted(), ["old"])
        XCTAssertEqual(loaded["old"]?.scrollSpeed, 1.5)
    }

    func testLegacyImportDoesNotOverwriteExistingRows() throws {
        try database.saveDevice(DeviceSettings(name: "Current"), id: "current")

        XCTAssertFalse(try database.importLegacyDevices(["legacy": DeviceSettings(name: "Legacy")]))
        XCTAssertEqual(try database.loadDevices().keys.sorted(), ["current"])
    }

    /// One writer is serialized on its queue while several readers keep reading; SQLite must never report a lock.
    func testReadersKeepReadingWhileWritesLand() throws {
        let database = database!
        try database.saveDevice(DeviceSettings(name: "Start"), id: "device")

        let group = DispatchGroup()
        let failures = FailureBox()

        for writer in 0..<100 {
            DispatchQueue.global().async(group: group) {
                var settings = DeviceSettings(name: "Write \(writer)")
                settings.scrollSpeed = Double(writer % 5) + 1
                do { try database.saveDevice(settings, id: "device") } catch { failures.record(error) }
            }
        }
        for _ in 0..<400 {
            DispatchQueue.global().async(group: group) {
                do { _ = try database.loadDevices() } catch { failures.record(error) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)

        XCTAssertTrue(failures.values.isEmpty, "\(failures.values)")
        let loaded = try XCTUnwrap(try database.loadDevices()["device"])
        XCTAssertTrue(loaded.name.hasPrefix("Write "), loaded.name)
    }

    func testStoreImportsTheOldEnabledSwitchOnce() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MouseLiteTests-\(UUID().uuidString)"))
        defaults.set(false, forKey: "enabled")

        let store = SettingsStore(database: database, defaults: defaults)
        XCTAssertFalse(store.enabled)
        XCTAssertFalse(try database.isEnabled())

        // A later launch keeps the database value, even if UserDefaults still says otherwise.
        defaults.set(true, forKey: "enabled")
        let relaunched = SettingsStore(database: database, defaults: defaults)
        XCTAssertFalse(relaunched.enabled)
    }

    func testUsageOrdersMostRecentFirst() throws {
        try database.markUsed(id: "old", name: "Old", at: Date(timeIntervalSince1970: 100))
        try database.markUsed(id: "new", name: "New", at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(try database.usageOrder(), ["new", "old"])

        try database.markUsed(id: "old", name: "Old Mouse", at: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(try database.usageOrder(), ["old", "new"])
        XCTAssertEqual(try database.usageOrder().count, 2)
    }

    func testSavingSettingsMarksTheDeviceUsed() throws {
        try database.saveDevice(DeviceSettings(name: "Mouse"), id: "mouse")
        XCTAssertEqual(try database.usageOrder(), ["mouse"])
    }

    func testDeletingADeviceAlsoForgetsItsUsage() throws {
        try database.markUsed(id: "mouse", name: "Mouse")
        try database.deleteDevice(id: "mouse")
        XCTAssertTrue(try database.usageOrder().isEmpty)
    }

    func testUsageCanExistWithoutSettings() throws {
        // A device that was used but never configured shouldn't get a settings row, only a place in the recent list.
        try database.markUsed(id: "plugged-in", name: "Borrowed Mouse")
        XCTAssertTrue(try database.loadDevices().isEmpty)
        XCTAssertEqual(try database.usageOrder(), ["plugged-in"])
    }

    func testStoreCoalescesRapidEditsOffTheMainThread() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MouseLiteTests-\(UUID().uuidString)"))
        let store = SettingsStore(database: database, defaults: defaults)

        for step in 1...20 {
            store.update("mouse", name: "Mouse") { $0.scrollSpeed = Double(step) / 2 }
        }
        XCTAssertEqual(store.settings(for: "mouse")?.scrollSpeed, 10)
        store.flush()
        XCTAssertEqual(try database.loadDevices()["mouse"]?.scrollSpeed, 10)
    }

    func testMigrationFromVersion1SeedsUsage() throws {
        let url = folder.appendingPathComponent("version1.sqlite3")
        try makeVersion1Database(at: url)

        let migrated = try SettingsDatabase(url: url, readerCount: 1)
        XCTAssertEqual(try migrated.usageOrder(), ["legacy"])
        XCTAssertEqual(try migrated.loadDevices()["legacy"]?.scrollSpeed, 1.5)
    }

    func testStoreReadsBackThroughTheDatabase() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MouseLiteTests-\(UUID().uuidString)"))
        let legacy = try JSONEncoder().encode(["legacy": DeviceSettings(name: "Legacy Mouse")])
        defaults.set(legacy, forKey: "deviceSettings")

        let store = SettingsStore(database: database, defaults: defaults)
        XCTAssertEqual(store.settings(for: "legacy")?.name, "Legacy Mouse")

        store.update("legacy", name: "Renamed") { $0.scrollSpeed = 3 }
        XCTAssertEqual(store.settings(for: "legacy")?.scrollSpeed, 3)
        store.flush()
        // The write landed through the writer, and a reader sees the committed row.
        XCTAssertEqual(try database.loadDevices()["legacy"]?.scrollSpeed, 3)

        store.forget("legacy")
        XCTAssertTrue(store.devices.isEmpty)
        store.flush()
        XCTAssertTrue(try database.loadDevices().isEmpty)

        store.enabled = false
        XCTAssertFalse(try database.isEnabled())
    }
}

private func makeVersion1Database(at url: URL) throws {
    let database = try SQLiteConnection(path: url.path, readOnly: false)
    try database.execute("""
        CREATE TABLE devices (
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
        CREATE TABLE button_actions (
            device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
            button INTEGER NOT NULL,
            action TEXT NOT NULL,
            PRIMARY KEY (device_id, button)
        );
        CREATE TABLE settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        PRAGMA user_version = 1;
        """)
    try database.run("""
        INSERT INTO devices (id, name, vertical, horizontal, scroll_speed, hardware_dpi, pointer_dpi,
                             disable_acceleration, updated_at)
        VALUES ('legacy', 'Legacy Mouse', 'system', 'system', 1.5, 800, NULL, 0, 12345)
        """)
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        storage.append(error.localizedDescription)
    }
}
