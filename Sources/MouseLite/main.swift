import AppKit
import ApplicationServices
import IOKit.hid
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SettingsStore.shared
    private let monitor = DeviceMonitor()
    private lazy var tap = EventTap(monitor: monitor)
    private let pointer = PointerHID()
    private let model = SettingsModel()
    private let settingsWindow = SettingsWindowController()
    private let updater = Updater()
    private var item: NSStatusItem!
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "MouseLite")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        NSLog("MouseLite: launched, AXTrusted=%d, listenAccess=%d", AXIsProcessTrusted() ? 1 : 0, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.store.flush()
                self?.pointer.restoreAll()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }

        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        store.onDeviceChanged = { [weak self] id in self?.applyPointerSettings(id) }
        monitor.onChange = { [weak self] in
            guard let self else { return }
            self.model.connected = self.monitor.devices
            for id in self.store.devices.keys { self.applyPointerSettings(id) }
        }
        monitor.onUse = { [weak self] device in
            self?.store.markUsed(device.id, name: device.name)
        }
        monitor.start()
        startTapWhenTrusted()
        updater.start()
        if CommandLine.arguments.contains("--settings") { settingsWindow.show(store: store, model: model) }
    }

    func applicationWillTerminate(_ note: Notification) {
        store.flush()
        pointer.restoreAll()
    }

    private func applyPointerSettings(_ id: String) {
        let s = store.settings(for: id)
        pointer.apply(deviceID: id, speed: s?.pointerMultiplier ?? 1, disableAcceleration: s?.disableAcceleration ?? false)
    }

    private func startTapWhenTrusted() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        tap.start()
        // Keep retrying until the tap really exists, so granting permission later just works.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tap.start()
                if self.tap.isRunning { t.invalidate() }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !tap.isRunning {
            let warn = NSMenuItem(title: "⚠️ 需要「輔助使用」權限（點此開啟設定）", action: #selector(openAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let enabled = NSMenuItem(title: "啟用", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = store.enabled ? .on : .off
        menu.addItem(enabled)

        let sys = NSMenuItem(title: "系統自然滑動：\(systemNaturalScrolling() ? "開" : "關")", action: nil, keyEquivalent: "")
        sys.isEnabled = false
        menu.addItem(sys)
        menu.addItem(.separator())

        // At most three devices, the ones used most recently; the rest wait in a submenu.
        let entries = deviceEntries()
        menu.addItem(sectionTitle("裝置"))
        for entry in entries.prefix(3) {
            menu.addItem(deviceItem(id: entry.id, name: entry.name, connected: entry.connected, trackpad: entry.trackpad))
        }
        if entries.count > 3 {
            let more = NSMenuItem(title: "其他裝置（\(entries.count - 3)）", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for entry in entries.dropFirst(3) {
                submenu.addItem(deviceItem(id: entry.id, name: entry.name, connected: entry.connected, trackpad: entry.trackpad))
            }
            more.submenu = submenu
            menu.addItem(more)
        }
        if entries.isEmpty { menu.addItem(sectionTitle("（未偵測到裝置）")) }

        menu.addItem(.separator())
        let advanced = NSMenuItem(title: "進階設定…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        advanced.target = self
        menu.addItem(advanced)
        let login = NSMenuItem(title: "登入時啟動", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        addUpdateItems(to: menu)
        let about = NSMenuItem(title: "關於 MouseLite（\(BuildInfo.current.label)）", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(withTitle: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func addUpdateItems(to menu: NSMenu) {
        guard updater.unavailableReason == nil else { return }
        if let release = updater.available {
            let install = NSMenuItem(title: "安裝更新 \(release.label)…", action: #selector(installUpdate), keyEquivalent: "")
            install.target = self
            install.isEnabled = !updater.isBusy
            menu.addItem(install)
        }
        let check = NSMenuItem(title: updater.menuTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        check.isEnabled = !updater.isBusy
        menu.addItem(check)
        let auto = NSMenuItem(title: "自動檢查更新", action: #selector(toggleAutoUpdates), keyEquivalent: "")
        auto.target = self
        auto.state = updater.preferences.checksAutomatically ? .on : .off
        menu.addItem(auto)
        let prereleases = NSMenuItem(title: "接收測試版", action: #selector(togglePrereleases), keyEquivalent: "")
        prereleases.target = self
        prereleases.state = updater.channel == .prerelease ? .on : .off
        menu.addItem(prereleases)
        menu.addItem(.separator())
    }

    @objc private func checkForUpdates() { updater.check(userInitiated: true) }

    @objc private func installUpdate() { updater.install() }

    @objc private func toggleAutoUpdates() {
        updater.setChecksAutomatically(!updater.preferences.checksAutomatically)
    }

    @objc private func togglePrereleases() {
        updater.setReceivesPrereleases(updater.channel != .prerelease)
    }

    private struct DeviceEntry {
        let id: String
        let name: String
        let connected: Bool
        let trackpad: Bool
    }

    /// Devices in the order the menu shows them: most recently used first, then connected, then saved ones.
    private func deviceEntries() -> [DeviceEntry] {
        let connected = monitor.devices
        let connectedByID = Dictionary(connected.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [DeviceEntry] = []
        var seen = Set<String>()
        for id in store.usageOrder() {
            if let device = connectedByID[id] {
                entries.append(DeviceEntry(id: id, name: device.name, connected: true, trackpad: device.isTrackpad))
                seen.insert(id)
            } else if let settings = store.settings(for: id) {
                entries.append(DeviceEntry(id: id, name: settings.name, connected: false, trackpad: false))
                seen.insert(id)
            }
        }
        for device in connected where !seen.contains(device.id) {
            entries.append(DeviceEntry(id: device.id, name: device.name, connected: true, trackpad: device.isTrackpad))
            seen.insert(device.id)
        }
        for (id, settings) in store.devices.sorted(by: { $0.value.name < $1.value.name }) where !seen.contains(id) {
            entries.append(DeviceEntry(id: id, name: settings.name, connected: false, trackpad: false))
            seen.insert(id)
        }
        return entries
    }

    private func deviceItem(id: String, name: String, connected: Bool, trackpad: Bool) -> NSMenuItem {
        let s = store.settings(for: id)
        let item = NSMenuItem(title: "\(name)\(connected ? "" : "（未連接）")", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: trackpad ? "rectangle.and.hand.point.up.left" : "computermouse", accessibilityDescription: nil)
        if #available(macOS 14.4, *) { item.subtitle = s?.summary ?? "跟隨系統" }

        let sub = NSMenu()
        sub.addItem(sectionTitle("滑動方向"))
        let both = s.flatMap { $0.verticalMode == $0.horizontalMode ? $0.verticalMode : nil } ?? (s == nil ? .system : nil)
        for m in ScrollMode.allCases {
            let i = NSMenuItem(title: m.title, action: #selector(setDirection(_:)), keyEquivalent: "")
            i.target = self
            i.state = m == both ? .on : .off
            i.representedObject = [id, name, m.rawValue]
            sub.addItem(i)
        }
        sub.addItem(.separator())
        let more = NSMenuItem(title: "更多設定…", action: #selector(openSettings(_:)), keyEquivalent: "")
        more.target = self
        more.representedObject = id
        sub.addItem(more)
        item.submenu = sub
        return item
    }

    private func sectionTitle(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func setDirection(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? [String] else { return }
        store.update(p[0], name: p[1]) { s in
            s.vertical = p[2]
            s.horizontal = p[2]
        }
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            let name = store.settings(for: id)?.name ?? monitor.devices.first { $0.id == id }?.name ?? id
            store.markUsed(id, name: name)
        }
        settingsWindow.show(store: store, model: model, selecting: sender.representedObject as? String)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: AppInfo.report(devices: monitor.devices),
                                         attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                                      .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc private func toggleEnabled() { store.enabled.toggle() }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do { if svc.status == .enabled { try svc.unregister() } else { try svc.register() } }
        catch { NSLog("MouseLite: login item change failed: \(error)") }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// Top-level code runs on the main thread; the delegate and the updater are main-actor types.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
