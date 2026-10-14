import AVFoundation
import SwiftUI

@MainActor
struct ContentView: View {
    @StateObject private var library: RecordingLibrary
    @StateObject private var recorder: CameraRecorder

    @State private var permissionChecked = false
    @State private var permissionGranted = false
    @State private var showLibrary = false
    /// 录制前的屏幕亮度，录制结束时恢复
    @State private var originalBrightness: CGFloat?

    init() {
        // 让 recorder 与 library 共用同一个实例，录制结束就直接刷新列表
        let library = RecordingLibrary()
        _library = StateObject(wrappedValue: library)
        _recorder = StateObject(wrappedValue: CameraRecorder(library: library))
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

            VStack(spacing: 0) {
                statusBar
                Spacer()
                controlBar
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 30)
        }
        .task { await bootstrap() }
        .onChange(of: recorder.isRecording) { _, recording in
            dimScreen(recording)
        }
        .sheet(isPresented: $showLibrary) {
            RecordingListView(library: library)
        }
        .alert("提示", isPresented: errorBinding) {
            Button("好", role: .cancel) { recorder.errorMessage = nil }
        } message: {
            Text(recorder.errorMessage ?? "")
        }
    }

    // MARK: - 顶部

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
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer(minLength: 0)

            Label(
                recorder.appIsInBackground ? "后台录制中" : "前台",
                systemImage: recorder.appIsInBackground ? "moon.stars.fill" : "sun.max.fill"
            )
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(recorder.appIsInBackground ? Color.green : Color.white)
        }
        .animation(.snappy, value: recorder.isRecording)
        .animation(.snappy, value: recorder.appIsInBackground)
    }

    // MARK: - 底部

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
                recorder.switchCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(recorder.isRecording || !permissionGranted)
            .opacity(recorder.isRecording ? 0.35 : 1)
        }
        .animation(.snappy, value: recorder.isRecording)
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

    /// 录制时把屏幕压到接近全黑（成熟后台录像 App 的标配：省电 + 防窥），
    /// 停止时恢复用户原来的亮度。
    private func dimScreen(_ dim: Bool) {
        if dim {
            if originalBrightness == nil {
                originalBrightness = UIScreen.main.brightness
            }
            UIScreen.main.brightness = 0.05
        } else if let brightness = originalBrightness {
            UIScreen.main.brightness = brightness
            originalBrightness = nil
        }
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
