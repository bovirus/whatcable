import XCTest
import WhatCableCore
@testable import WhatCableNotifications

/// Codex review finding 3's second half: direct rendering assertions for the
/// saved-cable-label composition key (`"%@ (%@)"`, added in
/// `Sources/WhatCableNotifications/Resources/*/Localizable.strings`) under
/// ja, zh-Hans, and zh-Hant. These double as regression tests for the
/// fullwidth-parentheses variant: ja / zh-Hans / zh-Hant all translate the
/// key as `"%1$@（%2$@）"` (fullwidth parens), which must actually render,
/// not just parse.
final class NotificationCableLabelCompositionLocalisationTests: XCTestCase {
    private func snapshot(id: UInt64, name: String) -> USBDeviceChangeGrouper.Snapshot {
        USBDeviceChangeGrouper.Snapshot(id: id, locationID: 0x0110_0000, name: name)
    }

    /// Red-proof: comment out `"%@ (%@)"` from `ja.lproj/Localizable.strings`
    /// (checked directly, then restored). `applyCableLabel` (reached via
    /// `addedNotificationContents`) falls back to the raw, untranslated
    /// interpolation `"Connected: SSD Enclosure (Office cable)"` -- ASCII
    /// parens, not fullwidth -- so a title assertion pinned to the fullwidth
    /// form goes red exactly the way a genuinely missing translation would.
    func testJapaneseUsesFullwidthParentheses() {
        defer { setNotificationsLocale("") }
        setNotificationsLocale("ja")
        let (added, _) = USBDeviceChangeGrouper.diff(previous: [], current: [snapshot(id: 1, name: "SSD Enclosure")])
        let contents = WhatCableCoreNotificationDecisionShim.addedContents(groups: added, cableLabel: "Office cable")
        XCTAssertEqual(contents.first?.title, "接続中: SSD Enclosure（Office cable）")
    }

    func testSimplifiedChineseUsesFullwidthParentheses() {
        defer { setNotificationsLocale("") }
        setNotificationsLocale("zh-Hans")
        let (added, _) = USBDeviceChangeGrouper.diff(previous: [], current: [snapshot(id: 1, name: "SSD Enclosure")])
        let contents = WhatCableCoreNotificationDecisionShim.addedContents(groups: added, cableLabel: "Office cable")
        XCTAssertEqual(contents.first?.title, "已连接：SSD Enclosure（Office cable）")
    }

    func testTraditionalChineseUsesFullwidthParentheses() {
        defer { setNotificationsLocale("") }
        setNotificationsLocale("zh-Hant")
        let (added, _) = USBDeviceChangeGrouper.diff(previous: [], current: [snapshot(id: 1, name: "SSD Enclosure")])
        let contents = WhatCableCoreNotificationDecisionShim.addedContents(groups: added, cableLabel: "Office cable")
        XCTAssertEqual(contents.first?.title, "已連接：SSD Enclosure（Office cable）")
    }

    /// English stays the ASCII-parens form, unaffected by the fix above:
    /// pins that the fallback path (the identifier-as-given lookup that
    /// finds `en.lproj` directly, no lowercasing needed) is unchanged.
    func testEnglishKeepsAsciiParentheses() {
        defer { setNotificationsLocale("") }
        setNotificationsLocale("en")
        let (added, _) = USBDeviceChangeGrouper.diff(previous: [], current: [snapshot(id: 1, name: "SSD Enclosure")])
        let contents = WhatCableCoreNotificationDecisionShim.addedContents(groups: added, cableLabel: "Office cable")
        XCTAssertEqual(contents.first?.title, "Connected: SSD Enclosure (Office cable)")
    }
}

/// Thin passthrough so this file doesn't need to know `NotificationDecision`'s
/// full `addedNotificationContents` signature (it also takes a
/// `thunderboltInvolved` default and a `singleDeviceBody` closure this test
/// doesn't care about).
private enum WhatCableCoreNotificationDecisionShim {
    static func addedContents(
        groups: [USBDeviceChangeGrouper.ChangeGroup],
        cableLabel: String?
    ) -> [NotificationContent] {
        NotificationDecision.addedNotificationContents(groups: groups, cableLabel: cableLabel) { _ in nil }
    }
}
