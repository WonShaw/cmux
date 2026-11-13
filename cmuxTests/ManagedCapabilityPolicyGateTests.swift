import CmuxCore
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Each resource owner receives its own forced-preference resolver. No test
/// can replace another test's policy, or bypass the production resolver.
@MainActor
struct ManagedCapabilityPolicyGateTests {
    @Test func theObserverSignalsFileTransferTransitions() throws {
        let suite = "ManagedCapabilityPolicyGateTests.observer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { store, key in
            store.object(forKey: key)
        })
        let center = NotificationCenter()
        let recorder = ChangeSignalRecorder()
        let token = center.addObserver(
            forName: ManagedDevicePolicy.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in recorder.recordChangeSignal() }
        defer { center.removeObserver(token) }
        let observer = ManagedPolicyEnforcementObserver(
            notificationCenter: center,
            capabilityPolicy: resolver
        )
        #expect(recorder.changeSignals == 0)

        // A file-transfer flip is its own transition and tells Settings.
        defaults.set(true, forKey: ManagedDevicePolicyKey.disableFileTransfer.rawValue)
        observer.reevaluate()
        #expect(recorder.changeSignals == 1)
        observer.reevaluate()
        #expect(recorder.changeSignals == 1)

        defaults.removeObject(forKey: ManagedDevicePolicyKey.disableFileTransfer.rawValue)
        observer.reevaluate()
        #expect(recorder.changeSignals == 2)
        withExtendedLifetime(observer) {}
    }

    @Test func settingsVisiblePoliciesPostChangeSignals() throws {
        let suite = "ManagedCapabilityPolicyGateTests.visible.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { store, key in
            store.object(forKey: key)
        })
        let center = NotificationCenter()
        let recorder = ChangeSignalRecorder()
        let token = center.addObserver(
            forName: ManagedDevicePolicy.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in recorder.recordChangeSignal() }
        defer { center.removeObserver(token) }
        let observer = ManagedPolicyEnforcementObserver(
            notificationCenter: center,
            capabilityPolicy: resolver
        )

        // A custom-sidebars push is Settings-visible only.
        defaults.set(true, forKey: ManagedDevicePolicyKey.disableCustomSidebars.rawValue)
        observer.reevaluate()
        #expect(recorder.changeSignals == 1)

        // Lifting it signals again; an unchanged re-check does not.
        defaults.removeObject(forKey: ManagedDevicePolicyKey.disableCustomSidebars.rawValue)
        observer.reevaluate()
        #expect(recorder.changeSignals == 2)
        observer.reevaluate()
        #expect(recorder.changeSignals == 2)
        withExtendedLifetime(observer) {}
    }

    @Test func fileTransferRefusalsAreRecognizable() {
        let error = ManagedFileTransferPolicy.refusalError()
        #expect(ManagedFileTransferPolicy.isRefusal(error))
        #expect(error.domain == "cmux.managedPolicy.fileTransfer")
        #expect(error.localizedDescription == ManagedFileTransferPolicy.disabledMessage)
        #expect(!ManagedFileTransferPolicy.isRefusal(NSError(domain: NSPOSIXErrorDomain, code: 1)))
    }
}

/// Counts Settings change signals posted by the observer.
private final class ChangeSignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var changeSignalCount = 0

    var changeSignals: Int { lock.withLock { changeSignalCount } }

    func recordChangeSignal() { lock.withLock { changeSignalCount += 1 } }
}
