import AVFoundation
import CoreMedia
import RecorderCore
import ScreenCaptureKit

/// One uninterrupted SCK stream feeds short, independently playable files.
/// Only the requested window plus one boundary segment is retained on disk.
final class ReplayCaptureOutput: NSObject, ScreenCaptureWriting, @unchecked Sendable {
    private final class Segment: @unchecked Sendable {
        let output: CaptureOutput
        var start: TimeInterval?
        var end: TimeInterval?
        var completion: Task<FrameRateMeasurement?, any Error>?
        var completed = false
        init(output: CaptureOutput) { self.output = output }
    }

    let outputURL: URL
    private let directory: URL
    private let retention: TimeInterval
    private let segmentDuration: TimeInterval
    private let run: ScreenRecorderRunToken
    private let width: Int
    private let height: Int
    private let frameRate: OutputFrameRate
    private let recordsAudio: Bool
    private let failure: @Sendable (CaptureOutputTerminalEvent) -> Void
    private let queue = DispatchQueue(label: "cn.laogou.dogsc.replay", qos: .userInitiated)
    private let ingress = PendingSampleGate(limit: 24)
    private let firstOutput: CaptureOutput
    // Every mutable property below is confined to queue.
    private var segments: [Segment]
    private var lastVideo: RetainedSampleBuffer?
    private var latestTime: TimeInterval = 0
    private var stopped = false
    private var captureEnd: TimeInterval?
    private var nextSegmentIndex = 1
    private var terminalError: (any Error)?
    private var timer: DispatchSourceTimer?

    init(run: ScreenRecorderRunToken, outputURL: URL, width: Int, height: Int,
         frameRate: OutputFrameRate, recordsSystemAudio: Bool, retention: TimeInterval,
         segmentDuration: TimeInterval = ReplayWindowPolicy.segmentDuration,
         onTerminalFailure: @escaping @Sendable (CaptureOutputTerminalEvent) -> Void) throws {
        self.run = run
        self.outputURL = outputURL
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.recordsAudio = recordsSystemAudio
        self.retention = max(retention, 0.1)
        self.segmentDuration = max(segmentDuration, 0.1)
        self.failure = onTerminalFailure
        directory = outputURL.deletingLastPathComponent().appendingPathComponent("replay-segments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = try CaptureOutput(run: run,
            outputURL: directory.appendingPathComponent("segment-000000.mp4"),
            width: width, height: height, frameRate: frameRate, codec: .h264,
            recordsSystemAudio: recordsSystemAudio, onTerminalFailure: onTerminalFailure)
        firstOutput = first
        segments = [Segment(output: first)]
        super.init()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, self.captureEnd == nil, self.terminalError == nil,
                  let last = self.lastVideo else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            // Static desktops still rotate and remain bounded even with audio
            // disabled. Repeat the last image only when SCK has gone idle.
            if now - self.latestTime >= 1,
               let repeated = Self.repeatedVideo(last.value, at: now) {
                self.consume(repeated, type: .screen)
            }
        }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        append(sampleBuffer, of: outputType)
    }

    func append(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, ingress.claim() else { return }
        let retained = RetainedSampleBuffer(value: sampleBuffer)
        queue.async { [self] in
            defer { ingress.complete() }
            consume(retained.value, type: type)
        }
    }

    private func consume(_ buffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard !stopped, captureEnd == nil, terminalError == nil else { return }
        let time = buffer.presentationTimeStamp.seconds
        guard time.isFinite else { return }
        if type == .screen {
            guard CMSampleBufferDataIsReady(buffer), CMSampleBufferGetImageBuffer(buffer) != nil,
                  ScreenCaptureFrameMetadata.status(of: buffer) == .complete,
                  time >= latestTime else { return }
            do {
                if let current = segments.last, let start = current.start,
                   time - start >= segmentDuration {
                    let next = try CaptureOutput(run: run,
                        outputURL: directory.appendingPathComponent(String(format: "segment-%06d.mp4", nextSegmentIndex)),
                        width: width, height: height, frameRate: frameRate, codec: .h264,
                        recordsSystemAudio: recordsAudio, onTerminalFailure: failure)
                    nextSegmentIndex += 1
                    finishSegment(current, at: time)
                    segments.append(Segment(output: next))
                }
                latestTime = time
                lastVideo = RetainedSampleBuffer(value: buffer)
                if segments.last?.start == nil { segments.last?.start = time }
                prune()
            } catch { fail(error) }
        }
        segments.last?.output.append(buffer, of: type)
    }

    private func finishSegment(_ segment: Segment, at end: TimeInterval) {
        guard segment.completion == nil else { return }
        segment.end = end
        segment.completion = Task { [self] in
            do {
                let result = try await segment.output.finish(atHostTime: end)
                queue.async { [self] in segment.completed = true; prune() }
                return result
            } catch {
                queue.async { [self] in fail(error) }
                throw error
            }
        }
    }

    private func prune() {
        // The unfinished boundary segment is retained until its writer closes.
        let expired = segments.filter {
            $0.completed && !ReplayWindowPolicy.shouldRetain(
                segmentEnd: $0.end ?? latestTime, latestTime: latestTime, duration: retention)
        }
        for segment in expired {
            do { try FileManager.default.removeItem(at: segment.output.outputURL) }
            catch { fail(error); return }
        }
        let expiredURLs = Set(expired.map { $0.output.outputURL })
        segments.removeAll { expiredURLs.contains($0.output.outputURL) }
    }

    private func fail(_ error: any Error) {
        guard terminalError == nil else { return }
        terminalError = error
        firstOutput.failStartup(with: error)
        failure(CaptureOutputTerminalEvent(run: run, stage: .videoAppend, error: error))
    }

    func stopAcceptingSamples(atHostTime time: TimeInterval) {
        queue.sync {
            captureEnd = captureEnd ?? time
            timer?.cancel()
            timer = nil
        }
    }

    func finish() async throws -> FrameRateMeasurement? {
        let snapshot: [Segment] = queue.sync {
            guard !stopped else { return [] }
            stopped = true
            timer?.cancel()
            timer = nil
            // Use the common host clock so an idle image extends up to Stop.
            let end = captureEnd ?? max(latestTime + 1 / Double(frameRate.rawValue),
                          CMClockGetTime(CMClockGetHostTimeClock()).seconds)
            if let current = segments.last { finishSegment(current, at: end) }
            return segments
        }
        guard !snapshot.isEmpty else { throw ScreenRecorderError.noFrames }
        var measurement: FrameRateMeasurement?
        for segment in snapshot {
            if let completion = segment.completion { measurement = try await completion.value }
        }
        if let error = await currentTerminalError() { throw error }
        let clips = snapshot.compactMap { segment -> ReplayMediaSegment? in
            guard let start = segment.start, let end = segment.end else { return nil }
            return ReplayMediaSegment(url: segment.output.outputURL, start: start, end: end)
        }
        try await ReplayVideoAssembler.export(segments: clips, retention: retention, to: outputURL)
        // Delete only after a playable MP4 has been successfully written.
        try FileManager.default.removeItem(at: directory)
        return measurement
    }

    func waitForFirstFrame(timeout: TimeInterval) async throws -> Date {
        try await firstOutput.waitForFirstFrame(timeout: timeout)
    }
    func firstFrameHostTime() async -> TimeInterval? { await firstOutput.firstFrameHostTime() }
    func currentMeasurement() async -> FrameRateMeasurement? {
        let output = queue.sync { segments.last?.output }
        return await output?.currentMeasurement()
    }
    func currentAudioDiagnostics() async -> AudioCaptureDiagnostics? {
        let output = queue.sync { segments.last?.output }
        return await output?.currentAudioDiagnostics()
    }
    func droppedAudioSamples() async -> Int {
        let output = queue.sync { segments.last?.output }
        return await output?.droppedAudioSamples() ?? 0
    }
    func currentTerminalError() async -> (any Error)? { queue.sync { terminalError } }
    func failStartup(with error: any Error) { queue.async { [self] in fail(error) } }
    func recordedSourceTime(atHostTime time: TimeInterval) -> TimeInterval? { nil }
    func setPaused(_ paused: Bool) async { /* Replay uses a continuous wall-clock window. */ }

    private static func repeatedVideo(_ sample: CMSampleBuffer, at time: TimeInterval) -> CMSampleBuffer? {
        guard let image = CMSampleBufferGetImageBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600_000), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &result) == noErr, let result,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true) else { return nil }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        dictionary[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
        return result
    }
}

struct ReplayMediaSegment: Sendable {
    let url: URL
    let start: TimeInterval
    let end: TimeInterval
}

enum ReplayVideoAssembler {
    static func export(segments: [ReplayMediaSegment], retention: TimeInterval, to destination: URL) async throws {
        guard let first = segments.first, let last = segments.last else { throw ScreenRecorderError.noFrames }
        let range = ReplayWindowPolicy.retainedRange(end: last.end - first.start, duration: retention)
        let windowStart = first.start + range.lowerBound
        let windowEnd = first.start + range.upperBound
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ScreenRecorderError.cannotCreateWriter
        }
        for segment in segments where segment.end > windowStart {
            let asset = AVURLAsset(url: segment.url)
            let lower = max(segment.start, windowStart)
            let upper = min(segment.end, windowEnd)
            guard upper > lower else { continue }
            let requested = CMTimeRange(start: CMTime(seconds: lower - segment.start, preferredTimescale: 600_000),
                duration: CMTime(seconds: upper - lower, preferredTimescale: 600_000))
            for type in [AVMediaType.video, .audio] {
                guard let track = try await asset.loadTracks(withMediaType: type).first else { continue }
                let available = try await track.load(.timeRange)
                let clipped = CMTimeRangeGetIntersection(requested, otherRange: available)
                guard clipped.duration.seconds > 0 else { continue }
                let target = type == .video ? video : audio
                let offset = lower - windowStart + clipped.start.seconds - requested.start.seconds
                try target.insertTimeRange(clipped, of: track,
                    at: CMTime(seconds: offset, preferredTimescale: 600_000))
                if type == .video { target.preferredTransform = try await track.load(.preferredTransform) }
            }
        }
        guard !video.segments.isEmpty,
              let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ScreenRecorderError.noFrames
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".replay-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        exporter.outputURL = temporary
        exporter.outputFileType = .mp4
        exporter.timeRange = CMTimeRange(start: .zero,
            duration: CMTime(seconds: windowEnd - windowStart, preferredTimescale: 600_000))
        await exporter.export()
        guard exporter.status == .completed else {
            throw exporter.error ?? ScreenRecorderError.recordingFailed("游戏视频保存失败，分段素材已保留")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
