# BackgroundRecorder · iOS 后台录像 App

一个用 SwiftUI + AVFoundation 写的 iPhone 录像 App：**录制中把 App 切到后台 / 锁屏，录像会继续**。

---

## 一、先把话说清楚：iOS 的「后台录像」是什么情况

iOS **没有**官方的后台摄像头 API。系统规则是：

| 场景 | 系统行为 |
| --- | --- |
| App 退到后台且未声明任何后台模式 | 约 5 秒后进程被挂起，`AVCaptureSession` 停止 |
| 已声明 `audio` 后台模式 + 活跃 `AVAudioSession` | 进程继续运行，采集会话继续出帧 → **录像能继续** |
| iPad 分屏 / Stage Manager | iOS 16+ 有官方 `isMultitaskingCameraAccessEnabled`，属于正规 API |
| iPhone 全屏 App 切后台 | 没有正规 API，只能走上面的 `audio` 后台模式这条路 |

所以本项目采用的是业界通行的做法：**用「音频」的名义换取后台运行时间**。具体四件事：

1. `Info.plist` 里 `UIBackgroundModes = [audio]`
2. `AVAudioSession` 用 `.playAndRecord` + `.videoRecording` 且保持 active
3. 采集会话里**必须挂着麦克风输入**，否则系统会判定你不需要后台运行并停掉整个会话
4. **录制期间无限循环播放一段静音音频**（借鉴 App Store 成熟后台录像 App 的核心手段）。
   系统判定「App 该不该留在后台」看的是它是否真的在处理音频；
   「有一个正在播放的播放器」比「激活的会话」信号强得多。
   静音文件按需生成（8kHz/16bit 单声道 1 秒 WAV，16KB），音量 0，CPU 占用可忽略。
   音频被打断（来电、Siri）结束后自动续播。
5. **画中画（PiP）—— 真正让摄像头在后台持续出帧的关键**。
   静音音频只保住进程不被挂起，**挡不住摄像头被中断**（App 不可见时系统照样掐摄像头）。
   成熟方案是：录制中实时画面经 `AVCaptureVideoDataOutput` 喂给 `AVSampleBufferDisplayLayer`，
   该层既是 App 内预览、也是 PiP 内容源。用户切走 App 的瞬间自动弹小窗，
   小窗可见 = App 处于「使用中」状态，系统允许摄像头继续运行 → 录制不中断。
   这正是 App Store 后台录像 App 和视频通话类 App 用的机制。

### ⚠️ 上架风险（重要）

- App Store 审核指南 **2.5.4** 明确要求：声明了 `audio` 后台模式，就必须真的在后台播放/录制**音频**，且不能被用户察觉为「滥用」。
- 纯录像用途在这种情况下**有较大概率被拒**（常见回复："Your app declares support for audio in the UIBackgroundModes key... but does not include any features that require persistent audio"）。
- 常见规避方式（按风险从低到高）：
  1. 产品定义成**录音为主的记录类 App**（如取证、行车记录），录音是核心功能 —— 这样后台音频是正当的。
  2. 走**企业内部分发 / TestFlight / Ad Hoc / 自签名**，不上公开 App Store。
  3. 后台仅作为「锁屏后短暂续录」，不宣称可以无限后台录制。
- 另外 `App Store 审核 5.1.1`：录像类 App 必须明确告知用户正在录制，并给出显著提示（本 App 已在前台显示红色指示与计时）。

> 结论：**技术可行，上架看用途**。如果只是自用 / 内部分发，直接跑就行。

---

## 二、功能列表

- [x] 前后台均可录像，切后台 / 锁屏继续录
- [x] 录制期间静音音频循环播放（成熟 App 同款保活核心），来电打断后自动续播
- [x] 录制时屏幕自动调暗至 5% 亮度（省电 + 防窥），停止后恢复原亮度
- [x] 实时取景预览（`AVCaptureVideoPreviewLayer`）
- [x] 红点 + 计时器，顶部实时显示「前台 / 后台录制中」
- [x] 前后置摄像头切换（录制中禁用）
- [x] **分片写入**（`movieFragmentInterval = 2s`）：进程被系统杀掉，已写入部分仍可播放
- [x] 后台任务兜底（`beginBackgroundTask`）
- [x] 采集被打断 / 音频被打断 / 运行时错误的事件处理与提示
- [x] 录制中屏幕常亮（`isIdleTimerDisabled`）
- [x] 录像列表：播放、保存到系统相册、分享导出、滑动删除、清空
- [x] 打开 `UIFileSharingEnabled`，可从「文件」App 直接取走录像
- [x] 录像统一存到 `Documents/Recordings/`，文件名 `REC_yyyyMMdd_HHmmss.mov`

---

## 三、跑起来

### 环境要求

- macOS + **Xcode 15 或更高**
- 一台**真机 iPhone**（模拟器没有摄像头，无法验证录像）
- iOS **17.0+**

### 方式 A：直接打开工程（推荐）

```bash
open BackgroundRecorder.xcodeproj
```

然后在 Xcode 里：

1. 选中左侧 `BackgroundRecorder` target → **Signing & Capabilities**
2. 勾选 `Automatically manage signing`，把 **Team** 选成你自己的 Apple ID / 开发者账号
3. 如果 `PRODUCT_BUNDLE_IDENTIFIER`（`com.wxw.BackgroundRecorder`）被占用，改成你自己的，比如 `com.yourname.BackgroundRecorder`
4. 连上 iPhone，`⌘R` 运行

首次运行需要在 iPhone 上：**设置 → 通用 → VPN与设备管理 → 信任你的开发者证书**。

### 方式 B：用 XcodeGen 生成工程

如果不想用手写的 `.xcodeproj`，仓库里带了 `project.yml`：

```bash
brew install xcodegen
cd BackgroundRecorder
xcodegen generate
open BackgroundRecorder.xcodeproj
```

### 方式 C：手动新建工程

1. Xcode → New Project → iOS → App
2. Product Name `BackgroundRecorder`，Interface **SwiftUI**，Language **Swift**
3. 把 `BackgroundRecorder/` 下所有 `.swift`、`Assets.xcassets`、`Info.plist` 拖进去（选择 Copy items if needed）
4. 删掉 Xcode 自动生成的 `Info.plist` 相关配置：target → Build Settings → 把 `GENERATE_INFOPLIST_FILE` 设为 `NO`，`INFOPLIST_FILE` 设为 `BackgroundRecorder/Info.plist`
5. 记得在 Info.plist 里补上 `UIBackgroundModes = audio`，否则后台录制不会生效

---

## 四、怎么验证后台录像真的生效

1. 打开 App，授予相机 + 麦克风权限
2. 点红色按钮开始录制，看到计时开始走
3. **按 Home 键 / 上滑回桌面** —— App 进入后台
4. 等 1~2 分钟（建议同时锁屏测一次）
5. 回到 App，点左下角相册按钮，列表里应有完整视频；对比时长与实际经过时间是否一致
6. 也可以在 macOS 上 `xcrun devicectl device info files --device <UDID>` 或者用「文件」App 直接打开 `BackgroundRecorder/Recordings` 看文件

**日志观察**：Xcode → Window → Devices and Simulators → 选中设备 → Open Console，过滤进程名 `BackgroundRecorder`，可以看到是否被挂起。

### 如果后台录制 5 秒后停了，逐条排查

| 症状 | 原因 |
| --- | --- |
| 一进后台就停 | `Info.plist` 的 `UIBackgroundModes` 没生效，或改的是错误的 Info.plist |
| 停之前有一声"咔" | `AVAudioSession` 被别的 App 打断（打电话、播音乐），看 `handleAudioInterruption` 恢复 |
| 只有前几秒有画面 | 音频输入没加进 session（本项目已加，别删） |
| 文件最后一段损坏 | `movieFragmentInterval` 没设，或设得太大 |
| 抓到 `videoDeviceNotAvailableInBackground` | 系统策略收紧（某些 iOS 版本 / 机型的低电量模式），此时只能回到前台继续 |

---

## 五、代码结构

```
BackgroundRecorder/
├── BackgroundRecorder.xcodeproj/            # Xcode 工程
├── project.yml                              # XcodeGen 备用工程描述
├── README.md
└── BackgroundRecorder/
    ├── BackgroundRecorderApp.swift          # @main 入口
    ├── ContentView.swift                    # 首页：预览 + 状态 + 录制按钮
    ├── CameraRecorder.swift                 # ★ 核心：采集会话、后台保活、分片写入
    ├── CameraPreviewView.swift              # UIViewRepresentable 包一层预览层
    ├── RecordingListView.swift              # 录像列表
    ├── PlayerView.swift                     # AVKit 播放器
    ├── RecordingLibrary.swift               # 文件扫描 / 删除 / 存相册 / 格式化
    ├── Info.plist                           # 权限 + UIBackgroundModes
    └── Assets.xcassets/
```

`CameraRecorder.swift` 是全部关键逻辑所在，后台相关的四步都在里面：

```swift
// 1. 分片写入：进程被杀也不丢已落盘的内容
movieOutput.movieFragmentInterval = CMTime(value: 2, timescale: 1)

// 2. 音频会话保持 active，这是系统允许后台运行的前提
try audio.setCategory(.playAndRecord, mode: .videoRecording,
                      options: [.defaultToSpeaker, .allowBluetoothHFP])

// 3. 进后台时再要一段执行时间做兜底
backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "...") { ... }

// 4. iPad / iOS 16+ 走官方多任务摄像头 API
session.isMultitaskingCameraAccessEnabled = true
```

---

## 六、下一步可以加什么

- **后台继续录制 + 低功耗**：把 `sessionPreset` 从 `.high` 降到 `.hd1280x720`，并限制 FPS
- **循环录制（行车记录仪模式）**：`movieOutput.maxRecordedDuration` 设成 5 分钟，在 `didFinishRecordingTo` 里自动开下一段，再按总容量淘汰旧文件
- **精确控制码率 / HEVC**：改用 `AVCaptureVideoDataOutput` + `AVAssetWriter`，能自己设 `AVVideoCodecType.hevc` 和 `AVVideoAverageBitRateKey`
- **后台录制时把预览关掉**：后台不再需要预览，可断开 video connection 的预览相关消耗
- **崩溃自恢复**：`applicationWillTerminate` 里主动 `stopRecording()`，保证文件 moov 完整
- **Widget / Live Activity**：用 `ActivityKit` 显示「正在后台录制」的实时状态

---

## 七、免责

后台录制属于系统灰色地带，请遵守当地法律法规（尤其是涉及他人隐私、公共场所录音录像的规定），并且**不要**把本 App 用于任何隐蔽偷拍用途。上架 App Store 前请按第一节的风险说明评估。
