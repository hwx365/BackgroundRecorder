# 黑色相机 · iPhone 录像 App

一个用 SwiftUI + AVFoundation 写的录像 App：支持**录音（可开关）**、循环分段、中断自动续录、
快捷指令 / 操作按钮触发；录制期间屏幕自动压到接近全黑（看起来像待机），适合长时间连续录制。

---

## 一、先说清楚能力边界（重要）

**iPhone 上，第三方 App 无法在切到其他 App 后继续录像。** 这不是代码问题，是 iOS 的平台限制。

依据是 Apple 官方文档对 `AVCaptureSession.isMultitaskingCameraAccessSupported` 的说明——它返回 true（即允许 App 处于非全屏/多任务状态时继续使用摄像头）需要以下**三条同时满足**：

| # | 条件 | iPhone 能否满足 |
| --- | --- | --- |
| 1 | 运行在支持 Stage Manager 外接显示的 **iPad** 上 | 否 —— 这一条直接排除 iPhone |
| 2 | 链接 iOS 18+，且 `UIBackgroundModes` 包含 **`voip`** | 否 —— 本项目不该声明 voip |
| 3 | 持有 **`com.apple.developer.avfoundation.multitasking-camera-access`** entitlement | 否 —— 免费签名拿不到任何 entitlement |

所以 App 一离开前台，系统会在**约 0.1 秒内**中断采集会话（`videoDeviceNotAvailableInBackground`），录制随即结束。真机实测日志见下：

```
[10:00:45.841] 进入后台 | 录制中=true 会话运行=true
[10:00:45.965] 采集中断 | reason=4 在前台=false 录制中=true     ← 0.12 秒后就被中断
[10:00:45.986] 录制结束 | 文件=REC_20261014_100043.mov
```

### 那些「看起来能后台录」的方案，为什么本项目没采用

| 方案 | 为什么放弃 |
| --- | --- |
| 静音音频循环播放 | 只能让**进程**留在后台，挡不住**摄像头**被中断。实测无效 |
| `UIBackgroundModes: audio` 声明 | 同上，且会给审核带来 2.5.4 条款风险（声明音频却不为音频服务）。<br>注意：本 App **确实会录制声音**（可选），所以声明麦克风权限是正当的；但**不声明后台音频模式** —— 因为它解决不了摄像头被中断的问题 |
| 画中画（PiP）实时画面小窗 | PiP 让 App 变成「可见」，中断原因从 `videoDeviceNotAvailableInBackground` 变成 `videoDeviceNotAvailableWithMultipleForegroundApps`，**依然中断**——因为缺少第 3 条的 entitlement。论文式依据：Apple 指南标题即《Accessing the camera while multitasking **on iPad**》 |

App Store 上标榜「后台录像」的应用，商店页大多写着**「专为 iPad 设计」**，也正是这个原因。

### 那本 App 怎么用

**前台录像 + 屏幕伪装**：录制开始后屏幕亮度降到 5%、界面保持最简，手机看起来像息屏待机，实际一直在录。

- ✅ 可长时间连续录制（屏幕常亮、`isIdleTimerDisabled`）
- ✅ 可选录音（默认开启，可在设置里关掉；关闭后为无音轨纯视频）
- ❌ 录制期间不能切到其他 App —— 一旦离开前台，录制会立即结束

> 如果你确实需要「边用其他 App 边录像」，唯一合规路径是 **iPad + 付费开发者账号**：
> 在 Developer 后台为 App ID 申请 `multitasking-camera-access` 能力，`UIBackgroundModes` 加 `voip`，
> 再用 PiP 呈现画面。需要的话可以在此工程基础上改。

---

## 二、比同类 App 多做了什么

调研了 App Store 上同品类的应用（QuietCam 黑屏相机、NoCam 暗影摄像机、Video Background Recorder 等）。
它们在 iPhone 上做的都是「前台录制 + 黑屏伪装」——没人能真正后台录像。它们的差异点集中在黑屏界面、
防误触、画质选择、闪光灯。**但它们普遍没做好长时间录制最需要的三件事**，本 App 补齐了：

| 能力 | 同类 App | 本 App |
| --- | --- | --- |
| 循环分段 | 少见 | 每 5/10/30/60 分钟自动切段，任何一段损坏不影响其他段 |
| **中断自动续录** | 几乎没有 | 被来电/其它 App 打断后，回到 App **自动接着录新一段**，录制不会因一次中断彻底结束 |
| 容量自管理 | 少见 | 超出上限自动淘汰最旧文件（行车记录仪式循环覆盖）；空间不足提前停止 |
| 过热/低电量适配 | 少见 | 自动降画质（1080p→720p→480p），降低负载 |
| 防误触 | 部分有 | 长按 1.2 秒才停止，口袋误触不会中断录制 |
| 诊断可观测 | 无 | 内置 `diagnostics.log`，记录每次中断原因与会话状态 |

---

## 三、功能列表

- [x] **录制声音可开关**（默认开启；关闭后为无音轨纯视频），麦克风被拒时自动降级为纯视频并提示
- [x] **隐身模式**：录制时全屏纯黑 + 亮度归零 + **隐藏状态栏与 Home 指示条**，轻点唤出控件，**长按 1.2 秒**停止
- [x] **循环分段**：按 5/10/30/60 分钟自动切段并续录
- [x] **中断自动续录**：被系统中断后回到 App 自动接续（可关闭）
- [x] **容量上限与循环覆盖**：超出自动删最旧，空间不足提前停止
- [x] **画质可选**（1080p / 720p / 480p），低电量或过热时自动降档
- [x] 录制期间屏幕亮度降至 5%，停止后恢复原亮度
- [x] 实时取景预览（`AVCaptureVideoPreviewLayer`）
- [x] 红点 + 计时器，顶部显示「前台 / 后台」状态
- [x] 前后置摄像头切换（录制中禁用）
- [x] 屏幕常亮（`isIdleTimerDisabled`）
- [x] **分片写入**（`movieFragmentInterval = 2s`）：进程崩溃或被杀，已写入部分仍可播放
- [x] 采集被打断 / 运行时错误的处理与提示（回前台自动恢复会话）
- [x] 录像列表：播放、保存到系统相册、分享导出、滑动删除、清空
- [x] 打开 `UIFileSharingEnabled`，可从「文件」App 直接取走录像
- [x] 诊断日志 `diagnostics.log`（前后台切换、中断原因、会话启停、录制起止）
- [x] 录像统一存到 `Documents/Recordings/`，文件名 `REC_yyyyMMdd_HHmmss.mov`
- [x] **快捷指令 / 操作按钮**：内置 3 个动作，可绑定到侧边「操作按钮」实现一键开始/停止

### 快捷指令与操作按钮

App 内置三个快捷指令动作，装好后在「快捷指令」App 里直接可见，无需手动创建：

| 动作 | 用途 |
| --- | --- |
| 开始录像 | 立即开始并进入黑屏隐身 |
| 停止录像 | 停止当前录像 |
| **开始或停止录像** | 按一下开始，再按一下停止 —— 最适合绑定操作按钮 |

**绑定到侧边「操作按钮」**（iPhone 15 Pro 及后续机型）：

```
设置 → 操作按钮 → 左右滑动选择「快捷指令」→ 选取「开始或停止录像」
```

之后按一下操作按钮：App 被唤起 → 立即开始录像 → 进入黑屏隐身（屏幕全黑）；
再按一下：停止录制。整个过程不需要看屏幕，也不用去点界面按钮。

> 摄像头只能在前台使用，因此这些动作会主动把 App 带到前台（`openAppWhenRun = true`），
> 这是系统要求，无法绕过。

---

## 四、跑起来

### 环境要求

- macOS + **Xcode 15 或更高**
- 一台**真机 iPhone**（模拟器没有摄像头）
- iOS **17.0+**

### 方式 A：直接打开工程

```bash
open BackgroundRecorder.xcodeproj
```

然后：选中 target → Signing & Capabilities → Team 选自己的 Apple ID → 按需改 `PRODUCT_BUNDLE_IDENTIFIER` → 连真机 `⌘R`。

### 方式 B：XcodeGen

```bash
brew install xcodegen && cd BackgroundRecorder && xcodegen generate
```

### 方式 C：没有 Mac（本项目实际采用的路径）

用 GitHub Actions 的 macOS 机器编译出**未签名 ipa**，再用 Windows 上的 Sideloadly + Apple ID 重签安装：

```
.github/workflows/ios-build.yml   →  xcodebuild + 打包未签名 .ipa 作为 Artifact
tools/gh_api_push.py              →  网络受限时用 REST API 代替 git push
```

`tools/gh_api_push.py` 的用途：国内直连 GitHub 时 `git fetch/push` 常被重置，
但 `api.github.com` 通常通畅。该脚本用 Git Data API 手工拼提交（blob → tree → commit → 更新 ref），
语义等价于 `git push`，并能正常触发 CI：

```bash
python tools/gh_api_push.py          # 默认推 hwx365/BackgroundRecorder 的 main
```

---

## 五、验证录制是否正常

1. 打开 App，授予**相机**权限
2. 点红色按钮开始录制，屏幕应立刻变暗，计时开始走
3. 录制过程中**不要切走**（切走会立即结束当前段，回到 App 会自动续录下一段）
4. 停止后进列表播放，检查画面连续、时长正确
5. 想验证分片写入：录制中强制结束 App，重开后该文件应仍可播放
6. 想验证自动续录：录制中切走 1 分钟再回来，列表里应出现「第 2 段」文件，日志中会有
   `回前台自动续录 -> 第 2 段`

**诊断日志**（`文件` App → 我的 iPhone → 黑色相机 → `diagnostics.log`）会记录每次
前后台切换、中断原因、会话启停，排查问题看这里最快。

---

## 六、代码结构

```
BackgroundRecorder/
├── BackgroundRecorder.xcodeproj/
├── .github/workflows/ios-build.yml     # CI：无签名 ipa 构建（含 Info.plist 断言）
├── tools/gh_api_push.py                # 网络受限时的推送方案（REST API 代替 git push）
├── project.yml                         # XcodeGen 备用描述
└── BackgroundRecorder/
    ├── BackgroundRecorderApp.swift     # @main 入口
    ├── ContentView.swift               # 首页：预览、状态、隐身模式覆盖层、录制按钮
    ├── CameraRecorder.swift            # ★ 核心：采集、分段、续录、降级、手电筒
    ├── RecordingSettings.swift         # 设置模型（画质/分段/容量/行为），持久化
    ├── SettingsView.swift              # 设置界面
    ├── CameraPreviewView.swift         # AVCaptureVideoPreviewLayer 包装
    ├── RecordingListView.swift         # 录像列表
    ├── PlayerView.swift                # AVKit 播放器
    ├── RecordingLibrary.swift          # 文件扫描 / 删除 / 容量管理 / 存相册
    ├── RecorderDiagnostics.swift       # 诊断日志
    ├── Info.plist                      # 仅相机权限，无后台模式
    └── Assets.xcassets/
```

---

## 七、后续可做

- **循环录制（行车记录仪模式）**：`movieOutput.maxRecordedDuration` 设 5 分钟，在
  `didFinishRecordingTo` 里自动续录，按总容量淘汰旧文件
- **后台只录声音**：如果「切走后继续记录」比画面更重要，音频后台录制是系统允许的
- **iPad + entitlement 版本**：满足「边用其他 App 边录像」的唯一官方合规路径
- **精确控制码率 / HEVC**：改用 `AVCaptureVideoDataOutput` + `AVAssetWriter`

---

## 八、免责

请遵守当地法律法规，尊重他人隐私，不要在公共场所或他人不知情的情况下进行隐蔽拍摄。
