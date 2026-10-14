import AVFoundation
import Combine
import CoreMedia
import UIKit

/// 摄像头录像器 —— 纯视频，不采集音频。
///
/// ## 为什么不做「后台录像」
/// iPhone 上第三方 App **无法**在切到其他 App 后继续使用摄像头：系统会在 App
/// 离开前台的瞬间中断采集会话（`videoDeviceNotAvailableInBackground`）。
/// 唯一的官方通道叫「多任务摄像头访问」，但 Apple 文档要求以下三条**同时**满足：
///
/// 1. 运行在支持 Stage Manager 外接显示的 **iPad** 上；
/// 2. 链接 iOS 18+，且 `UIBackgroundModes` 包含 `voip`；
/// 3. 持有 `com.apple.developer.avfoundation.multitasking-camera-access` entitlement。
///
/// iPhone 在第一条就不满足，所以本 App 的定位是**前台录像**：
/// 录制期间把屏幕压到接近全黑（看起来像待机），实际一直在录。详见 README。
///
/// 为什么不用音频相关的手段（静音音频保活、后台音频模式、画中画）：
/// 它们只能让**进程**留在后台，挡不住**摄像头**被中断 —— 实测日志中
/// 摄像头在切走 0.12 秒后就被中断。既然解决不了问题，就不引入这些
/// 会增加耗电和 App Store 审核风险的东西。
final class CameraRecorder: NSObject, ObservableObject {

    // MARK: - 对外发布状态

    @Published private(set) var isConfigured = false
    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var appIsInBackground = false
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back
    @Published var errorMessage: String?

    // MARK: - 采集核心

    let session = AVCaptureSession()

    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.wxw.BackgroundRecorder.session")
    private let library: RecordingLibrary

    private var videoInput: AVCaptureDeviceInput?

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var durationTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var isConfiguredLocked = false
    private var idleTimerWasDisabled = false

    // MARK: - 生命周期

    init(library: RecordingLibrary) {
        self.library = library
        super.init()
        registerObservers()
        RecorderDiagnostics.shared.log(
            "=== CameraRecorder 初始化 | 纯视频模式（无音频）| 部署目标 iOS 17+ ==="
        )
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - 权限（只需要相机）

    /// 请求相机权限。
    static func requestCameraPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    static var hasCameraPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    // MARK: - 会话

    /// 配置并启动采集会话。可重复调用。
    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSessionIfNeeded()
            if !self.session.isRunning {
                RecorderDiagnostics.shared.log("启动采集会话")
                self.session.startRunning()
            }
            DispatchQueue.main.async { self.isConfigured = true }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning {
                RecorderDiagnostics.shared.log("停止采集会话")
                self.session.stopRunning()
            }
        }
    }

    // MARK: - 录制控制

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !movieOutput.isRecording else { return }

        do {
            let url = try library.makeNewRecordingURL()
            applyVideoRotation()
            movieOutput.startRecording(to: url, recordingDelegate: self)

            RecorderDiagnostics.shared.log(
                "开始录制 -> \(url.lastPathComponent) | 在前台=\(UIApplication.shared.applicationState == .active)"
            )

            idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true

            isRecording = true
            duration = 0
            startDurationTimer()
        } catch {
            report("无法创建录像文件：\(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        RecorderDiagnostics.shared.log(
            "手动停止录制 | 已录=\(CMTimeGetSeconds(movieOutput.recordedDuration))s"
        )
        // 分片写入模式下，stopRecording 会立刻把 moov 补全成完整文件
        movieOutput.stopRecording()
    }

    // MARK: - 摄像头切换

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self, !self.movieOutput.isRecording, let current = self.videoInput else { return }

            let target: AVCaptureDevice.Position = current.device.position == .back ? .front : .back
            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: target),
                let newInput = try? AVCaptureDeviceInput(device: device)
            else { return }

            self.session.beginConfiguration()
            self.session.removeInput(current)

            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
                DispatchQueue.main.async { self.cameraPosition = target }
            } else {
                self.session.addInput(current)
            }

            self.session.commitConfiguration()
        }
    }

    // MARK: - 会话配置（必须在 sessionQueue 上执行）

    private func configureSessionIfNeeded() {
        guard !isConfiguredLocked else { return }
        isConfiguredLocked = true

        session.beginConfiguration()
        session.sessionPreset = .high

        // 只加视频输入：不采集音频，录出的 .mov 里没有音轨
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            configureFrameRate(for: device, target: 30)
        } else {
            report("无法访问摄像头")
        }

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        movieOutput.minFreeDiskSpaceLimit = 100 * 1024 * 1024

        // 2 秒一个分片（fragmented MP4）：进程被杀/崩溃时，已写入磁盘的部分
        // 依然是可播放的完整文件，不会留下一个打不开的残file
        movieOutput.movieFragmentInterval = CMTime(value: 2, timescale: 1)

        session.commitConfiguration()

        RecorderDiagnostics.shared.log(
            "会话配置完成 | 视频输入=\(videoInput != nil) 音频输入=false（纯视频）"
        )
    }

    private func configureFrameRate(for device: AVCaptureDevice, target: Double) {
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= target && target <= $0.maxFrameRate
        }
        guard supported else { return }

        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1, timescale: CMTimeScale(target))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            // 帧率设置失败不影响录制，忽略
        }
    }

    private func applyVideoRotation() {
        guard let connection = movieOutput.connection(with: .video) else { return }

        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    // MARK: - 时长

    private func startDurationTimer() {
        durationTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.movieOutput.isRecording else { return }
            // 用 output 的实际已录时长，比自己计时更准
            let seconds = CMTimeGetSeconds(self.movieOutput.recordedDuration)
            self.duration = seconds.isFinite ? seconds : 0
        }
        RunLoop.main.add(timer, forMode: .common)
        durationTimer = timer
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    // MARK: - 前后台与打断

    private func registerObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleEnterBackground()
        })

        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleEnterForeground()
        })

        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        })

        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            RecorderDiagnostics.shared.log("采集中断结束")

            // 只在 App 处于前台时才重启会话。
            // 在后台调用 startRunning() 会被系统拒绝，并立刻触发
            // videoDeviceNotAvailableInBackground 中断。
            guard UIApplication.shared.applicationState == .active else {
                RecorderDiagnostics.shared.log("当前在后台，推迟重启会话，等回前台再恢复")
                return
            }

            self.sessionQueue.async {
                if !self.session.isRunning {
                    RecorderDiagnostics.shared.log("会话未运行，正在重启")
                    self.session.startRunning()
                }
            }
        })

        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            RecorderDiagnostics.shared.log("采集运行时错误: \(error?.localizedDescription ?? "未知")")
            self?.report("采集运行时错误：\(error?.localizedDescription ?? "未知")")
        })
    }

    private func handleEnterBackground() {
        appIsInBackground = true
        RecorderDiagnostics.shared.log(
            "进入后台 | 录制中=\(isRecording) 会话运行=\(session.isRunning) 已录=\(movieOutput.isRecording ? CMTimeGetSeconds(movieOutput.recordedDuration) : 0)s"
        )

        // 兜底：多争取几秒执行时间，让录制能干净收尾（写入 moov）
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "BackgroundRecorder.FinishRecording"
            ) { [weak self] in
                self?.endBackgroundTask()
            }
        }
    }

    private func handleEnterForeground() {
        appIsInBackground = false
        endBackgroundTask()
        RecorderDiagnostics.shared.log(
            "回到前台 | 录制中=\(isRecording) 会话运行=\(session.isRunning)"
        )

        // 系统在后台停掉了会话，回前台时恢复预览
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning {
                RecorderDiagnostics.shared.log("会话已停止，回前台后重启")
                self.session.startRunning()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func handleInterruption(_ note: Notification) {
        guard
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
            let reason = AVCaptureSession.InterruptionReason(rawValue: raw)
        else { return }

        RecorderDiagnostics.shared.log(
            "采集中断 | reason=\(raw) 在前台=\(UIApplication.shared.applicationState == .active) 录制中=\(isRecording)"
        )

        switch reason {
        case .videoDeviceNotAvailableInBackground:
            // 这是预期行为：App 离开前台，系统禁止使用摄像头。
            // 回前台时 handleEnterForeground 会自动重启会话，所以只记日志不弹窗。
            RecorderDiagnostics.shared.log("原因: App 不在前台，系统禁止使用摄像头（iPhone 的平台限制）")
        case .videoDeviceInUseByAnotherClient, .audioDeviceInUseByAnotherClient:
            report("摄像头被其它 App 占用，录制已中断")
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            RecorderDiagnostics.shared.log("原因: 多任务场景下摄像头不可用")
        case .videoDeviceNotAvailableDueToSystemPressure:
            report("设备过热，摄像头暂时不可用")
        case .sensitiveContentMitigationActivated:
            RecorderDiagnostics.shared.log("原因: 系统敏感内容遮蔽触发，摄像头被临时暂停")
        @unknown default:
            report("采集被系统中断")
        }
    }

    // MARK: - 工具

    private func report(_ message: String) {
        if Thread.isMainThread {
            errorMessage = message
        } else {
            DispatchQueue.main.async { self.errorMessage = message }
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        // 无需处理
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // 该回调在 AVCapture 的内部队列上触发，所有状态更新必须切回主线程
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.stopDurationTimer()
            self.isRecording = false
            self.duration = 0
            UIApplication.shared.isIdleTimerDisabled = self.idleTimerWasDisabled

            RecorderDiagnostics.shared.log(
                "录制结束 | 文件=\(outputFileURL.lastPathComponent) error=\(error?.localizedDescription ?? "无")"
            )

            // 注意：AVErrorRecordingSuccessfullyFinishedKey 是 NSError 的 userInfo key，
            // 不是 AVError.Code。它等于 true 时表示"虽然带了 error，但文件本身是完整的"，
            // 属于正常结束，不应该报给用户。
            let nsError = error as NSError?
            let finishedSuccessfully =
                (nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false

            let appInBackground = self.appIsInBackground
            if let error, !finishedSuccessfully, !appInBackground {
                self.report("录制结束异常：\(error.localizedDescription)")
            }

            // 0 字节文件直接删掉，避免列表里出现坏条目
            if let attributes = try? FileManager.default.attributesOfItem(atPath: outputFileURL.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue == 0 {
                try? FileManager.default.removeItem(at: outputFileURL)
            }

            let library = self.library
            Task { await library.refresh() }
        }
    }
}
