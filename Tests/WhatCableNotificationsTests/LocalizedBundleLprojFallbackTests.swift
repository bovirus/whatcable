import XCTest
@testable import WhatCableNotifications

/// Notifications-target half of the adversarial-review lproj-lowercase
/// finding. See `Tests/WhatCableCoreTests/LocalizedBundleLprojFallbackTests.swift`
/// for the full explanation; this is the same bug, same fix, in
/// `setNotificationsLocale`.
///
/// Red-proof (checked against the unfixed resolver before the lowercased
/// fallback was added): `setNotificationsLocale("zh-Hant")` then
/// `String(localized: "Charger connected", bundle: _notificationsLocalizedBundle)`
/// returned "Charger connected" (the English source string) instead of the
/// zh-Hant translation, because the exact-case lookup against the built
/// bundle's lowercased `zh-hant.lproj` folder found nothing and
/// `setNotificationsLocale` fell back to `.module`.
final class LocalizedBundleLprojFallbackTests: XCTestCase {
    func testZhHantResolvesToItsOwnTranslation() {
        defer { setNotificationsLocale("") }
        setNotificationsLocale("zh-Hant")
        let result = String(localized: "Charger connected", bundle: _notificationsLocalizedBundle)
        XCTAssertEqual(result, "充電器已連接")
        XCTAssertNotEqual(result, "Charger connected")
    }
}
