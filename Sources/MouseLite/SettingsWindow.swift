import AppKit
import Combine
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var connected: [PointerDevice] = []
    @Published var selection: String?
}

private struct DeviceRow: Identifiable {
    let id: String
    let name: String
    let connected: Bool
    let trackpad: Bool
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var model: SettingsModel
    @State private var showAbout = false

    private var rows: [DeviceRow] {
        var out = model.connected.map { DeviceRow(id: $0.id, name: $0.name, connected: true, trackpad: $0.isTrackpad) }
        let live = Set(out.map(\.id))
        out += store.devices.filter { !live.contains($0.key) }
            .sorted { $0.value.name < $1.value.name }
            .map { DeviceRow(id: $0.key, name: $0.value.name, connected: false, trackpad: false) }
        return out
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("裝置") {
                    ForEach(rows) { row in
                        SidebarRow(row: row, summary: store.settings(for: row.id)?.summary ?? "跟隨系統")
                            .tag(row.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text("MouseLite \(BuildInfo.current.label)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("關於與診斷") { showAbout = true }
                        .buttonStyle(.link).font(.caption)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        } detail: {
            if let row = rows.first(where: { $0.id == model.selection }) ?? rows.first {
                DeviceDetail(store: store, row: row).id(row.id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "computermouse").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("未偵測到滑鼠或觸控板").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(isPresented: $showAbout) { AboutSheet(devices: model.connected) }
        .onAppear {
            if model.selection == nil {
                model.selection = (rows.first { !$0.trackpad } ?? rows.first)?.id
            }
        }
        .onChange(of: model.selection) { selection in
            guard let selection, let row = rows.first(where: { $0.id == selection }) else { return }
            store.markUsed(selection, name: row.name)
        }
    }
}

private struct AboutSheet: View {
    let devices: [PointerDevice]
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "computermouse")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 64, height: 64)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                Text("MouseLite").font(.title2.weight(.semibold))
                Text("版本 \(BuildInfo.current.label)・\(AppInfo.versionLine)").foregroundStyle(.secondary)
            }

            Form {
                Section("環境") {
                    LabeledContent("系統", value: "\(AppInfo.macOS)・\(AppInfo.chip)")
                }
                Section("權限") {
                    LabeledContent("輔助使用") { status(AppInfo.accessibilityGranted, AppInfo.accessibilityGranted ? "已允許" : "未允許") }
                    LabeledContent("輸入監控") { status(AppInfo.inputMonitoring == "已允許", AppInfo.inputMonitoring) }
                }
                Section("已連接的指標裝置") {
                    if devices.isEmpty {
                        Text("（無）").foregroundStyle(.secondary)
                    } else {
                        ForEach(devices, id: \.id) { LabeledContent($0.name, value: $0.id).monospacedDigit() }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(copied ? "已複製 ✓" : "複製診斷資訊") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppInfo.report(devices: devices), forType: .string)
                    copied = true
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 520)
    }

    private func status(_ ok: Bool, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(text)
        }
    }
}

private struct SidebarRow: View {
    let row: DeviceRow
    let summary: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.trackpad ? "rectangle.and.hand.point.up.left" : "computermouse")
                .font(.system(size: 15))
                .frame(width: 22)
                .foregroundStyle(row.connected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1)
                Text(row.connected ? summary : "未連接・\(summary)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .opacity(row.connected ? 1 : 0.6)
    }
}

private struct DeviceDetail: View {
    @ObservedObject var store: SettingsStore
    let row: DeviceRow
    @State private var tab: Tab = .scroll

    enum Tab: String, CaseIterable, Identifiable {
        case scroll = "捲動", pointer = "指標", buttons = "按鍵"
        var id: String { rawValue }
    }

    private var tabs: [Tab] { row.trackpad ? [.scroll] : Tab.allCases }
    private var current: DeviceSettings { store.settings(for: row.id) ?? DeviceSettings(name: row.name) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if tabs.count > 1 {
                Picker("", selection: $tab) {
                    ForEach(tabs) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                .padding(.bottom, 8)
            }
            Form {
                switch tab {
                case .scroll: scrollSections
                case .pointer: pointerSections
                case .buttons: buttonSections
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: row.trackpad ? "rectangle.and.hand.point.up.left" : "computermouse")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.title2.weight(.semibold))
                HStack(spacing: 5) {
                    Circle().fill(row.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(row.connected ? "已連接" : "未連接").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack {
            Button("重設此裝置") { store.forget(row.id) }
                .disabled(!current.isCustomised)
            Spacer()
            Text("變更會立即套用").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var scrollSections: some View {
        Section {
            Picker("垂直", selection: mode(\.vertical)) { modeOptions }
                .pickerStyle(.segmented)
            Picker("水平", selection: mode(\.horizontal)) { modeOptions }
                .pickerStyle(.segmented)
        } header: {
            Text("滑動方向")
        } footer: {
            Text("系統目前：自然滑動\(systemNaturalScrolling() ? "開" : "關")。在這裡選擇的是這個裝置自己的方向，不會改變系統設定，其他裝置不受影響。")
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }

        Section {
            SpeedRow(title: "滾輪速度", value: binding(\.scrollSpeed))
        } header: {
            Text("捲動速度")
        } footer: {
            Text("1× 為原本速度；小於 1 較慢，大於 1 較快。")
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder private var pointerSections: some View {
        Section {
            DPIRow(title: "指標 DPI", value: pointerDPI, hardware: current.hardwareDPI)
        } header: {
            Text("指標 DPI")
        } footer: {
            Text("調整這個裝置的指標靈敏度，不影響系統「滑鼠」設定。這是依下方的實體 DPI 等比例換算的軟體調整，不會改變滑鼠本身的 DPI。")
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }

        Section {
            HStack {
                Text("目前的實體 DPI")
                Spacer()
                TextField("", value: hardwareDPI, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 72)
                Text("DPI").foregroundStyle(.secondary)
            }
        } header: {
            Text("滑鼠實體 DPI")
        } footer: {
            Text("macOS 無法讀取或更改滑鼠硬體的 DPI，請用滑鼠上的按鈕或廠商軟體設定，再把目前的數值填在這裡，上面的 DPI 才會換算正確。")
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }

        Section {
            Toggle("關閉指標加速", isOn: binding(\.disableAcceleration))
        } header: {
            Text("加速度")
        } footer: {
            Text("關閉後，指標移動距離只和滑鼠移動距離成正比，適合需要精準操作的情境。此功能使用 macOS 私有介面，系統更新後可能失效。")
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder private var buttonSections: some View {
        Section {
            ForEach(RemappableButton.all, id: \.number) { button in
                Picker(button.title, selection: action(button)) {
                    ForEach(Array(ButtonAction.groups.enumerated()), id: \.offset) { index, group in
                        if index > 0 { Divider() }
                        ForEach(group, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
        } header: {
            Text("按鍵動作")
        } footer: {
            Text("選「預設」會維持按鍵原本的行為。")
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }

    private var modeOptions: some View {
        ForEach(ScrollMode.allCases, id: \.self) { Text($0.title).tag($0) }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<DeviceSettings, T>) -> Binding<T> {
        Binding(get: { current[keyPath: keyPath] },
                set: { v in store.update(row.id, name: row.name) { $0[keyPath: keyPath] = v } })
    }

    private var pointerDPI: Binding<Int> {
        Binding(get: { current.effectiveDPI },
                set: { v in store.update(row.id, name: row.name) { $0.pointerDPI = v == $0.hardwareDPI ? nil : v } })
    }

    private var hardwareDPI: Binding<Int> {
        Binding(get: { current.hardwareDPI },
                set: { v in store.update(row.id, name: row.name) { $0.hardwareDPI = v } })   // sanitize() clamps
    }

    private func mode(_ keyPath: WritableKeyPath<DeviceSettings, String>) -> Binding<ScrollMode> {
        Binding(get: { ScrollMode(rawValue: current[keyPath: keyPath]) ?? .system },
                set: { v in store.update(row.id, name: row.name) { $0[keyPath: keyPath] = v.rawValue } })
    }

    private func action(_ button: RemappableButton) -> Binding<ButtonAction> {
        Binding(get: { current.buttonAction(button.number) },
                set: { v in
                    store.update(row.id, name: row.name) {
                        $0.buttonActions[String(button.number)] = v == .none ? nil : v.rawValue
                    }
                })
    }
}

private struct SpeedRow: View {
    let title: String
    @Binding var value: Double

    private static let sliderRange = 0.1...5.0
    private static let typedRange = DeviceSettings.scrollSpeedRange

    /// Log scale keeps 0.5× and 2× symmetric around the default, and snaps to 1× near it.
    private var slider: Binding<Double> {
        Binding(get: { log2(value.clamped(to: Self.sliderRange)) },
                set: { x in
                    var v = pow(2, x)
                    if abs(v - 1) < 0.04 { v = 1 }
                    value = (v * 100).rounded() / 100
                })
    }

    private var typed: Binding<Double> {
        Binding(get: { value }, set: { value = $0.clamped(to: Self.typedRange) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                TextField("", value: typed, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
                Text("×").foregroundStyle(.secondary)
                Button("預設") { value = 1 }
                    .controlSize(.small)
                    .disabled(value == 1)
            }
            HStack(spacing: 8) {
                Text("慢").font(.caption).foregroundStyle(.secondary)
                Slider(value: slider, in: log2(Self.sliderRange.lowerBound)...log2(Self.sliderRange.upperBound))
                Text("快").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DPIRow: View {
    let title: String
    @Binding var value: Int
    let hardware: Int

    private static let presets = [400, 800, 1200, 1600, 2400, 3200, 4800, 6400]

    private var range: ClosedRange<Int> { DeviceSettings.pointerDPIRange(hardware: hardware) }

    private var slider: Binding<Double> {
        Binding(get: { log2(Double(value.clamped(to: range))) },
                set: { x in
                    var v = Int(pow(2, x).rounded())
                    v = (v + 25) / 50 * 50                                        // 50 DPI steps
                    if abs(v - hardware) * 100 < hardware * 4 { v = hardware }    // snap to "no change"
                    value = v.clamped(to: range)
                })
    }

    private var typed: Binding<Int> {
        Binding(get: { value }, set: { value = $0.clamped(to: range) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                TextField("", value: typed, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 72)
                Text("DPI").foregroundStyle(.secondary)
                Menu("常用") {
                    ForEach(Self.presets, id: \.self) { p in
                        Button("\(p) DPI") { value = p.clamped(to: range) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button("預設") { value = hardware }
                    .controlSize(.small)
                    .disabled(value == hardware)
            }
            HStack(spacing: 8) {
                Text("慢").font(.caption).foregroundStyle(.secondary)
                Slider(value: slider, in: log2(Double(range.lowerBound))...log2(Double(range.upperBound)))
                Text("快").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}

private extension Int {
    func clamped(to r: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}

final class SettingsWindowController {
    private var window: NSWindow?

    func show(store: SettingsStore, model: SettingsModel, selecting id: String? = nil) {
        if let id { model.selection = id }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "MouseLite 設定"
            w.contentView = NSHostingView(rootView: SettingsView(store: store, model: model))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

}
