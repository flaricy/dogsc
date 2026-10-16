import AppKit
import Combine
import Sparkle

/// Owns the single Sparkle session for the installed application bundle.
///
/// Development and custom builds never install an official update over local
/// changes, including custom builds that retain the installed app's identity.
@MainActor
final class AppUpdateController: ObservableObject {
    static let shared = AppUpdateController()

    static let formalBundleIdentifier = "cn.laogou.dogsc"

    @Published private(set) var isReady = false
    @Published private(set) var automaticallyChecksForUpdates = false

    private var updaterController: SPUStandardUpdaterController?
    private var didStart = false

    private init() {}

    var isCustomBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "DogSCCustomBuild") as? Bool == true
    }

    var isFormalRelease: Bool {
        Bundle.main.bundleIdentifier == Self.formalBundleIdentifier && !isCustomBuild
    }

    var currentVersionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"
        return "\(version)（\(build)）"
    }

    var availabilityDescription: String {
        if isCustomBuild {
            return "定制版已禁用官方更新，以保留你的录屏功能修改。"
        }
        if isFormalRelease {
            return automaticallyChecksForUpdates
                ? "每天自动检查 GitHub Release；发现新版后可直接下载、替换并重新打开。"
                : "自动检查已关闭；仍可随时手动检查并直接安装新版。"
        }
        return "开发版不会替换正式版；发布后的 DogSC 才会连接 GitHub 更新源。"
    }

    func startIfEligible() {
        guard !didStart else { return }
        didStart = true
        guard isFormalRelease else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        isReady = true
    }

    func checkForUpdates() {
        guard isFormalRelease else { return }
        startIfEligible()
        guard let updaterController else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isFormalRelease else { return }
        startIfEligible()
        updaterController?.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }
}
