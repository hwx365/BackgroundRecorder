import AVFoundation
import SwiftUI

@MainActor
struct ContentView: View {

    @StateObject private var library: RecordingLibrary
    @StateObject private var settings: RecordingSettings
    @StateObject private var recorder: CameraRecorder

    @Environment(\.scenePhase) private var scenePhase

    @State private var permissionChecked = false
    @State private var permissionGranted = false
    @State private var showLibrary = false
    @State private var showSettings = false
    /// 录制前的屏幕亮度，结束后恢复
    @State private var originalBrightness: CGFloat?

    /// 隐身覆盖层是否已被主动解除（只有「停止录像」才会置为 true）
    @State private var stealthDismissed = false

    /// 双指长按成功次数，由 `StealthGestureLayer` 自增
    ///（UIKit 手势识别器不能直接改 @State，只能写 Binding）
    @State private var stealthExitRequest = 0

    init() {
        let library = RecordingLibrary()
        let settings = RecordingSettings()
        _library = StateObject(wrappedValue: library)
        _settings = StateObject(wrappedValue: settings)
        _recorder = StateObject(wrappedValue: CameraRecorder(library: library, settings: settings))
    }

    /// 隐身状态：开关打开 + 正在录制 + 尚未解除。
    ///
    /// 录制期间这个值会**一直保持 true** —— 没有任何轻点/滑动能暂时揭开黑屏，
    /// 唯一的出口是「双指长按 3 秒」或侧边「操作按钮」停止录像。
    private var stealthActive: Bool {
        settings.stealthMode && recorder.isRecording && !stealthDismissed
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if permissionGranted {
                CameraPreviewView(session: recorder.session)
                    .ignoresSafeArea()
                    .overlay(alignment: .top) { topFade }
            } else if permissionChecked {
                permissionPlaceholder
            } else {
                ProgressView().tint(.white)
            }

            if stealthActive {
                stealthOverlay
            } else {
                controlsLayer
            }
        }
        // 状态栏（信号 / 时间 / 电量）与底部 Home 指示条由 **系统** 绘制在 App 视图层级之上，
        // 用 Color.black 覆盖层是盖不住的，只能让系统自己关掉。
        // 与亮度调节同步：录制期间一直隐藏，退出隐身时和亮度一起恢复。
        .statusBarHidden(stealthActive)
        .persistentSystemOverlays(stealthActive ? .hidden : .automatic)
        // 录制期间「让位」系统手势：从屏幕边缘上滑的**第一次**手势由 App 接管，
        // 不会立刻把 App 切到后台（切后台 = 摄像头被中断 = 停录），要再滑一次才退出。
        // 官方语义是「优先于系统手势」而非「禁止」，所以这是大幅降低误触，不是绝对锁死。
        .defersSystemGestures(on: recorder.isRecording ? .all : [])
        .task { await bootstrap() }
        .onChange(of: recorder.isRecording) { _, recording in
            if !recording { stealthDismissed = false }
            applyBrightness()
        }
        .onChange(of: stealthDismissed) { _, _ in applyBrightness() }
        .onChange(of: settings.stealthMode) { _, _ in applyBrightness() }
        .onChange(of: stealthExitRequest) { _, _ in exitStealth() }
        // 屏幕全黑且亮度为 0，没有任何视觉反馈，用一次震动确认「双指长按」已被识别
        .sensoryFeedback(.success, trigger: stealthExitRequest)
        .onChange(of: scenePhase) { _, phase in
            // 隐身模式下亮度被压到 0，此时若进程被系统回收或用户上滑清掉，
            // 恢复代码就不会执行，手机会一直停在 0 亮度（看起来像坏了）。
            // 所以一进入后台就先把亮度还回去；回到前台再重新压暗。
            if phase == .background {
                restoreBrightness()
            } else if phase == .active {
                applyBrightness()
            }
        }
        .onChange(of: settings.quality) { _, _ in recorder.applyQualitySetting() }
        .onChange(of: settings.recordAudio) { _, _ in recorder.applyAudioSetting() }
        .sheet(isPresented: $showLibrary) {
            RecordingListView(library: library)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, library: library)
        }
        .alert("提示", isPresented: errorBinding) {
            Button("好", role: .cancel) { recorder.errorMessage = nil }
        } message: {
            Text(recorder.errorMessage ?? "")
        }
    }

    // MARK: - 隐身模式

    /// 全黑覆盖层 —— 黑屏期间屏幕对内**完全无响应**。
    ///
    /// | 操作 | 效果 |
    /// | --- | --- |
    /// | 单指轻点 / 滑动 | **什么都不发生** |
    /// | **双指长按 3 秒** | 停止录像、退出隐身（口袋里不可能做出来） |
    /// | 侧边「操作按钮」 | 走快捷指令停止录像（不依赖屏幕，见 `RecordingIntents`） |
    ///
    /// 连「轻点唤出控件」也去掉了：任何单指可触发的响应，在口袋里都会被误触 ——
    /// 轻则亮屏暴露、重则直接停录。黑屏就该是彻底的黑屏，出口只有那两个需要刻意做出的动作。
    ///
    /// 双指长按在 `StealthGestureLayer` 里用 UIKit 实现 —— SwiftUI 的 `onLongPressGesture`
    /// 无法要求「两指同时按住」。
    private var stealthOverlay: some View {
        Color.black
            .ignoresSafeArea()
            .overlay {
                StealthGestureLayer(exitCount: $stealthExitRequest)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .topTrailing) {
                // 极暗的红点：表示正在录制
                Circle()
                    .fill(.red.opacity(0.22))
                    .frame(width: 6, height: 6)
                    .padding(16)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                Text("双指长按 3 秒停止")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.16))
                    .padding(.bottom, 24)
                    .allowsHitTesting(false)
            }
    }

    /// 双指长按 3 秒：停止录像并退出隐身。
    private func exitStealth() {
        // 先把界面亮回来：停止录制时文件要收尾（写入 moov 索引），
        // 这期间如果还是全黑，会让人以为「按了没反应」而反复长按。
        stealthDismissed = true
        recorder.stopRecordingByUser()
    }

    // MARK: - 常规界面

    private var controlsLayer: some View {
        VStack(spacing: 0) {
            statusBar
            notices
            Spacer()
            controlBar
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 30)
    }

    private var topFade: some View {
        LinearGradient(
            colors: [.black.opacity(0.55), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 140)
        .allowsHitTesting(false)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if recorder.isRecording {
                HStack(spacing: 7) {
                    Circle()
                        .fill(.red)
                        .frame(width: 9, height: 9)
                    Text(RecordingLibrary.formattedDuration(recorder.duration))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                    if settings.segment != .unlimited {
                        Text("第 \(recorder.segmentIndex) 段")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer(minLength: 0)

            if permissionGranted, !recorder.isRecording {
                if recorder.torchAvailable {
                    circleButton(
                        system: recorder.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                        tint: recorder.torchOn ? .yellow : .white
                    ) {
                        recorder.toggleTorch()
                    }
                }
                circleButton(system: "arrow.triangle.2.circlepath.camera") {
                    recorder.switchCamera()
                }
            }

            Label(
                recorder.appIsInBackground ? "已切走" : "录制中",
                systemImage: recorder.appIsInBackground ? "exclamationmark.triangle.fill" : "video.fill"
            )
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(recorder.appIsInBackground ? Color.orange : Color.white)
            .opacity(recorder.isRecording ? 1 : 0.55)
        }
        .animation(.snappy, value: recorder.isRecording)
        .animation(.snappy, value: recorder.appIsInBackground)
    }

    /// 自动降级 / 存储提示
    private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = recorder.downgradeNotice {
                noticeRow(notice, icon: "thermometer.medium", color: .orange)
            }
            if let notice = recorder.storageNotice {
                noticeRow(notice, icon: "externaldrive.badge.exclamationmark", color: .yellow)
            }
            if recorder.microphoneDenied {
                noticeRow("未授予麦克风权限：本次只录画面、没有声音", icon: "mic.slash.fill", color: .orange)
            }
        }
        .padding(.top, 10)
        .animation(.snappy, value: recorder.downgradeNotice)
        .animation(.snappy, value: recorder.storageNotice)
        .animation(.snappy, value: recorder.microphoneDenied)
    }

    private func noticeRow(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(color)
    }

    private var controlBar: some View {
        HStack {
            Button {
                showLibrary = true
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "photo.stack").font(.title3)
                    Text("\(library.items.count)").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            Button {
                recorder.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.white.opacity(0.9), lineWidth: 5)
                        .frame(width: 84, height: 84)
                    RoundedRectangle(
                        cornerRadius: recorder.isRecording ? 8 : 34,
                        style: .continuous
                    )
                    .fill(.red)
                    .frame(
                        width: recorder.isRecording ? 34 : 68,
                        height: recorder.isRecording ? 34 : 68
                    )
                }
            }
            .disabled(!permissionGranted)
            .opacity(permissionGranted ? 1 : 0.35)

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .animation(.snappy, value: recorder.isRecording)
    }

    private func circleButton(
        system: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    // MARK: - 无权限占位

    private var permissionPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("需要相机权限")
                .font(.headline)
                .foregroundStyle(.white)
            Text("本 App 只录像、不录音。请在「设置 → 隐私与安全性」中开启相机权限后重新打开 App。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("打开系统设置") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
    }

    // MARK: - 逻辑

    /// 录制时压低屏幕亮度：隐身模式归零（看起来像息屏），普通模式保留极低亮度。
    /// 停止时恢复用户原来的亮度。
    private func applyBrightness() {
        guard recorder.isRecording else {
            restoreBrightness()
            return
        }

        if originalBrightness == nil {
            originalBrightness = UIScreen.main.brightness
        }
        UIScreen.main.brightness = stealthActive ? 0.0 : 0.05
    }

    /// 把亮度还原成用户原来的值。可重复调用（已还原过就什么都不做）。
    private func restoreBrightness() {
        guard let brightness = originalBrightness else { return }
        UIScreen.main.brightness = brightness
        originalBrightness = nil
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { recorder.errorMessage != nil },
            set: { if !$0 { recorder.errorMessage = nil } }
        )
    }

    private func bootstrap() async {
        if CameraRecorder.hasCameraPermission {
            permissionGranted = true
        } else {
            permissionGranted = await CameraRecorder.requestCameraPermission()
        }
        // 开了录音就顺带申请麦克风权限；被拒绝也不影响录像，只是没有声音
        if settings.recordAudio, !CameraRecorder.hasMicrophonePermission {
            _ = await CameraRecorder.requestMicrophonePermission()
        }
        permissionChecked = true

        if permissionGranted {
            recorder.startSession()
        }
        await library.refresh()
    }
}

#Preview {
    ContentView()
}
