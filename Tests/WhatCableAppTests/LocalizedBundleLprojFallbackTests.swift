import XCTest
@testable import WhatCable

/// App-target half of the adversarial-review lproj-lowercase finding. See
/// `Tests/WhatCableCoreTests/LocalizedBundleLprojFallbackTests.swift` for the
/// full explanation; this is the same bug, same fix, in `setAppLocale`.
///
/// Red-proof (checked against the unfixed resolver before the lowercased
/// fallback was added): `setAppLocale("zh-Hant")` then
/// `String(localized: "Quit", bundle: _appLocalizedBundle)` returned "Quit"
/// (the English source string) instead of "結束", because the exact-case
/// lookup against the built bundle's lowercased `zh-hant.lproj` folder found
/// nothing and `setAppLocale` fell back to `.module`.
final class LocalizedBundleLprojFallbackTests: XCTestCase {
    func testZhHantResolvesToItsOwnTranslation() {
        defer { setAppLocale("") }
        setAppLocale("zh-Hant")
        let result = String(localized: "Quit", bundle: _appLocalizedBundle)
        XCTAssertEqual(result, "結束")
        XCTAssertNotEqual(result, "Quit")
    }
}
