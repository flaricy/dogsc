import AVFoundation
import RecorderCore
import ScreenCaptureKit

/// The normal writer and rolling replay writer share the same capture lifecycle.
protocol ScreenCaptureWriting: SCStreamOutput, Sendable {
    var outputURL: URL { get }
    func append(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType)
    func recordedSourceTime(atHostTime: TimeInterval) -> TimeInterval?
    func setPaused(_ paused: Bool) async
    func finish() async throws -> FrameRateMeasurement?
    func currentMeasurement() async -> FrameRateMeasurement?
    func currentAudioDiagnostics() async -> AudioCaptureDiagnostics?
    func droppedAudioSamples() async -> Int
    func currentTerminalError() async -> (any Error)?
    func failStartup(with error: any Error)
    func waitForFirstFrame(timeout: TimeInterval) async throws -> Date
    func firstFrameHostTime() async -> TimeInterval?
}

extension ScreenCaptureWriting {
    func waitForFirstFrame() async throws -> Date { try await waitForFirstFrame(timeout: 5) }
}
