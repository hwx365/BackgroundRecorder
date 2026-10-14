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
///
/// ## 为什么这里「只做事、不说话」
///
/// 三个 Intent 的 `perform()` 都刻意**不返回 dialog**，也不遵循 `ProvidesDialog`。
///
/// 因为 dialog 会让系统在屏幕上弹一条提示（「已开始录像。」），而从「操作按钮」触发的
/// 场景本来就是不想看屏幕 —— 弹出提示既多余，又会在进入黑屏隐身的瞬间把屏幕照亮，
/// 把隐身效果破坏掉。
///
/// 代价是**失败时也静默**。所以每一条结果都写进 `diagnostics.log`，
/// 需要排查时去「文件」App 里看（路径见 README）。
///
/// 另外：App 切到前台本身就是最直接的反馈 —— 成功则屏幕变黑（进入隐身），
/// 失败则停在明亮的常规界面。
///
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

    static func start() async {
        guard let recorder = await readyRecorder() else {
            RecorderDiagnostics.shared.log("快捷指令 | 开始录像被忽略：录像器未就绪")
            return
        }
        guard CameraRecorder.hasCameraPermission else {
            RecorderDiagnostics.shared.log("快捷指令 | 开始录像被忽略：没有相机权限")
            return
        }
        guard !recorder.isRecording else {
            RecorderDiagnostics.shared.log("快捷指令 | 开始录像被忽略：已在录制中")
            return
        }
        recorder.startRecordingFromShortcut()
        RecorderDiagnostics.shared.log("快捷指令 | 开始录像")
    }

    static func stop() async {
        guard let recorder = await readyRecorder() else {
            RecorderDiagnostics.shared.log("快捷指令 | 停止录像被忽略：录像器未就绪")
            return
        }
        guard recorder.isRecording else {
            RecorderDiagnostics.shared.log("快捷指令 | 停止录像被忽略：当前没有在录制")
            return
        }
        recorder.stopRecordingByUser()
        RecorderDiagnostics.shared.log("快捷指令 | 停止录像")
    }

    static func toggle() async {
        guard let recorder = await readyRecorder() else {
            RecorderDiagnostics.shared.log("快捷指令 | 切换被忽略：录像器未就绪")
            return
        }
        if recorder.isRecording {
            recorder.stopRecordingByUser()
            RecorderDiagnostics.shared.log("快捷指令 | 切换 → 停止录像")
            return
        }
        guard CameraRecorder.hasCameraPermission else {
            RecorderDiagnostics.shared.log("快捷指令 | 切换被忽略：没有相机权限")
            return
        }
        recorder.startRecordingFromShortcut()
        RecorderDiagnostics.shared.log("快捷指令 | 切换 → 开始录像")
    }
}

// MARK: - 三个动作
//
// 全部只返回 `.result()`，不带 dialog —— 原因见文件顶部。

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "开始录像"
    static var description: IntentDescription? = IntentDescription("立即开始录像，并进入黑屏隐身界面。")
    /// 摄像头只能在前台使用，所以要求把 App 带到前台
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await RecordingShortcutRunner.start()
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "停止录像"
    static var description: IntentDescription? = IntentDescription("停止当前正在进行的录像。")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await RecordingShortcutRunner.stop()
        return .result()
    }
}

/// 最适合绑定到侧边「操作按钮」：按一下开始，再按一下停止
struct ToggleRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "开始或停止录像"
    static var description: IntentDescription? = IntentDescription(
        "正在录像就停止，否则开始录像。适合绑定到侧边「操作按钮」。"
    )
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await RecordingShortcutRunner.toggle()
        return .result()
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
