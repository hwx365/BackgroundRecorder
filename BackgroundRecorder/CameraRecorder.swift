import AVFoundation
import Combine
import CoreMedia
import UIKit

/// 摄像头录像器 —— 支持录音（可开关）、循环分段与中断续录。
///
/// ## 为什么不做「后台录像」
/// iPhone 上第三方 App **无法**在切到其他 App 后继续使用摄像头：系统会在 App
/// 离开前台的瞬间中断采集会话（`videoDeviceNotAvailableInBackground`）。
/// 唯一的官方通道「多任务摄像头访问」要求三条同时满足：
///
/// 1. 运行在支持 Stage Manager 外接显示的 **iPad** 上；
/// 2. 链接 iOS 18+，且 `UIBackgroundModes` 包含 `voip`；
/// 3. 持有 `com.apple.developer.avfoundation.multitasking-camera-access` entitlement。
///
/// iPhone 在第一条就不满足 —— App Store 上标榜「后台录像」的同类应用，
/// 在 iPhone 上做的其实都是「前台录制 + 黑屏伪装」。本 App 同样如此，
/// 但补上了它们普遍缺失的三件事：**中断自动续录、循环分段、容量自管理**。
///
/// ## 三个关键机制
/// - **分段**：`movieOutput.maxRecordedDuration` 到点后自动接下一段，
///   任何一段损坏都不影响其他段，单文件也不会大到无法管理。
/// - **续录**：被系统中断（切走、来电、被抢占）后，`resumeOnForeground`
///   标记待续，回到前台自动起一段新的，录制不会因一次中断而彻底结束。
/// - **容量自管理**：超过容量上限自动淘汰最旧的文件；空间不足时提前停止，
///   避免录到一半把手机写满。
final class CameraRecorder: NSObject, ObservableObject {

    // MARK: - 对外发布状态

    @Published private(set) var isConfigured = false
    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var appIsInBackground = false
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back
    /// 当前是第几段（1 起算）
    @Published private(set) var segmentIndex = 0
    @Published private(set) var torchAvailable = false
    @Published private(set) var torchOn = false
    /// 当前是否真的在采集声音（设置开启 且 麦克风已授权）
    @Published private(set) var audioRecordingEnabled = false
    /// 用户开启了录音，但麦克风权限被拒绝
    @Published private(set) var microphoneDenied = false
    /// 自动降画质的说明，nil 表示未降级
    @Published private(set) var downgradeNotice: String?
    /// 存储相关提示（自动清理 / 空间不足）
    @Published private(set) var storageNotice: String?
    @Published var errorMessage: String?

    // MARK: - 采集核心

    let session = AVCaptureSession()

    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.wxw.BackgroundRecorder.session")
    private let library: RecordingLibrary
    private let settings: RecordingSettings

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var durationTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var isConfiguredLocked = false
    private var idleTimerWasDisabled = false

    /// 用户按下录制后为 true：表示这是一次「持续录制会话」。
    /// 分段到点会自动接下一段；用户主动停止时置回 false。
    private var sessionActive = false
    /// 因离开前台等系统原因被中断，回前台后需要自动接续
    private var resumeOnForeground = false

    /// 开始每段前的剩余空间下限
    private let minimumFreeBytes: Int64 = 300 * 1024 * 1024

    // MARK: - 生命周期

    init(library: RecordingLibrary, settings: RecordingSettings) {
        self.library = library
        self.settings = settings
        super.init()
        // 注册给快捷指令 / 操作按钮使用
        RecorderBridge.shared.recorder = self
        registerObservers()
        RecorderDiagnostics.shared.log(
            "=== CameraRecorder 初始化 | 录音=\(settings.recordAudio) | 画质=\(settings.quality.title) | 分段=\(settings.segment.title) ==="
        )
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - 权限

    static func requestCameraPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    static func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var hasCameraPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - 会话

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSessionIfNeeded()
            self.applyPresetIfNeeded()
            if !self.session.isRunning {
                RecorderDiagnostics.shared.log("启动采集会话")
                self.session.startRunning()
            }
            DispatchQueue.main.async { self.isConfigured = true }
        }
    }

    func stopSession() {
        sessionActive = false
        resumeOnForeground = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning {
                RecorderDiagnostics.shared.log("停止采集会话")
                self.session.stopRunning()
            }
        }
    }

    /// 画质设置变化后调用
    func applyQualitySetting() {
        sessionQueue.async { [weak self] in
            self?.applyPresetIfNeeded()
        }
    }

    // MARK: - 录制控制

    func toggleRecording() {
        if isRecording {
            stopRecordingByUser()
        } else {
            sessionActive = true
            resumeOnForeground = false
            storageNotice = nil
            segmentIndex = 1
            RecorderDiagnostics.shared.log("用户开始录制（分段模式：\(settings.segment.title)）")
            startNextSegment()
        }
    }

    /// 供快捷指令 / 操作按钮调用：确保采集会话就绪后再开始录制。
    /// 冷启动（App 刚被操作按钮唤起）时，ContentView 的初始化可能还没跑完，
    /// 这里先幂等地把会话拉起来。
    func startRecordingFromShortcut() {
        guard !isRecording else { return }
        RecorderDiagnostics.shared.log("快捷指令触发开始录制")
        startSession()
        toggleRecording()
    }

    /// 用户主动停止。会终止整段持续会话，不再自动续录。
    func stopRecordingByUser() {
        sessionActive = false
        resumeOnForeground = false
        RecorderDiagnostics.shared.log("用户停止录制（第 \(segmentIndex) 段）")
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }

    private func startNextSegment() {
        guard !movieOutput.isRecording, sessionActive else { return }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            // 会话可能刚被中断过，先确保在跑
            if !self.session.isRunning { self.session.startRunning() }
            self.applyPresetIfNeeded()
            // 录音开关或麦克风权限可能刚变过，开新分段前同步一次
            self.updateAudioInputLocked()
            DispatchQueue.main.async { self.beginSegment() }
        }
    }

    private func beginSegment() {
        guard !movieOutput.isRecording, sessionActive else { return }

        // 1) 容量上限：超出就先淘汰最旧的
        let limit = settings.storageLimit.bytes
        if limit > 0 {
            let removed = library.enforceStorageLimitOnDisk(limitBytes: limit)
            if removed > 0 {
                storageNotice = "已自动清理最旧的 \(removed) 个录像（容量上限 \(settings.storageLimit.title)）"
                let library = self.library
                Task { await library.refresh() }
            }
        }

        // 2) 剩余空间检查：不够就别开始，免得录到一半写满
        let free = library.freeDiskSpaceBytes()
        if free > 0, free < minimumFreeBytes {
            storageNotice = "剩余空间不足（\(RecordingLibrary.formattedSize(free))），已停止"
            RecorderDiagnostics.shared.log("拒绝开始新分段：剩余空间 \(RecordingLibrary.formattedSize(free))")
            sessionActive = false
            report("存储空间不足，已停止录制。请清理后重试。")
            return
        }

        do {
            let url = try library.makeNewRecordingURL(segmentIndex: segmentIndex)
            applyVideoRotation()
            applySegmentLength()
            movieOutput.startRecording(to: url, recordingDelegate: self)

            RecorderDiagnostics.shared.log(
                "开始录制第 \(segmentIndex) 段 -> \(url.lastPathComponent) | 录音=\(audioRecordingEnabled) | 剩余空间 \(RecordingLibrary.formattedSize(free))"
            )

            idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true

            isRecording = true
            duration = 0
            startDurationTimer()
        } catch {
            sessionActive = false
            report("无法创建录像文件：\(error.localizedDescription)")
        }
    }

    private func applySegmentLength() {
        let seconds = settings.segment.seconds
        movieOutput.maxRecordedDuration = seconds > 0
            ? CMTime(seconds: seconds, preferredTimescale: 600)
            : .invalid
    }

    // MARK: - 画质（含低电量 / 过热自动降级）

    /// 必须在 sessionQueue 上调用，且不能在录制中切换 preset
    private func applyPresetIfNeeded() {
        guard !movieOutput.isRecording else { return }

        // 先决定"应该用哪一档画质"，最后再换算成 preset
        var quality = settings.quality
        var notice: String?

        if settings.autoDowngrade {
            let info = ProcessInfo.processInfo

            if info.isLowPowerModeEnabled {
                quality = RecordingQuality.lower(quality, .hd720p)
                notice = "低电量模式：已自动切换为 720p"
            }

            switch info.thermalState {
            case .fair:
                quality = RecordingQuality.lower(quality, .hd720p)
                notice = notice ?? "机身偏热：已自动切换为 720p"
            case .serious:
                quality = RecordingQuality.lower(quality, .hd720p)
                notice = "机身较热：已自动切换为 720p"
            case .critical:
                quality = .vga
                notice = "机身过热：已自动切换为 480p"
            case .nominal:
                break
            @unknown default:
                break
            }
        }

        let desired = quality.preset

        if session.sessionPreset != desired {
            session.beginConfiguration()
            session.sessionPreset = desired
            session.commitConfiguration()
            RecorderDiagnostics.shared.log("画质切换 -> \(desired.rawValue) | \(notice ?? "按设置")")
        }

        DispatchQueue.main.async { self.downgradeNotice = notice }
    }

    // MARK: - 手电筒

    func toggleTorch() {
        setTorch(!torchOn)
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                if on, device.isTorchAvailable {
                    device.torchMode = .on
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.torchOn = on && device.torchMode == .on }
                RecorderDiagnostics.shared.log("手电筒 -> \(on ? "开" : "关")")
            } catch {
                RecorderDiagnostics.shared.log("手电筒设置失败: \(error.localizedDescription)")
            }
        }
    }

    private func refreshTorchAvailability() {
        let available = videoInput?.device.hasTorch ?? false
        DispatchQueue.main.async { self.torchAvailable = available }
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
                DispatchQueue.main.async {
                    self.cameraPosition = target
                    self.torchOn = false
                }
            } else {
                self.session.addInput(current)
            }

            self.session.commitConfiguration()
            self.refreshTorchAvailability()
        }
    }

    // MARK: - 会话配置（必须在 sessionQueue 上执行）

    private func configureSessionIfNeeded() {
        guard !isConfiguredLocked else { return }
        isConfiguredLocked = true

        session.beginConfiguration()
        session.sessionPreset = settings.quality.preset

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

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        movieOutput.minFreeDiskSpaceLimit = 100 * 1024 * 1024

        // 2 秒一个分片（fragmented MP4）：进程崩溃或被杀，已写入磁盘的部分
        // 依然是可播放的完整文件
        movieOutput.movieFragmentInterval = CMTime(value: 2, timescale: 1)

        session.commitConfiguration()

        RecorderDiagnostics.shared.log(
            "会话配置完成 | 视频输入=\(videoInput != nil) | preset=\(session.sessionPreset.rawValue)"
        )
        refreshTorchAvailability()

        // 麦克风输入按「设置开关 + 系统权限」决定（内部会另起一次配置）
        updateAudioInputLocked()
    }

    // MARK: - 录音（可开关）

    /// 设置界面改了录音开关、或系统权限变化后调用
    func applyAudioSetting() {
        sessionQueue.async { [weak self] in
            self?.updateAudioInputLocked()
        }
    }

    /// 必须在 sessionQueue 上调用，且不能在录制过程中改动音频输入
    private func updateAudioInputLocked() {
        guard !movieOutput.isRecording else { return }

        let authorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let wantAudio = settings.recordAudio && authorized

        if wantAudio, audioInput == nil {
            guard let device = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                RecorderDiagnostics.shared.log("接入麦克风失败")
                publishAudioState(enabled: false, denied: false)
                return
            }
            session.beginConfiguration()
            session.addInput(input)
            session.commitConfiguration()
            audioInput = input
            RecorderDiagnostics.shared.log("已接入麦克风：录像将包含声音")
        } else if !wantAudio, let existing = audioInput {
            session.beginConfiguration()
            session.removeInput(existing)
            session.commitConfiguration()
            audioInput = nil
            RecorderDiagnostics.shared.log("已移除麦克风：本次为纯视频录制")
        }

        publishAudioState(enabled: audioInput != nil, denied: settings.recordAudio && !authorized)
    }

    private func publishAudioState(enabled: Bool, denied: Bool) {
        DispatchQueue.main.async {
            self.audioRecordingEnabled = enabled
            self.microphoneDenied = denied
        }
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

    // MARK: - 前后台、打断与系统状态

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

            // 只在 App 处于前台时才重启会话：后台调用 startRunning() 会被拒绝，
            // 并立刻触发 videoDeviceNotAvailableInBackground 中断。
            guard UIApplication.shared.applicationState == .active else {
                RecorderDiagnostics.shared.log("当前在后台，推迟重启会话")
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

        // 机身过热 / 低电量：自动降画质
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            RecorderDiagnostics.shared.log("热状态变化: rawValue=\(ProcessInfo.processInfo.thermalState.rawValue)")
            self?.applyQualitySetting()
        })

        observers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            RecorderDiagnostics.shared.log("低电量模式: \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
            self?.applyQualitySetting()
        })
    }

    private func handleEnterBackground() {
        appIsInBackground = true
        RecorderDiagnostics.shared.log(
            "进入后台 | 录制中=\(isRecording) 分段=\(segmentIndex) 会话运行=\(session.isRunning) 已录=\(movieOutput.isRecording ? CMTimeGetSeconds(movieOutput.recordedDuration) : 0)s"
        )

        // 兜底：争取一点时间让当前分段干净收尾（写入 moov）
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "BackgroundRecorder.FinishSegment"
            ) { [weak self] in
                self?.endBackgroundTask()
            }
        }
    }

    private func handleEnterForeground() {
        appIsInBackground = false
        endBackgroundTask()
        RecorderDiagnostics.shared.log(
            "回到前台 | 录制中=\(isRecording) 待续录=\(resumeOnForeground) 会话运行=\(session.isRunning)"
        )

        sessionQueue.async { [weak self] in
            guard let self else { return }
            // 用户可能刚在系统设置里改了麦克风权限，回前台时重新同步
            self.updateAudioInputLocked()
            if !self.session.isRunning {
                RecorderDiagnostics.shared.log("会话已停止，回前台后重启")
                self.session.startRunning()
            }
        }

        // 中断后自动续录：这是同类 App 普遍缺失、而长时间录制最需要的能力
        if !isRecording, sessionActive, resumeOnForeground, settings.autoResume {
            resumeOnForeground = false
            segmentIndex += 1
            RecorderDiagnostics.shared.log("回前台自动续录 -> 第 \(segmentIndex) 段")
            startNextSegment()
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
            // 预期行为：App 离开前台，系统禁止使用摄像头。
            // 回前台会自动续录，所以这里只记日志，不打扰用户。
            RecorderDiagnostics.shared.log("原因: App 不在前台（iPhone 平台限制），回前台将自动续录")
        case .videoDeviceInUseByAnotherClient, .audioDeviceInUseByAnotherClient:
            report("摄像头被其它 App 占用")
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            RecorderDiagnostics.shared.log("原因: 多任务场景下摄像头不可用")
        case .videoDeviceNotAvailableDueToSystemPressure:
            report("设备过热，摄像头暂时不可用")
        case .sensitiveContentMitigationActivated:
            RecorderDiagnostics.shared.log("原因: 系统敏感内容遮蔽触发")
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
                "第 \(self.segmentIndex) 段结束 | 文件=\(outputFileURL.lastPathComponent) error=\(error?.localizedDescription ?? "无")"
            )

            // AVErrorRecordingSuccessfullyFinishedKey 是 NSError 的 userInfo key，
            // 不是 AVError.Code。等于 true 表示"虽然带了 error，但文件是完整的"，属正常结束
            let nsError = error as NSError?
            let finishedSuccessfully =
                (nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            let appActive = UIApplication.shared.applicationState == .active

            if let error, !finishedSuccessfully, appActive {
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

            // 续录判定
            guard self.sessionActive else { return }

            if appActive {
                // 分段到点（或其他原因），在前台就直接接下一段
                self.segmentIndex += 1
                RecorderDiagnostics.shared.log("自动接续 -> 第 \(self.segmentIndex) 段")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.sessionActive,
                          UIApplication.shared.applicationState == .active else { return }
                    self.startNextSegment()
                }
            } else {
                // 被系统中断（离开前台等）：标记待续录，回前台自动接着录
                self.segmentIndex += 1
                self.resumeOnForeground = self.settings.autoResume
                RecorderDiagnostics.shared.log(
                    "录制被中断（不在前台），回前台自动续录=\(self.resumeOnForeground)"
                )
                if !self.settings.autoResume {
                    self.sessionActive = false
                }
            }
        }
    }
}
