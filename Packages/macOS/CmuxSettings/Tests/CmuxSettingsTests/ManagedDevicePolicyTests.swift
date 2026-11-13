import CmuxSettings
import Foundation
import Testing

/// Behavior tests for ``ManagedDevicePolicy``: forced-value resolution,
/// tier-0 precedence over user values, and the channel → release-domain
/// fallback. Forced values cannot be produced without installing a real
/// configuration profile, so the tests drive the injected probe: a key
/// counts as forced when the suite stores it under a `forced.`-prefixed
/// mirror key.
struct ManagedDevicePolicyTests {
    private static let forcedMirrorPrefix = "forced."

    private static let probe: ManagedDevicePolicy.ForcedObjectProbe = { defaults, key in
        defaults.object(forKey: forcedMirrorPrefix + key)
    }

    private func makeSuite(_ label: String) throws -> (UserDefaults, () -> Void) {
        let suiteName = "ManagedDevicePolicyTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func unforcedKeysAreNotEnforcedEvenWhenAUserValueExists() throws {
        let (defaults, cleanup) = try makeSuite("unforced")
        defer { cleanup() }

        // A plain (user-level) write is not a managed policy.
        defaults.set(true, forKey: ManagedDevicePolicyKey.disableFileTransfer.rawValue)
        let policy = ManagedDevicePolicy(
            defaults: defaults,
            releaseDomainDefaults: nil,
            forcedObject: Self.probe
        )

        #expect(!policy.isEnforced(.disableFileTransfer))
        #expect(policy.forcedBool(for: .disableFileTransfer) == nil)
        #expect(!policy.isKeyForcedInAppDomain(ManagedDevicePolicyKey.disableFileTransfer.rawValue))
    }

    @Test func forcedTrueEnforcesThePolicyRegardlessOfUserValue() throws {
        let (defaults, cleanup) = try makeSuite("forcedTrue")
        defer { cleanup() }

        // The user "disagrees" with the profile; the forced value must win.
        defaults.set(false, forKey: ManagedDevicePolicyKey.disableCustomSidebars.rawValue)
        defaults.set(
            true,
            forKey: Self.forcedMirrorPrefix + ManagedDevicePolicyKey.disableCustomSidebars.rawValue
        )
        let policy = ManagedDevicePolicy(
            defaults: defaults,
            releaseDomainDefaults: nil,
            forcedObject: Self.probe
        )

        #expect(policy.isEnforced(.disableCustomSidebars))
        #expect(policy.forcedBool(for: .disableCustomSidebars) == true)
        #expect(policy.isKeyForcedInAppDomain(ManagedDevicePolicyKey.disableCustomSidebars.rawValue))
    }

    @Test func forcedFalseLocksTheKeyWithoutEnforcingThePolicy() throws {
        let (defaults, cleanup) = try makeSuite("forcedFalse")
        defer { cleanup() }

        defaults.set(
            false,
            forKey: Self.forcedMirrorPrefix + ManagedDevicePolicyKey.disableFileTransfer.rawValue
        )
        let policy = ManagedDevicePolicy(
            defaults: defaults,
            releaseDomainDefaults: nil,
            forcedObject: Self.probe
        )

        #expect(!policy.isEnforced(.disableFileTransfer))
        #expect(policy.forcedBool(for: .disableFileTransfer) == false)
        // Still forced: writers must not fight it even though the policy is off.
        #expect(policy.isKeyForcedInAppDomain(ManagedDevicePolicyKey.disableFileTransfer.rawValue))
    }

    @Test func nonBooleanForcedValueDoesNotEnforceThePolicy() throws {
        let (defaults, cleanup) = try makeSuite("nonBoolean")
        defer { cleanup() }

        defaults.set(
            "yes",
            forKey: Self.forcedMirrorPrefix + ManagedDevicePolicyKey.disableFileTransfer.rawValue
        )
        let policy = ManagedDevicePolicy(
            defaults: defaults,
            releaseDomainDefaults: nil,
            forcedObject: Self.probe
        )

        #expect(!policy.isEnforced(.disableFileTransfer))
        #expect(policy.forcedBool(for: .disableFileTransfer) == nil)
        // The key is still forced from a write-suppression standpoint.
        #expect(policy.isKeyForcedInAppDomain(ManagedDevicePolicyKey.disableFileTransfer.rawValue))
    }

    @Test func channelBuildsFallBackToTheReleaseDomain() throws {
        let (appDefaults, appCleanup) = try makeSuite("channelApp")
        defer { appCleanup() }
        let (releaseDefaults, releaseCleanup) = try makeSuite("channelRelease")
        defer { releaseCleanup() }

        releaseDefaults.set(
            true,
            forKey: Self.forcedMirrorPrefix + ManagedDevicePolicyKey.disableFileTransfer.rawValue
        )
        let policy = ManagedDevicePolicy(
            defaults: appDefaults,
            releaseDomainDefaults: releaseDefaults,
            forcedObject: Self.probe
        )

        #expect(policy.isEnforced(.disableFileTransfer))
        // Write suppression is scoped to the app's own domain.
        #expect(!policy.isKeyForcedInAppDomain(ManagedDevicePolicyKey.disableFileTransfer.rawValue))
    }

    @Test func appDomainForcedValueWinsOverTheReleaseDomain() throws {
        let (appDefaults, appCleanup) = try makeSuite("precedenceApp")
        defer { appCleanup() }
        let (releaseDefaults, releaseCleanup) = try makeSuite("precedenceRelease")
        defer { releaseCleanup() }

        let key = ManagedDevicePolicyKey.disableCustomSidebars.rawValue
        appDefaults.set(false, forKey: Self.forcedMirrorPrefix + key)
        releaseDefaults.set(true, forKey: Self.forcedMirrorPrefix + key)
        let policy = ManagedDevicePolicy(
            defaults: appDefaults,
            releaseDomainDefaults: releaseDefaults,
            forcedObject: Self.probe
        )

        #expect(policy.forcedBool(for: .disableCustomSidebars) == false)
        #expect(!policy.isEnforced(.disableCustomSidebars))
    }

    @Test func releaseBuildHasNoFallbackDomain() {
        #expect(ManagedDevicePolicy.defaultReleaseDomainDefaults(
            bundleIdentifier: ManagedDevicePolicy.releasePayloadDomain
        ) == nil)
        #expect(ManagedDevicePolicy.defaultReleaseDomainDefaults(
            bundleIdentifier: "com.comux.app.debug"
        ) != nil)
    }

    @Test func documentedPolicyKeyNamesAreStable() {
        // These strings are the administrator-facing contract documented in
        // docs/managed-device-policies.md; renaming them breaks deployed
        // configuration profiles.
        #expect(ManagedDevicePolicyKey.disableFileTransfer.rawValue == "DisableFileTransfer")
        #expect(ManagedDevicePolicyKey.disableCustomSidebars.rawValue == "DisableCustomSidebars")
        #expect(ManagedDevicePolicyKey.allowStyleKeys.isEmpty)
        #expect(ManagedDevicePolicy.releasePayloadDomain == "com.comux.app")
    }
}
