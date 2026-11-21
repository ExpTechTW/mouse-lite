import Foundation
import XCTest
@testable import MouseLite

final class DeviceMonitorTests: XCTestCase {
    private let trackpad = PointerDevice(id: "builtin:trackpad", name: "內建觸控板", isTrackpad: true)
    private let mouse = PointerDevice(id: "2821:6862", name: "ROG OMNI RECEIVER", isTrackpad: false)

    func testButtonTargetPrefersAMouseOverTheTrackpadThatWasJustScrolled() {
        // The trackpad is the most recent input, but a middle/side button can only belong to the mouse.
        let target = DeviceMonitor.buttonTarget(
            among: [trackpad, mouse],
            lastActive: [trackpad.id: 1_000, mouse.id: 970]
        )
        XCTAssertEqual(target?.id, mouse.id)
    }

    func testOnlyATrackpadHasNoButtonTarget() {
        XCTAssertNil(DeviceMonitor.buttonTarget(among: [trackpad], lastActive: [trackpad.id: 1_000]))
    }

    func testTheMostRecentlyUsedMouseWins() {
        let older = PointerDevice(id: "older", name: "Older Mouse", isTrackpad: false)
        let newer = PointerDevice(id: "newer", name: "Newer Mouse", isTrackpad: false)
        let target = DeviceMonitor.buttonTarget(
            among: [older, newer],
            lastActive: [older.id: 10, newer.id: 20]
        )
        XCTAssertEqual(target?.id, newer.id)
    }

    func testDiscreteScrollUsesTheOnlyMouseWithoutRecentDeviceInput() {
        XCTAssertEqual(DeviceMonitor.scrollTarget(among: [trackpad, mouse], recent: nil, isContinuous: false)?.id, mouse.id)
        XCTAssertNil(DeviceMonitor.scrollTarget(among: [trackpad], recent: nil, isContinuous: false))
    }

    func testDiscreteScrollRequiresRecentInputToChooseBetweenMice() {
        let other = PointerDevice(id: "other", name: "Other Mouse", isTrackpad: false)
        XCTAssertNil(DeviceMonitor.scrollTarget(among: [mouse, other], recent: nil, isContinuous: false))
        XCTAssertEqual(DeviceMonitor.scrollTarget(among: [mouse, other], recent: other, isContinuous: false)?.id, other.id)
    }

    func testContinuousScrollKeepsItsRecentDevice() {
        XCTAssertEqual(DeviceMonitor.scrollTarget(among: [trackpad, mouse], recent: trackpad, isContinuous: true)?.id, trackpad.id)
        XCTAssertNil(DeviceMonitor.scrollTarget(among: [trackpad, mouse], recent: nil, isContinuous: true))
    }
}
