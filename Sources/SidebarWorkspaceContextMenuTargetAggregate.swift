import CmuxCore
import Foundation

/// Shared context-menu facts derived from a target workspace selection.
///
/// The sidebar computes the selected-set aggregate once above `LazyVStack`.
/// Selected rows reuse this immutable value instead of repeating
/// grouping, unread, and notification aggregation during row realization.
struct SidebarWorkspaceContextMenuTargetAggregate: Equatable {
    let targetWorkspaceIds: [UUID]
    let eligibleGroupTargetIds: [UUID]
    let allEligibleTargetsGroupId: UUID?
    let hasGroupedEligibleTarget: Bool
    let canMarkRead: Bool
    let canMarkUnread: Bool
    let hasLatestNotification: Bool
    let allNotificationsMuted: Bool
    let notifications: [TerminalNotification]

    @MainActor
    init(
        targetWorkspaceIds: [UUID],
        workspaceRowsById: [UUID: SidebarWorkspaceRowInput],
        anchorWorkspaceIds: Set<UUID>,
        notificationIndex: SidebarWorkspaceNotificationIndex
    ) {
        self.targetWorkspaceIds = targetWorkspaceIds
        eligibleGroupTargetIds = targetWorkspaceIds.filter {
            !anchorWorkspaceIds.contains($0) && workspaceRowsById[$0] != nil
        }
        let eligibleGroupIds = eligibleGroupTargetIds.map { workspaceRowsById[$0]?.groupId }
        allEligibleTargetsGroupId = Self.commonGroupId(eligibleGroupIds)
        hasGroupedEligibleTarget = eligibleGroupTargetIds.contains {
            workspaceRowsById[$0]?.groupId != nil
        }
        canMarkRead = targetWorkspaceIds.contains {
            (workspaceRowsById[$0]?.unreadCount ?? 0) > 0
        }
        canMarkUnread = targetWorkspaceIds.contains {
            (workspaceRowsById[$0]?.unreadCount ?? 0) == 0
        }
        hasLatestNotification = notificationIndex.hasNotification(
            workspaceIds: targetWorkspaceIds
        )
        allNotificationsMuted = !targetWorkspaceIds.isEmpty && targetWorkspaceIds.allSatisfy {
            workspaceRowsById[$0]?.workspace.isMuted == true
        }
        notifications = notificationIndex.contextMenuNotifications(
            workspaceIds: targetWorkspaceIds
        )
    }

    private static func commonGroupId(_ groupIds: [UUID?]) -> UUID? {
        guard let first = groupIds.first,
              groupIds.allSatisfy({ $0 == first }) else {
            return nil
        }
        return first
    }
}
