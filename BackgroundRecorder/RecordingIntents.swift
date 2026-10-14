import AppIntents
import Foundation

/// 桥接：让 App Intent 拿到正在运行的录像器实例。
///
/// 三个 Intent 都设置了 `openAppWhenRun = true`（摄像头必须在前台使用），
/// 因此它们会在 App 进程内执行，只要 CameraRecorder 初始化时把自己注册进来即可。
final class RecorderBridge {
    static let shared = RecorderBridge()

    weak var recorder: CameraRecorder?

    private init() {}
}

/// 快捷指令 / 操作按钮的执行入口。
/// 统一在主线程上操作录像器（App Intent 的 perform 在后台上下文，需要显式切回）。
@MainActor
enum RecordingShortcutRunner {

    /// 冷启动时录像器可能还没创建完，最多等 2 秒
    private static func readyRecorder() async -> CameraRecorder? {
        for _ in 0..<20 {
            if let recorder = RecorderBridge.shared.recorder { return recorder }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    static func start() async -> String {
        guard let recorder = await readyRecorder() else {
            return "录像器还没准备好，请先手动打开一次 App。"
        }
        guard CameraRecorder.hasCameraPermission else {
            return "无法开始录像：还没有相机权限，请先打开 App 完成授权。"
        }
        guard !recorder.isRecording else {
            return "已经在录像了。"
        }
        recorder.startRecordingFromShortcut()
        return "已开始录像。"
    }

    static func stop() async -> String {
        guard let recorder = await readyRecorder() else {
            return "录像器还没准备好，请先手动打开一次 App。"
        }
        guard recorder.isRecording else {
            return "当前没有在录像。"
        }
        recorder.stopRecordingByUser()
        return "已停止录像。"
    }

    static func toggle() async -> String {
        guard let recorder = await readyRecorder() else {
            return "录像器还没准备好，请先手动打开一次 App。"
        }
        if recorder.isRecording {
            recorder.stopRecordingByUser()
            return "已停止录像。"
        }
        guard CameraRecorder.hasCameraPermission else {
            return "无法开始录像：还没有相机权限，请先打开 App 完成授权。"
        }
        recorder.startRecordingFromShortcut()
        return "已开始录像。"
    }
}

// MARK: - 三个动作

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "开始录像"
    static var description: IntentDescription? = IntentDescription("立即开始录像，并进入黑屏隐身界面。")
    /// 摄像头只能在前台使用，所以要求把 App 带到前台
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await RecordingShortcutRunner.start()
        return .result(dialog: "\(message)")
    }
}

struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "停止录像"
    static var description: IntentDescription? = IntentDescription("停止当前正在进行的录像。")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await RecordingShortcutRunner.stop()
        return .result(dialog: "\(message)")
    }
}

/// 最适合绑定到侧边「操作按钮」：按一下开始，再按一下停止
struct ToggleRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "开始或停止录像"
    static var description: IntentDescription? = IntentDescription(
        "正在录像就停止，否则开始录像。适合绑定到侧边「操作按钮」。"
    )
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await RecordingShortcutRunner.toggle()
        return .result(dialog: "\(message)")
    }
}

// MARK: - 让快捷指令自带这三个动作，用户无需手动创建

struct BackgroundRecorderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: [
                "用 \(.applicationName) 录像",
                "\(.applicationName) 切换录像"
            ],
            shortTitle: "开始或停止录像",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "\(.applicationName) 开始录像"
            ],
            shortTitle: "开始录像",
            systemImageName: "video.fill"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "\(.applicationName) 停止录像"
            ],
            shortTitle: "停止录像",
            systemImageName: "stop.fill"
        )
    }
}
