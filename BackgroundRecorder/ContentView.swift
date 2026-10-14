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

    /// 隐身模式下控件是否被临时唤出
    @State private var controlsRevealed = false
    /// 用于作废上一次的自动隐藏
    @State private var revealGeneration = 0

    init() {
        let library = RecordingLibrary()
        let settings = RecordingSettings()
        _library = StateObject(wrappedValue: library)
        _settings = StateObject(wrappedValue: settings)
        _recorder = StateObject(wrappedValue: CameraRecorder(library: library, settings: settings))
    }

    /// 隐身状态：开关打开 + 正在录制 + 控件未唤出
    private var stealthActive: Bool {
        settings.stealthMode && recorder.isRecording && !controlsRevealed
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
        // 保持「唤出控件时恢复、自动隐藏后再次关闭」的节奏与亮度调节一致。
        .statusBarHidden(stealthActive)
        .persistentSystemOverlays(stealthActive ? .hidden : .automatic)
        .task { await bootstrap() }
        .onChange(of: recorder.isRecording) { _, recording in
            if !recording { controlsRevealed = false }
            applyBrightness()
        }
        .onChange(of: controlsRevealed) { _, _ in applyBrightness() }
        .onChange(of: settings.stealthMode) { _, _ in applyBrightness() }
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

    /// 全黑覆盖层：轻点唤出控件，长按 1.2 秒停止录制。
    /// 参考同类 App（QuietCam / NoCam）的「隐身模式」，但额外做了防误触 ——
    /// 放在口袋里蹭到屏幕不会把录制停掉。
    private var stealthOverlay: some View {
        Color.black
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { revealControls() }
            .onLongPressGesture(minimumDuration: 1.2) {
                controlsRevealed = true
                recorder.stopRecordingByUser()
            }
            .overlay(alignment: .topTrailing) {
                // 极暗的红点：表示正在录制。长按可停，但先要有可见的录制状态
                Circle()
                    .fill(.red.opacity(0.22))
                    .frame(width: 6, height: 6)
                    .padding(16)
            }
            .overlay(alignment: .bottom) {
                Text("轻点唤出控件 · 长按 1.2 秒停止")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.16))
                    .padding(.bottom, 24)
            }
    }

    private func revealControls() {
        controlsRevealed = true
        revealGeneration += 1
        let generation = revealGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if revealGeneration == generation { controlsRevealed = false }
        }
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
