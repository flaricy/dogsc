import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import RecorderCore
import ScreenCaptureKit
import Testing
@testable import DogSCApp

struct ReplayRecordingTests {
    @Test func defaultsAndRetentionBoundaries() {
        #expect(ReplayWindowPolicy.minutes(0) == 10)
        #expect(ReplayWindowPolicy.minutes(-1) == 10)
        #expect(ReplayWindowPolicy.minutes(30) == 30)
        #expect(ReplayWindowPolicy.retainedRange(end: 120, duration: 600) == 0..<120)
        #expect(ReplayWindowPolicy.retainedRange(end: 3600, duration: 600) == 3000..<3600)
        #expect(!ReplayWindowPolicy.shouldRetain(segmentEnd: 3000, latestTime: 3600, duration: 600))
        #expect(ReplayWindowPolicy.shouldRetain(segmentEnd: 3001, latestTime: 3600, duration: 600))
    }

    @Test @MainActor func autoMotionIsOffByDefaultAndPlanSnapshotsPreference() throws {
        let defaults = UserDefaults.standard
        let key = AppPreferences.automaticMotionEnabledKey
        let previous = defaults.object(forKey: key)
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.removeObject(forKey: key)
        #expect(!AppPreferences.automaticMotionEnabled)
        let target = CaptureSelectionTarget.display(id: 1, name: "Test")
        let config = target.materializing(in: CaptureConfiguration())
        let plan = try RecordingPlan(target: target, configuration: config, pointerCaptureFrame: .zero,
            automaticallyCreatesZooms: AppPreferences.automaticMotionEnabled)
        defaults.set(true, forKey: key)
        #expect(AppPreferences.automaticMotionEnabled)
        #expect(!plan.automaticallyCreatesZooms)
    }

    @Test func rollingWriterProducesBoundedPlayableMP4() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replay.mp4")
        let output = try ReplayCaptureOutput(run: ScreenRecorderRunToken(runID: RecordingRunID(), streamGeneration: 1),
            outputURL: url, width: 64, height: 64, frameRate: .fps30,
            recordsSystemAudio: true, retention: 0.6, segmentDuration: 0.2,
            onTerminalFailure: { _ in })
        // Use the real monotonic clock, as SCK does, and enough frame spacing
        // to exercise writer rollover without deliberately saturating ingress.
        for index in 0..<45 {
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            output.append(try videoSample(at: now, shade: UInt8(index * 5)), of: .screen)
            output.append(try audioSample(at: now), of: .audio)
            try await Task.sleep(for: .milliseconds(35))
        }
        try await Task.sleep(for: .milliseconds(100))
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("replay-segments"),
            includingPropertiesForKeys: nil)
        #expect(files.filter { $0.pathExtension == "mp4" }.count <= 6)
        _ = try await output.finish()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 0.45 && duration <= 0.65)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        #expect(image.width == 64)
        var rgba = [UInt8](repeating: 0, count: 64 * 64 * 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 64, height: 64, bitsPerComponent: 8,
                bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        #expect(rgba[0] > 100) // The early dark frames must have been dropped.
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("replay-segments").path))
    }

    @Test func replayShorterThanLimitKeepsWholeTake() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("short.mp4")
        let output = try ReplayCaptureOutput(run: ScreenRecorderRunToken(runID: RecordingRunID(), streamGeneration: 1),
            outputURL: url, width: 64, height: 64, frameRate: .fps30,
            recordsSystemAudio: false, retention: 600, onTerminalFailure: { _ in })
        for index in 0..<8 {
            output.append(try videoSample(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
                shade: UInt8(index * 20)), of: .screen)
            try await Task.sleep(for: .milliseconds(40))
        }
        output.stopAcceptingSamples(atHostTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        try await Task.sleep(for: .milliseconds(350))
        _ = try await output.finish()
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(duration > 0.2 && duration < 0.5)
    }

    @Test func idleScreenRemainsPlayableAcrossReplayBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("idle.mp4")
        let output = try ReplayCaptureOutput(run: ScreenRecorderRunToken(runID: RecordingRunID(), streamGeneration: 1),
            outputURL: url, width: 64, height: 64, frameRate: .fps30,
            recordsSystemAudio: false, retention: 0.6, segmentDuration: 0.2, onTerminalFailure: { _ in })
        output.append(try videoSample(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds, shade: 128), of: .screen)
        try await Task.sleep(for: .milliseconds(1250))
        _ = try await output.finish()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 0.5 && duration <= 0.65)
        let generator = AVAssetImageGenerator(asset: asset)
        let image = try await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image
        #expect(image.width == 64)
    }

    @Test func failedPromotionPreservesSegmentsAndExistingDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("existing.mp4")
        let original = Data("existing file".utf8)
        try original.write(to: url)
        let output = try ReplayCaptureOutput(run: ScreenRecorderRunToken(runID: RecordingRunID(), streamGeneration: 1),
            outputURL: url, width: 64, height: 64, frameRate: .fps30,
            recordsSystemAudio: false, retention: 600, onTerminalFailure: { _ in })
        output.append(try videoSample(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds, shade: 128), of: .screen)
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: (any Error).self) { _ = try await output.finish() }
        #expect(try Data(contentsOf: url) == original)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("replay-segments").path))
    }

    private func audioSample(at time: TimeInterval) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format) == noErr)
        let count = 1600
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: count * 8, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count * 8, flags: 0, blockBufferOut: &block) == noErr)
        let data = Data(repeating: 0, count: count * 8)
        data.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!,
                                              offsetIntoDestination: 0, dataLength: count * 8)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600_000), decodeTimeStamp: .invalid)
        var size = 8
        var result: CMSampleBuffer?
        #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &result) == noErr)
        return try #require(result)
    }

    private func videoSample(at time: TimeInterval, shade: UInt8) throws -> CMSampleBuffer {
        var pixelResult: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelResult)
        #expect(status == kCVReturnSuccess)
        let pixel = try #require(pixelResult)
        CVPixelBufferLockBaseAddress(pixel, [])
        if let address = CVPixelBufferGetBaseAddress(pixel) {
            memset(address, Int32(shade), CVPixelBufferGetDataSize(pixel))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                                                     formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600_000), decodeTimeStamp: .invalid)
        var sampleResult: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sampleResult)
        let sample = try #require(sampleResult)
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true))
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        dictionary[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
        return sample
    }
}
