import AVFoundation
import Combine
import CoreMedia
import UIKit

/// 摄像头录像器。
///
/// 关于「后台录像」的实现要点（iOS 没有官方的后台摄像头 API）：
/// 1. `Info.plist` 声明 `UIBackgroundModes = [audio]`，App 退到后台不会被立刻挂起；
/// 2. `AVAudioSession` 使用 `.playAndRecord` + `.videoRecording` 并保持 active，
///    这是系统判定「我有正当后台理由」的依据；
/// 3. 采集会话里必须包含麦克风输入，否则系统会停掉整个会话；
/// 4. `movieFragmentInterval` 设为 2 秒做分片写入，这样即使进程被系统杀掉，
///    已经写入磁盘的部分依然是一个可播放的完整文件；
/// 5. 额外用 `beginBackgroundTask` 做一层兜底，争取更多执行时间片。
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
    private var audioInput: AVCaptureDeviceInput?

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
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - 权限

    static func requestPermissions() async -> (camera: Bool, microphone: Bool) {
        async let camera = AVCaptureDevice.requestAccess(for: .video)
        async let microphone = AVCaptureDevice.requestAccess(for: .audio)
        return await (camera, microphone)
    }

    static var hasPermissions: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - 会话

    /// 配置并启动采集会话。可重复调用。
    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSessionIfNeeded()
            self.activateAudioSession()
            if !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async { self.isConfigured = true }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
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

        // 视频输入
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            configureFrameRate(for: device, target: 30)
        } else {
            report("无法访问摄像头")
        }

        // 音频输入 —— 后台录制能持续的前提，不能省
        if let device = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }

        // 文件输出
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        movieOutput.minFreeDiskSpaceLimit = 100 * 1024 * 1024

        // 关键：2 秒一个分片（fragmented MP4），进程被杀也不丢已写入的内容
        movieOutput.movieFragmentInterval = CMTime(value: 2, timescale: 1)

        // iPad / iOS 16+：允许本 App 不在前台时继续使用摄像头（官方 API）
        // 注意这两个都是 AVCaptureSession 的属性，不是 AVCaptureDevice 的
        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }

        session.commitConfiguration()
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

    private func activateAudioSession() {
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try audio.setActive(true, options: [])
        } catch {
            report("音频会话配置失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 时长

    private func startDurationTimer() {
        durationTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.movieOutput.isRecording else { return }
            // 用 output 的实际已录时长，比自己计时更准（后台 Timer 会被降频）
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
            self.sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
            }
        })

        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.report("采集运行时错误：\(error?.localizedDescription ?? "未知")")
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleAudioInterruption(note)
        })
    }

    private func handleEnterBackground() {
        appIsInBackground = true

        // 兜底：再要一段后台执行时间，配合 audio 后台模式形成双保险
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "BackgroundRecorder.KeepRecording"
            ) { [weak self] in
                self?.endBackgroundTask()
            }
        }
    }

    private func handleEnterForeground() {
        appIsInBackground = false
        endBackgroundTask()

        // 若系统在后台停掉了会话（例如被其它 App 抢占摄像头），回前台时恢复
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.activateAudioSession()
            if !self.session.isRunning { self.session.startRunning() }
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

        switch reason {
        case .videoDeviceInUseByAnotherClient, .audioDeviceInUseByAnotherClient:
            report("摄像头被其它 App 占用，录制已中断")
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            report("分屏模式下摄像头不可用")
        case .videoDeviceNotAvailableDueToSystemPressure:
            report("设备过热，摄像头暂时不可用")
        case .videoDeviceNotAvailableInBackground:
            report("系统不允许在后台使用摄像头，采集已停止")
        @unknown default:
            report("采集被系统中断")
        }
    }

    private func handleAudioInterruption(_ note: Notification) {
        guard
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        if type == .ended {
            sessionQueue.async { [weak self] in
                self?.activateAudioSession()
            }
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

            // AVError.recordingSuccessfullyFinished 表示"虽然报错但文件是好的"，不算失败
            if let avError = error as? AVError, avError.code == .recordingSuccessfullyFinished {
                // 正常结束
            } else if let error {
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
