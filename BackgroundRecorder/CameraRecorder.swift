import AVFoundation
import AVKit
import Combine
import CoreMedia
import CoreVideo
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
/// 6. 真正让摄像头在后台持续出帧的关键：**画中画（PiP）**。
///    App Store 成熟后台录像 App 的实际方案 —— 录制中把实时画面放进 PiP 小窗，
///    小窗可见 = App 处于「使用中」状态，系统允许摄像头继续运行，录制不中断。
///    （静音音频只能保住进程不被挂起，挡不住摄像头被中断，两者缺一不可。）
///
/// ## 一条硬约束
/// 绝对不能在 App 处于后台时调用 `session.startRunning()`。
/// 系统会拒绝该调用，并立刻回敬一个
/// `AVCaptureSession.InterruptionReason.videoDeviceNotAvailableInBackground`
/// 中断 —— 这会让人误以为"系统不允许后台使用摄像头"，其实是自己踩的坑。
/// 因此所有重启会话的入口都必须先确认 `applicationState == .active`。
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

    /// 全屏预览 + 画中画内容源。
    /// AVCaptureVideoPreviewLayer 不能作为 PiP 内容源，必须用 sample buffer 显示层，
    /// 由 videoDataOutput 逐帧喂入。
    let previewLayer = AVSampleBufferDisplayLayer()

    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let videoDataQueue = DispatchQueue(label: "com.wxw.BackgroundRecorder.videodata")
    private var pipController: AVPictureInPictureController?
    private let pipPlaybackDelegate = PiPPlaybackDelegate()

    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.wxw.BackgroundRecorder.session")
    private let library: RecordingLibrary

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    /// 静音循环播放器 —— 借鉴 App Store 成熟后台录像 App 的核心保活手段。
    ///
    /// 系统判定「App 该不该留在后台」看的是它是否真的在处理音频。
    /// 仅激活 AVAudioSession + 采集麦克风，信号强度不如「有一个正在播放的播放器」。
    /// 录制期间无限循环播放一段纯静音的音频，系统就会持续认为
    /// 「这是个正在播放音频的 App」，从而不挂起进程，摄像头也就不会断。
    private var silencePlayer: AVAudioPlayer?

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
            "=== CameraRecorder 初始化 | 后台模式=\(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") ?? "缺失") ==="
        )
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

            // 启动静音循环播放（成熟方案核心，见 silencePlayer 注释）
            startSilencePlayback()

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

        // 视频数据输出：逐帧喂给 previewLayer（预览 + PiP 内容源）
        videoDataOutput.videoSettings =
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: videoDataQueue)
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            if #available(iOS 17.0, *),
               let connection = videoDataOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                // 传感器默认横置，转 90° 让送进预览层/PiP 的画面是竖直的
                connection.videoRotationAngle = 90
            }
        }

        session.commitConfiguration()

        previewLayer.videoGravity = .resizeAspectFill
        setupPictureInPictureIfNeeded()

        RecorderDiagnostics.shared.log(
            "会话配置完成 | 视频输入=\(videoInput != nil) 音频输入=\(audioInput != nil) 多任务摄像头=\(session.isMultitaskingCameraAccessEnabled)"
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
            RecorderDiagnostics.shared.log("音频会话配置失败: \(error.localizedDescription)")
            report("音频会话配置失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 静音循环播放（后台保活核心）

    /// 启动静音循环播放。录制开始时调用。
    private func startSilencePlayback() {
        guard silencePlayer == nil else { return }

        do {
            let url = try makeSilentWAVFile()
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1   // 无限循环
            player.volume = 0           // 双保险：内容本身是静音，音量再压到 0
            player.prepareToPlay()
            let playing = player.play()
            silencePlayer = playing ? player : nil
            RecorderDiagnostics.shared.log(
                "静音播放启动 | 成功=\(playing) 时长=\(player.duration)s 循环中"
            )
        } catch {
            RecorderDiagnostics.shared.log("静音播放创建失败: \(error.localizedDescription)")
            // 静音播放失败不阻断录制，只损失保活强度
        }
    }

    /// 停止静音循环播放。录制结束时调用。
    private func stopSilencePlayback() {
        guard let player = silencePlayer else { return }
        player.stop()
        silencePlayer = nil
        RecorderDiagnostics.shared.log("静音播放停止")
    }

    /// 音频被打断（来电、Siri 等）结束后，AVAudioPlayer 不会自动续播，
    /// 需要手动拉起来。录制期间调用。
    private func resumeSilencePlaybackIfNeeded() {
        guard isRecording else { return }
        if let player = silencePlayer, !player.isPlaying {
            let ok = player.play()
            RecorderDiagnostics.shared.log("静音播放续播 | 成功=\(ok)")
        } else if silencePlayer == nil {
            startSilencePlayback()
        }
    }

    /// 在临时目录生成一段 1 秒的静音 WAV（8kHz / 16bit / 单声道）。
    ///
    /// 不打包任何音频资源文件，首次调用时按需生成，之后复用。
    /// 1 秒 8kHz 的静音 PCM 只有 16KB，循环播放的 CPU 占用可忽略。
    private func makeSilentWAVFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-8000hz-16bit.wav")

        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate = 8000
        let seconds = 1
        let dataBytes = sampleRate * seconds * 2   // 16bit = 2 字节/样本，单声道

        var data = Data()
        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(36 + dataBytes))             // RIFF chunk size
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        append(16)                                 // fmt chunk size
        append16(1)                                // PCM
        append16(1)                                // 单声道
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))             // byteRate = rate * blockAlign
        append16(2)                                // blockAlign
        append16(16)                               // bits per sample
        data.append("data".data(using: .ascii)!)
        append(UInt32(dataBytes))
        data.append(Data(count: dataBytes))        // 全 0 = 静音

        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - 画中画（后台保活核心 v2）

    /// App Store 成熟后台录像 App 的真实方案：录制中把实时画面放进画中画小窗。
    /// 小窗可见 = App 处于「使用中」状态 → 系统允许摄像头继续出帧 → 录制不中断。
    /// `canStartPictureInPictureAutomaticallyFromInlinePiP = true` 后，
    /// 用户切走的瞬间系统自动弹出小窗，无需任何手动操作。
    private func setupPictureInPictureIfNeeded() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            RecorderDiagnostics.shared.log("PiP 不受此设备支持（后台录制将不可靠）")
            return
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: previewLayer,
            playbackDelegate: pipPlaybackDelegate
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        pipController = controller
        RecorderDiagnostics.shared.log("PiP 已配置（切到后台自动弹小窗，摄像头因此保持活跃）")
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
            RecorderDiagnostics.shared.log("采集中断结束")

            // 只在 App 处于前台时才重启会话。
            // 在后台调用 startRunning() 会被系统拒绝，并立刻触发
            // videoDeviceNotAvailableInBackground 中断（见类注释里的硬约束）。
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

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleAudioInterruption(note)
        })
    }

    private func handleEnterBackground() {
        appIsInBackground = true
        RecorderDiagnostics.shared.log(
            "进入后台 | 录制中=\(isRecording) 会话运行=\(session.isRunning) 静音播放=\(silencePlayer?.isPlaying ?? false) 已录=\(movieOutput.isRecording ? CMTimeGetSeconds(movieOutput.recordedDuration) : 0)s"
        )

        // 静音播放若意外停止（来电打断等），立刻拉起来——它是保活的核心
        if isRecording, silencePlayer?.isPlaying != true {
            RecorderDiagnostics.shared.log("进后台发现静音播放停止，重新启动")
            startSilencePlayback()
        }

        // PiP 状态快照 + 2 秒后复查（自动弹窗发生在切走的瞬间，2 秒后能看清结果）
        RecorderDiagnostics.shared.log(
            "PiP | 支持=\(AVPictureInPictureController.isPictureInPictureSupported()) 活动=\(pipController?.isPictureInPictureActive ?? false)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            RecorderDiagnostics.shared.log(
                "进后台2秒后 | PiP活动=\(self.pipController?.isPictureInPictureActive ?? false) 会话运行=\(self.session.isRunning) 录制中=\(self.movieOutput.isRecording)"
            )
        }

        // 主动刷新音频会话：系统判断"这个 App 该不该留在后台"的依据是
        // 它是否真的在处理音频。进后台时重新激活一次，强化这个身份。
        sessionQueue.async { [weak self] in
            self?.activateAudioSession()
        }

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
        RecorderDiagnostics.shared.log(
            "回到前台 | 录制中=\(isRecording) 会话运行=\(session.isRunning)"
        )

        // 若系统在后台停掉了会话（被其它 App 抢占摄像头、锁屏等），回前台时恢复
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.activateAudioSession()
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
        case .videoDeviceInUseByAnotherClient, .audioDeviceInUseByAnotherClient:
            report("摄像头被其它 App 占用，录制已中断")
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            report("分屏模式下摄像头不可用")
        case .videoDeviceNotAvailableDueToSystemPressure:
            report("设备过热，摄像头暂时不可用")
        case .videoDeviceNotAvailableInBackground:
            // 多任务切换、锁屏等场景下系统会临时禁止后台使用摄像头，这是正常现象。
            // 回到前台时 handleEnterForeground 会自动重启会话，所以只记日志，
            // 不弹窗打断用户（否则会造成"后台录制失败"的错误印象）。
            RecorderDiagnostics.shared.log("原因: 系统临时禁止后台摄像头，回前台自动恢复，不提示用户")
        case .sensitiveContentMitigationActivated:
            // iOS 18+ 敏感内容遮蔽（防偷拍）：系统在检测到遮蔽动作时暂停摄像头
            RecorderDiagnostics.shared.log("原因: 系统敏感内容遮蔽触发，摄像头被临时暂停")
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
            // 打断结束后续播静音（AVAudioPlayer 被打断后不会自动恢复）
            resumeSilencePlaybackIfNeeded()
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

            self.stopSilencePlayback()
            self.pipController?.stopPictureInPicture()

            RecorderDiagnostics.shared.log(
                "录制结束 | 文件=\(outputFileURL.lastPathComponent) error=\(error?.localizedDescription ?? "无")"
            )

            // 注意：AVErrorRecordingSuccessfullyFinishedKey 是 NSError 的 userInfo key，
            // 不是 AVError.Code。它等于 true 时表示"虽然带了 error，但文件本身是完整的"，
            // 属于正常结束，不应该报给用户。
            let nsError = error as NSError?
            let finishedSuccessfully =
                (nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false

            if let error, !finishedSuccessfully {
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

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // 层进入 failed 状态（如来电打断后）需要 flush 才能继续接收
        if previewLayer.status == .failed {
            previewLayer.flush()
        }
        previewLayer.enqueue(sampleBuffer)
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension CameraRecorder: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        RecorderDiagnostics.shared.log("PiP 已启动 —— 画面小窗可见，摄像头保持活跃，录制不中断")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        RecorderDiagnostics.shared.log("PiP 启动失败: \(error.localizedDescription)")
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        RecorderDiagnostics.shared.log("PiP 已停止")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // 用户点小窗回 App，直接完成恢复
        completionHandler(true)
    }
}

// MARK: - PiP 播放委托（实时流没有快进/暂停概念，实现成恒定"播放中"即可）

private final class PiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {

    /// 实时流没有可回溯的时间轴，返回一个从 0 到无穷的区间
    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(value: 0, timescale: 600),
            duration: CMTime.positiveInfinity
        )
    }

    /// 实时流永远处于"播放中"
    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    /// 实时流不支持快进/快退，直接完成回调。
    /// （async 版本由协议默认实现派生，不要显式实现，否则两个方法会映射到
    ///  同一个 Objective-C 选择器产生冲突。）
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion: @escaping @Sendable () -> Void
    ) {
        completion()
    }

    // 以下是旧版协议的成员，保留空实现以兼容旧 SDK
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    func pictureInPictureControllerTimeRangeDidChange(
        _ pictureInPictureController: AVPictureInPictureController
    ) {}

    func pictureInPictureControllerIsPlaybackPausedDidChange(
        _ pictureInPictureController: AVPictureInPictureController
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}
}
