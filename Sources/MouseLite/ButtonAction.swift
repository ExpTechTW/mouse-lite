import AppKit
import CoreGraphics

struct RemappableButton {
    let number: Int
    let title: String

    static let all = [
        RemappableButton(number: 2, title: "中鍵（滾輪按下）"),
        RemappableButton(number: 3, title: "側鍵：後退"),
        RemappableButton(number: 4, title: "側鍵：前進"),
    ]
}

enum ButtonAction: String, CaseIterable {
    case none, disabled
    case missionControl, spaceLeft, spaceRight
    case playPause
    case copy, paste, back, forward
    case leftClick, rightClick, doubleClick

    var title: String {
        switch self {
        case .none: return "預設（不變）"
        case .disabled: return "停用"
        case .missionControl: return "任務控制"
        case .spaceLeft: return "切換到左邊的桌面"
        case .spaceRight: return "切換到右邊的桌面"
        case .playPause: return "播放／暫停"
        case .copy: return "拷貝 ⌘C"
        case .paste: return "貼上 ⌘V"
        case .back: return "上一頁 ⌘["
        case .forward: return "下一頁 ⌘]"
        case .leftClick: return "左鍵點擊"
        case .rightClick: return "右鍵點擊"
        case .doubleClick: return "按兩下"
        }
    }

    static let groups: [[ButtonAction]] = [
        [.none, .disabled],
        [.missionControl, .spaceLeft, .spaceRight],
        [.playPause],
        [.copy, .paste, .back, .forward],
        [.leftClick, .rightClick, .doubleClick],
    ]

    func perform() {
        switch self {
        case .none, .disabled:
            break
        case .missionControl:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        case .spaceLeft: Self.key(123, .maskControl)    // ⌃←
        case .spaceRight: Self.key(124, .maskControl)   // ⌃→
        case .copy: Self.key(8, .maskCommand)
        case .paste: Self.key(9, .maskCommand)
        case .back: Self.key(33, .maskCommand)          // ⌘[
        case .forward: Self.key(30, .maskCommand)       // ⌘]
        case .playPause: Self.mediaKey(16)              // NX_KEYTYPE_PLAY
        case .leftClick: Self.click(.left, count: 1)
        case .rightClick: Self.click(.right, count: 1)
        case .doubleClick: Self.click(.left, count: 2)
        }
    }

    private static func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func mediaKey(_ key: Int) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                               modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: (key << 16) | (state << 8), data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static func click(_ button: CGMouseButton, count: Int) {
        let loc = CGEvent(source: nil)?.location ?? .zero
        let (down, up): (CGEventType, CGEventType) = button == .left ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
        for i in 1...count {
            for type in [down, up] {
                let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: loc, mouseButton: button)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                e?.post(tap: .cghidEventTap)
            }
        }
    }
}
