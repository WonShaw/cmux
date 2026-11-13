import Dispatch
import Foundation

extension GitMetadataService {
    /// Resolves the full reference snapshot for watcher/config consumers.
    nonisolated func gitReferenceSnapshotForConfig(
        repository: ResolvedGitRepository,
        deadline: DispatchTime
    ) async -> GitReferenceSnapshot {
        await gitReferenceSnapshot(
            repository: repository,
            deadline: deadline,
            includeStorageWatchPaths: true
        )
    }

    /// Resolves refs on the package's bounded blocking-I/O lane.
    ///
    /// - Parameter repository: The already-resolved repository to inspect.
    /// - Returns: A consistent branch, commit, and head-signature snapshot.
    @concurrent
    nonisolated func gitReferenceSnapshot(
        repository: ResolvedGitRepository,
        deadline: DispatchTime? = nil,
        includeStorageWatchPaths: Bool = false,
        revalidateFileBackedHead: Bool = false
    ) async -> GitReferenceSnapshot {
        guard deadline.map({ $0 > DispatchTime.now() }) ?? true else {
            return GitReferenceSnapshot(
                checkedOutBranch: .unreadable,
                headSignature: nil,
                currentCommit: nil
            )
        }
        let referenceReader = referenceReader
        let didAcquire = if let deadline {
            await referenceSnapshotLimiter.acquire(until: deadline)
        } else {
            await referenceSnapshotLimiter.acquire()
        }
        guard didAcquire else {
            return GitReferenceSnapshot(
                checkedOutBranch: .unreadable,
                headSignature: nil,
                currentCommit: nil
            )
        }
        let cancellationSignal = WorkspaceChangesCancellationSignal(deadline: deadline)
        let snapshot: GitReferenceSnapshot = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<GitReferenceSnapshot, Never>) in
                Self.blockingStatusQueue.async {
                    let snapshot = cancellationSignal.withCurrentBinding {
                        guard deadline.map({ $0 > DispatchTime.now() }) ?? true else {
                            return GitReferenceSnapshot(
                                checkedOutBranch: .unreadable,
                                headSignature: nil,
                                currentCommit: nil
                            )
                        }
                        if revalidateFileBackedHead {
                            return referenceReader.headSnapshot(
                                repository: repository,
                                deadline: deadline
                            )
                        } else {
                            return referenceReader.snapshot(
                                repository: repository,
                                deadline: deadline,
                                includeStorageWatchPaths: includeStorageWatchPaths
                            )
                        }
                    }
                    continuation.resume(returning: snapshot)
                }
            }
        } onCancel: {
            cancellationSignal.cancel()
        }
        await referenceSnapshotLimiter.release()
        return snapshot
    }
}
