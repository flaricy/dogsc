import AppKit
import Foundation

extension AppModel {
    func completeGameReplay(run: RecordingRun, warnings: [String]) async {
        var warnings = warnings
        do {
            guard let source = recordingURL, await isUsableVideoFile(source) else {
                throw ScreenRecorderError.recordingFailed("游戏视频保存失败，分段素材已保留")
            }
            recorderTransitionStage = .savingProject
            let folder = AppPreferences.exportDirectoryURL
            let destination = folder.appendingPathComponent("Game-\(UUID().uuidString).mp4")
            // Copy to a sibling staging name first: a full destination disk
            // must never destroy the only recoverable recording.
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let partial = folder.appendingPathComponent(".game-\(UUID().uuidString).mp4")
                defer { try? FileManager.default.removeItem(at: partial) }
                try FileManager.default.copyItem(at: source, to: partial)
                try FileManager.default.moveItem(at: partial, to: destination)
            }.value
            lastGameReplayURL = destination
            if let session = await workspace.invalidateCurrentSession() {
                // These are this replay's generated staging files, never a
                // user's project. The final video is already safely exported.
                try? FileManager.default.removeItem(at: session.packageURL)
            }
        } catch {
            warnings.append(appErrorDescription(error))
            if let session = currentSession {
                warnings.append(session.packageURL.path)
            }
            _ = await workspace.invalidateCurrentSession()
        }
        guard recordingRuns.end(run.id) != nil else { return }
        finishingTask = nil
        resetTransientRecordingState()
        captureSetup.reset()
        resumeLiveInputIndicatorsForSetup()
        recorderTransitionStage = .idle
        phase = .setup
        errorMessage = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }

    /// Completed takes are already durable. Return to capture without forcing
    /// an editor session or replacing an unfinished save.
    func beginNextRecording() {
        if phase == .recordingComplete {
            Task { @MainActor [weak self] in
                if await self?.saveCompletedRecording() == true { WindowCoordinator.showRecorderBar() }
            }
        } else if phase == .editor, !exporter.isExporting, !isMediaExchangeRunning {
            flushCurrentProjectAndClose()
        } else if phase == .setup {
            WindowCoordinator.showRecorderBar()
        }
    }
}
