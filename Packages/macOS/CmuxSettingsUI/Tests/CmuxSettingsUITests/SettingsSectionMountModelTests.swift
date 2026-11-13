import SwiftUI
import Testing
@testable import CmuxSettingsUI

/// Progressive section mounting for the settings window
/// (https://github.com/manaflow-ai/cmux/issues/12134): one section in the
/// first pass, one more per appearance, navigation mounts on demand.
@MainActor
@Suite("SettingsSectionMountModel")
struct SettingsSectionMountModelTests {
    private let order: [SettingsSectionID] = [.sleepyMode, .app, .terminal, .textBox, .reset]

    @Test func displayOrderGivesEverySectionASlot() {
        let slots = Set(SettingsSectionMountModel.displayOrder)
        #expect(slots.count == SettingsSectionMountModel.displayOrder.count)
        #expect(slots == Set(SettingsSectionID.allCases))
    }

    @Test func firstPassMountsOnlyTheInitialSection() {
        let model = SettingsSectionMountModel(initial: .terminal, order: order)
        #expect(model.mounted == [.terminal])
        #expect(model.isMounted(.terminal))
        #expect(!model.isMounted(.sleepyMode))
        #expect(!model.isComplete)
    }

    @Test func eachAppearanceMountsExactlyOneMoreSectionInDisplayOrder() {
        let model = SettingsSectionMountModel(initial: .terminal, order: order)
        var mountedInOrder: [SettingsSectionID] = []
        var current: SettingsSectionID? = .terminal
        while let section = current {
            current = model.sectionDidAppear(section)
            if let current { mountedInOrder.append(current) }
        }
        #expect(mountedInOrder == [.sleepyMode, .app, .textBox, .reset])
        #expect(model.isComplete)
        #expect(model.mounted == Set(order))
        #expect(model.sectionDidAppear(.reset) == nil)
    }

    @Test func appearanceOfASectionThatIsNotTheChainHeadDoesNotAdvance() {
        let model = SettingsSectionMountModel(initial: .sleepyMode, order: order)
        // Navigation mounts .textBox out of band; its appearance must not
        // start a second chain (two sections per turn).
        #expect(model.ensureMounted(.textBox) == false)
        #expect(model.sectionDidAppear(.textBox) == nil)
        #expect(model.mounted == [.sleepyMode, .textBox])
        #expect(model.sectionDidAppear(.sleepyMode) == .app)
        #expect(model.sectionDidAppear(.app) == .terminal)
        // .textBox is already mounted, so the chain skips it.
        #expect(model.sectionDidAppear(.terminal) == .reset)
        // Everything is mounted, but the last mount is still under
        // construction until it appears.
        #expect(!model.isComplete)
        #expect(model.sectionDidAppear(.reset) == nil)
        #expect(model.isComplete)
    }

    @Test func ensureMountedReportsAlreadyMountedSections() {
        let model = SettingsSectionMountModel(initial: .sleepyMode, order: order)
        #expect(model.ensureMounted(.sleepyMode))
        #expect(model.ensureMounted(.reset) == false)
        #expect(model.ensureMounted(.reset))
    }

    @Test func sectionsOutsideTheOrderCountAsMounted() {
        let model = SettingsSectionMountModel(initial: .sleepyMode, order: [.sleepyMode, .app])
        #expect(model.isMounted(.mobile))
        #expect(model.ensureMounted(.mobile))
        #expect(model.mounted == [.sleepyMode])
    }

    @Test func initialSectionOutsideTheOrderFallsBackToTheFirstSlot() {
        let model = SettingsSectionMountModel(initial: .mobile, order: [.sleepyMode, .app])
        #expect(model.mounted == [.sleepyMode])
        #expect(model.sectionDidAppear(.sleepyMode) == .app)
    }

    @Test func completionWaitsForTheFinalSectionToAppear() {
        let model = SettingsSectionMountModel(initial: .sleepyMode, order: [.sleepyMode, .app])
        #expect(!model.isComplete)
        #expect(model.sectionDidAppear(.sleepyMode) == .app)
        #expect(model.mounted == Set([.sleepyMode, .app]))
        #expect(!model.isComplete, "the App section is mounted but has not appeared yet")
        #expect(model.sectionDidAppear(.app) == nil)
        #expect(model.isComplete)
    }

    @Test func deferredScrollIsOwedToItsSectionOnly() {
        let model = SettingsSectionMountModel(initial: .sleepyMode, order: order)
        let target = SettingsSectionScrollTarget(
            section: .textBox, anchorID: "section:textBox", anchor: .top, generation: 3
        )
        model.deferScroll(target)
        #expect(model.takeDeferredScroll(for: .app) == nil)
        #expect(model.takeDeferredScroll(for: .textBox) == target)
        #expect(model.takeDeferredScroll(for: .textBox) == nil)
        model.deferScroll(target)
        model.cancelDeferredScroll()
        #expect(model.deferredScroll == nil)
    }

    @Test func pinnedScrollTracksTheLatestNavigation() {
        let model = SettingsSectionMountModel(initial: .sleepyMode, order: order)
        let first = SettingsSectionScrollTarget(section: .reset, anchorID: "section:reset", anchor: .top, generation: 1)
        let second = SettingsSectionScrollTarget(section: .app, anchorID: "row:app", anchor: .center, generation: 2)
        model.pin(first)
        model.pin(second)
        #expect(model.pinnedScroll == second)
    }

    @Test func isAboveFollowsDisplayOrder() {
        let model = SettingsSectionMountModel(initial: .sleepyMode, order: order)
        #expect(model.isAbove(.sleepyMode, .reset))
        #expect(!model.isAbove(.reset, .sleepyMode))
        #expect(!model.isAbove(.app, .app))
        #expect(model.isAbove(.terminal, .textBox))
        #expect(!model.isAbove(.mobile, .reset))
    }
}
