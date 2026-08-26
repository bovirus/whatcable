import XCTest
@testable import WhatCable

/// Proves `NotificationManager.foldLabelledCables(from:)` returns `nil`
/// ("feature unavailable") in exactly the two cases production relies on:
/// zero providers registered (the public-mirror build), and providers
/// registered but every one of them returning nil (Pro locked). Neither
/// case may collapse to `[:]` ("available, zero labelled cables"): that
/// collapse is the bug issue #570's review finding 1 exists to prevent (a
/// licence transition mid-session would otherwise read, to the sequencer's
/// diff, as every attached labelled cable disconnecting or appearing at
/// once).
///
/// Tests a free function taking the provider list as a plain argument,
/// not `PluginRegistry.shared` directly: `PluginRegistry` is an
/// append-only global singleton with no way to reset registrations
/// between tests, so an isolated "zero providers registered" assertion
/// against the live registry would be order-dependent on whatever else in
/// the same test process happened to call `bootstrapPlugins` first.
/// `NotificationManager.foldLabelledCables(from:)` was extracted from the
/// `currentLabelledCables` closure in `NotificationManager.init` for
/// exactly this reason.
@MainActor
final class NotificationManagerLabelledCableFoldTests: XCTestCase {
    /// Zero providers (the public-mirror build's shape: nothing registers
    /// `notificationCableLabelProvider` at all) must fold to nil, not `[:]`.
    func testZeroProvidersFoldsToNilNotEmptyDictionary() {
        let result = NotificationManager.foldLabelledCables(from: [])
        XCTAssertNil(result)
    }

    /// One registered provider returning nil (Pro locked, or the
    /// provider's own live read found nothing) must fold to nil, not
    /// `[:]`: the same "unavailable" state as zero providers, reached a
    /// different way.
    func testSingleRegisteredProviderReturningNilFoldsToNil() {
        let result = NotificationManager.foldLabelledCables(from: [{ nil }])
        XCTAssertNil(result)
    }

    /// Multiple registered providers all returning nil must also fold to
    /// nil: "every provider is unavailable" is still "the feature is
    /// unavailable", not "available, empty".
    func testAllRegisteredProvidersReturningNilFoldsToNil() {
        let result = NotificationManager.foldLabelledCables(from: [{ nil }, { nil }])
        XCTAssertNil(result)
    }

    /// A provider that actually returns `[:]` (unlocked, but nothing
    /// currently attributes) is the genuine "available, empty" state and
    /// must be preserved as `[:]`, distinct from the nil cases above.
    func testProviderReturningEmptyDictionaryFoldsToEmptyDictionaryNotNil() {
        let result = NotificationManager.foldLabelledCables(from: [{ [:] }])
        XCTAssertEqual(result, [:])
    }

    /// One provider contributing real values, mixed with another that
    /// returns nil, folds to the contributed values (the nil-returning
    /// provider is skipped, not treated as poisoning the whole fold).
    func testOneAvailableProviderAmongNilOnesContributesItsValues() {
        let result = NotificationManager.foldLabelledCables(from: [
            { nil },
            { ["cable-1": "Office cable"] }
        ])
        XCTAssertEqual(result, ["cable-1": "Office cable"])
    }
}
