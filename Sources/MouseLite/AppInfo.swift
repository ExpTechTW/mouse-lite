import ApplicationServices
import Foundation
import IOKit.hid

enum AppInfo {
    private static func plist(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }

    static var version: String { plist("CFBundleShortVersionString") ?? "dev" }
    static var label: String { BuildInfo.current.label }
    static var build: String { plist("CFBundleVersion") ?? "-" }
    static var versionLine: String { "\(version) (\(build))" }

    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var chip: String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel"
        #endif
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static var inputMonitoring: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "已允許"
        case kIOHIDAccessTypeDenied: return "已拒絕"
        default: return "尚未決定"
        }
    }

    /// Plain-text block users can paste into a bug report.
    static func report(devices: [PointerDevice]) -> String {
        var lines = [
            "MouseLite \(versionLine)・\(label)",
            "\(macOS) · \(chip)",
            "輔助使用：\(accessibilityGranted ? "已允許" : "未允許")",
            "輸入監控：\(inputMonitoring)",
            "已連接的指標裝置：",
        ]
        lines += devices.isEmpty ? ["  （無）"] : devices.map { "  \($0.name)  [\($0.id)]\($0.isTrackpad ? " 觸控板" : "")" }
        return lines.joined(separator: "\n")
    }
}
