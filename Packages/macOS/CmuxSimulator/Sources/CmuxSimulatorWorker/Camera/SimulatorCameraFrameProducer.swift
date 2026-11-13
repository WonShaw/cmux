@preconcurrency import AVFoundation
import CmuxSimulator
import CoreImage
import Foundation

@MainActor
final class SimulatorCameraFrameProducer {
    private let surfaceRing: SimulatorCameraSurfaceRing
    private let timing: any SimulatorCameraTiming
    private let playback: SimulatorCameraPlayback
    private let sessionRunner: SimulatorCameraSessionRunner
    private let fileManager: FileManager
    private let captureQueue = DispatchQueue(
        label: "com.cmux.simulator.camera.capture",
        qos: .userInteractive
    )
    private var videoTask: Task<Void, Never>?
    private var captureSession: SimulatorCameraCaptureSessionBox?
    private var captureDelegate: SimulatorCameraCaptureDelegate?

    init(
        surfaceRing: SimulatorCameraSurfaceRing,
        timing: any SimulatorCameraTiming = ContinuousSimulatorCameraTiming(),
        sessionRunner: SimulatorCameraSessionRunner = SimulatorCameraSessionRunner(),
        fileManager: FileManager = FileManager()
    ) {
        self.surfaceRing = surfaceRing
        self.timing = timing
        playback = SimulatorCameraPlayback(surfaceRing: surfaceRing, timing: timing)
        self.sessionRunner = sessionRunner
        self.fileManager = fileManager
    }

    deinit {
        videoTask?.cancel()
        if let captureSession { sessionRunner.stopDetached(captureSession) }
    }

    func configure(_ configuration: SimulatorCameraConfiguration) async throws {
        let source = unwrappedSimulatorCameraSource(configuration)

        await stop()
        switch source {
        case .disabled:
            return
        case .placeholder:
            let playback = playback
            videoTask = Task(priority: .userInitiated) {
                await playback.playPlaceholder()
            }
        case let .image(url):
            guard url.isFileURL,
                  fileManager.isReadableFile(atPath: url.path),
                  let image = CIImage(contentsOf: url)
            else {
                throw SimulatorWorkerFailure.privateAPIUnavailable(
                    "The synthetic-camera image is missing or unreadable."
                )
            }
            // Match serve-sim camera semantics: preserve the entire source and
            // letterbox aspect-ratio differences instead of cropping them.
            surfaceRing.publish(image, fillsFrame: false)
        case let .video(url, loops):
            guard url.isFileURL, fileManager.isReadableFile(atPath: url.path) else {
                throw SimulatorWorkerFailure.privateAPIUnavailable(
                    "The synthetic-camera video is missing or unreadable."
                )
            }
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else {
                throw SimulatorWorkerFailure.privateAPIUnavailable(
                    "The synthetic-camera video has no video track."
                )
            }
            let playback = playback
            videoTask = Task(priority: .userInitiated) {
                await playback.playVideo(
                    url: url,
                    loops: loops
                )
            }
        case let .hostCamera(deviceIdentifier):
            try await startHostCamera(deviceIdentifier: deviceIdentifier)
        case .targeted:
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "The synthetic-camera target configuration could not be resolved."
            )
        }
    }

    func stop() async {
        let stoppingVideoTask = videoTask
        stoppingVideoTask?.cancel()
        videoTask = nil
        await stoppingVideoTask?.value
        if let captureSession {
            await sessionRunner.stop(captureSession)
            await withCheckedContinuation { continuation in
                captureQueue.async { continuation.resume() }
            }
        }
        captureSession = nil
        captureDelegate = nil
    }

    /// The offline build never captures from a host camera: the app carries no
    /// camera usage description or entitlement, so the source is rejected.
    private func startHostCamera(deviceIdentifier _: String?) async throws {
        throw SimulatorWorkerFailure.privateAPIUnavailable(
            "Host-camera mirroring is not available in this build."
        )
    }
}

private func unwrappedSimulatorCameraSource(
    _ configuration: SimulatorCameraConfiguration
) -> SimulatorCameraConfiguration {
    if case let .targeted(_, source) = configuration {
        return unwrappedSimulatorCameraSource(source)
    }
    return configuration
}

/// No host cameras are offered: this build does not request camera access.
func simulatorAvailableHostCameras() -> [SimulatorHostCameraDevice] {
    []
}
