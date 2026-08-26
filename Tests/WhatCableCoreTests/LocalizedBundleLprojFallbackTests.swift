import Testing
import Foundation
@testable import WhatCableCore

/// Adversarial-review finding: SPM lowercases script/region `.lproj` folder
/// names when it copies resources into a built bundle (`zh-Hans.lproj` lands
/// as `zh-hans.lproj`, MEASURED), but `setCoreLocale` was passed the
/// canonical BCP-47 identifier (`zh-Hans`), which `Bundle.url(forResource:
/// withExtension:)` matches with an exact string. The lookup always missed
/// for zh-Hans / zh-Hant / pt-BR, so the language picker silently fell back
/// to English for those three languages.
///
/// Red-proof (checked against the unfixed resolver before the lowercased
/// fallback was added): `setCoreLocale("zh-Hant")` then
/// `String(localized: "Nothing connected", bundle: _coreLocalizedBundle)`
/// returned "Nothing connected" (the English source string) instead of the
/// zh-Hant translation, because the exact-case lookup found nothing and
/// `setCoreLocale` fell back to `.module`.
@Suite("LocalizedBundle lproj lowercase fallback (WhatCableCore)")
struct LocalizedBundleLprojFallbackTests {
    @Test("setCoreLocale(\"zh-Hant\") resolves a key to its zh-Hant translation, not English")
    func zhHantResolvesToItsOwnTranslation() {
        defer { setCoreLocale("") }
        setCoreLocale("zh-Hant")
        let result = String(localized: "Nothing connected", bundle: _coreLocalizedBundle)
        #expect(result == "未連接任何裝置")
        #expect(result != "Nothing connected")
    }
}
