# 构建与发布手册

> **这份文档是给「下一个接手的任务/人」用的。** 从零开始照着做就能出 ipa 并装到 iPhone，
> 不需要重新摸索。所有路径、账号、坑位都是实测结论，不是理论。
>
> 最后更新：2026-10-30　|　适用：无 Mac 的 Windows 开发机

---

## 0. 三十秒看懂

```
改 Swift 代码
    ↓
python tools/rebuild.py -m "说明"        ← 一条命令搞定下面全部
    ↓
tools/gh_api_push.py  用 REST API 推送（不用 git push，会被墙）
    ↓
GitHub Actions 的 macOS 机器跑 xcodebuild（公开仓库免费）
    ↓
下载未签名 ipa → 校验 Info.plist 关键键
    ↓
Sideloadly + Apple ID 重签 → 装进 iPhone（7 天有效）
```

**核心约束**：Xcode 只跑在 macOS 上，这台 Windows 机器编译不了 iOS 项目。
所以编译这一步必须挂在 GitHub 的 macOS runner 上，产物是**未签名** ipa，
靠 Windows 上的 Sideloadly 用免费 Apple ID 重签。

---

## 1. 环境事实（照抄）

| 项 | 值 |
| --- | --- |
| 本地仓库 | `c:\Users\wxw\Desktop\wxw-kf\BackgroundRecorder` |
| 工作区 | `c:\Users\wxw\Desktop\wxw-kf`（ipa 输出到这里的 `ipa\`） |
| GitHub 仓库 | `hwx365/BackgroundRecorder`（**Public** —— 私有仓库的 macOS 额度按 10 倍计费） |
| gh CLI | `C:\Program Files\GitHub CLI\gh.exe`（可能不在 PATH，脚本里会自己找） |
| gh 登录态 | 账号 `hwx365`，scope 含 `repo` + `workflow`（后者是推 `.github/` 必须的） |
| Python | 3.14，已装 `pyyaml` |
| 工程文件 | `BackgroundRecorder.xcodeproj`（**在仓库根**） |
| 源码目录 | `BackgroundRecorder/`（子目录，注意与工程文件不同级） |
| Scheme | `BackgroundRecorder`（共享 scheme：`xcshareddata/xcschemes/`） |
| Bundle ID | `com.wxw.BackgroundRecorder`（Sideloadly 在设备上会改成 `...HHW3QV2V3Z`） |
| 显示名 | 黑色相机 |
| 部署目标 | iOS 17.0，`SWIFT_VERSION = 5.0`（**别升到 6**，见第 7 节） |
| 测试机 | iPhone 16 Pro（`iPhone17,1`），iOS 18.7.8，UDID `00008140-000E6C620A43801C` |
| Apple ID（签名用） | `1648671213@qq.com`（免费账号，证书 7 天；另有 `wanghou0000@163.com` 备用） |

---

## 2. 日常流程（唯一需要的命令）

```powershell
cd c:\Users\wxw\Desktop\wxw-kf\BackgroundRecorder
python tools/rebuild.py -m "修复某某问题"
```

它依次做 6 件事：提交 → 推送 → 匹配本次 commit 的 CI 运行 → 等编译 →
下载 ipa 到 `..\ipa\` → 校验 `Info.plist` 关键键。全部通过才返回 0。

其他用法：

| 命令 | 用途 |
| --- | --- |
| `python tools/rebuild.py` | 不改代码，只重跑一次流水线（工作区干净时） |
| `python tools/rebuild.py -m "..." --no-download` | 只等编译结果，不下 ipa |
| `python tools/rebuild.py --timeout 30` | 排队久时放宽等待时间（默认 20 分钟） |

成功后的输出形如：

```
6/6  完成
  ipa : c:\Users\wxw\Desktop\wxw-kf\ipa\BackgroundRecorder-unsigned.ipa
  大小: 0.49 MB
  校验: 全部通过
```

---

## 3. 手工分步（脚本坏掉时照着敲）

```powershell
$gh = 'C:\Program Files\GitHub CLI\gh.exe'
cd c:\Users\wxw\Desktop\wxw-kf\BackgroundRecorder

# 1. 提交
git add -A
git commit -m "说明"

# 2. 推送 —— 不用 git push！用 API 推送脚本
python tools/gh_api_push.py

# 3. 等编译（记下 run id）
& $gh run list --repo hwx365/BackgroundRecorder --limit 3
& $gh run view <run-id> --repo hwx365/BackgroundRecorder

# 4. 失败时看日志
& $gh run view <run-id> --repo hwx365/BackgroundRecorder --log-failed

# 5. 下载产物
& $gh run download <run-id> --repo hwx365/BackgroundRecorder `
    -n BackgroundRecorder-unsigned-ipa -D ..\ipa
```

### 为什么不用 `git push`

国内直连时 `git fetch` 通常正常，但 `git push` 走的是 HTTP POST `/git-receive-pack`，
容易被重置或长时间挂起；而 `api.github.com` 往往还能通。
`tools/gh_api_push.py` 用 Git Data API 手工拼一次提交（blob → tree → commit → ref），
并且**显式传入本地的 author/committer 与日期**，使远端 sha 与本地完全一致 ——
所以本地不会和远端分叉，网络恢复后仍可正常用 `git push`。

> 脚本只借用 gh CLI 已登录的凭据，自己**不接触任何 token**，也不写进任何文件。

---

## 4. CI 配置里的 5 个关键点（改之前先读）

配置文件：`.github/workflows/ios-build.yml`

| # | 关键点 | 为什么 |
| --- | --- | --- |
| 1 | **不要给 Build 步骤设 `working-directory`** | `.xcodeproj` 在仓库根，源码在 `BackgroundRecorder/` 子目录。设成子目录会报 `does not exist` |
| 2 | 三件套关签名：`CODE_SIGNING_ALLOWED=NO` `CODE_SIGNING_REQUIRED=NO` `CODE_SIGN_IDENTITY=""` | 不需要任何证书 / Secret / 开发者账号 |
| 3 | `-configuration Release` + `-derivedDataPath "$RUNNER_TEMP/dd"` | 产物路径可预期，便于打包 |
| 4 | 打包必须是 `Payload/` 目录 + zip | `.ipa` 的本质就是这个结构，目录名一个字都不能错 |
| 5 | `runs-on: macos-latest` | 需要 Xcode 15+（iOS 17 部署目标）。标签失效时换 `macos-15` / `macos-14` |

CI 还包含一步 `Verify Info.plist keys`：校验三个权限说明键存在，并**断言不存在
`UIBackgroundModes`**（iPhone 上第三方 App 无法后台用摄像头，声明了反而是审核风险）。

---

## 5. 新增 Swift 文件：必须手工登记 pbxproj

工程文件是手写的，**不会自动发现新文件**。不登记就是「文件在磁盘上但不参与编译」，
编译时会报 `cannot find 'XXX' in scope`。

需要在 `BackgroundRecorder.xcodeproj/project.pbxproj` 里加 **4 处**：

1. `PBXBuildFile` 段 —— 加一行构建条目（新 ID）
2. `PBXFileReference` 段 —— 加一行文件引用（另一个新 ID）
3. `PBXGroup` 的 `children` —— 加进源码分组
4. `PBXSourcesBuildPhase` 的 `files` —— 加进编译阶段

ID 格式约定：`A1B2C3D4E5F60000000000XX`，**必须是 24 位十六进制**，
构建条目用 `001x` 段，文件引用用 `002x` 段，不要复用已存在的。

改完用这段校验（对象 ID 长度、引用是否悬空、文件是否真实存在、是否全部参与编译）：

```python
import os, re, io
ROOT = r'c:/Users/wxw/Desktop/wxw-kf/BackgroundRecorder'
text = io.open(os.path.join(ROOT, 'BackgroundRecorder.xcodeproj/project.pbxproj'), encoding='utf-8').read()
ids = sorted(set(re.findall(r'\bA1B2C3D4E5F60000000000[0-9A-F]{2}\b', text)))
print('ID 总数:', len(ids), '| 长度异常:', [i for i in ids if len(i) != 24])
swift = sorted(f for f in os.listdir(os.path.join(ROOT, 'BackgroundRecorder')) if f.endswith('.swift'))
phase = text.split('PBXSourcesBuildPhase section')[1]
print('未参与编译:', [f for f in swift if f'/* {f} in Sources */' not in phase])
```

---

## 6. ipa 校验（发布前必做）

`tools/rebuild.py` 已内置，也可以用下面片段单独查：

```python
import zipfile, plistlib
z = zipfile.ZipFile(r'c:/Users/wxw/Desktop/wxw-kf/ipa/BackgroundRecorder-unsigned.ipa')
n = [x for x in z.namelist() if x.endswith('.app/Info.plist')][0]
info = plistlib.loads(z.read(n))
print('显示名:', info.get('CFBundleDisplayName'))
print('最低系统:', info.get('MinimumOSVersion'))
print('后台模式（应为 None）:', info.get('UIBackgroundModes'))
print('图标:', [x.split('/')[-1] for x in z.namelist() if 'AppIcon' in x])
```

---

## 7. 编译错误速查（全部真实踩过）

| 报错 | 真正原因 | 修法 |
| --- | --- | --- |
| `'BackgroundRecorder.xcodeproj' does not exist` | 给了 `working-directory: BackgroundRecorder`，但工程在仓库根 | 去掉 `working-directory` |
| `call to main actor-isolated ... in a synchronous nonisolated context` | `@MainActor` 类型的方法被非主线程调用 | 那个方法标 `nonisolated`（只做文件/IO、不碰 UI 才算安全） |
| `type 'AVError.Code' has no member 'recordingSuccessfullyFinished'` | 它不是 error code，是 NSError 的 userInfo key | 用 `AVErrorRecordingSuccessfullyFinishedKey` 查 `error.userInfo` |
| `type 'AVCaptureDevice' has no member 'isMultitaskingCameraAccessSupported'` | API 归属写错 | 两个属性都挂在 **`AVCaptureSession`** 实例上 |
| PowerShell 校验脚本报「文件编码错误」 | PowerShell 5.1 默认按 GBK 解码 UTF-8 文件 | 用 UTF-8 显式读取，文件本身没问题（无 BOM 是正常的） |
| 包内 PNG 打不开：`broken data stream` | Xcode 打包时把 PNG 转成 Apple 私有 **CgBI** 格式 | 正常现象，iOS 能读，别当成损坏 |
| Swift 6 模式下爆一堆并发错误 | `SWIFT_VERSION` 被改成 6 会开严格并发检查 | 保持 **5.0**；真要升 6 得整体改造 `@MainActor` 边界 |

---

## 8. Sideloadly 侧载（Windows → iPhone）

**安装前置**：Sideloadly（<https://sideloadly.io/>）+ Apple 设备驱动
（微软商店「Apple Devices」或 Apple 官网版 iTunes，**不要商店版**）。

**步骤**：数据线连 iPhone → 手机点「信任」→ 拖 ipa 进 Sideloadly →
填 Apple ID → Start → 输密码和双重认证码。

**装完必做两步**（否则点开闪退）：

1. 设置 → 隐私与安全性 → **开发者模式** → 打开 → 重启手机
2. 设置 → 通用 → VPN与设备管理 → 开发者 App → 点 Apple ID → **信任**

### 已知故障表（按出现频率排序）

| 症状 | 原因 | 修法 |
| --- | --- | --- |
| 装完点开就闪退 / 图标变灰 | 免费签名 **7 天到期** | 重跑 Sideloadly 一次 |
| 点开闪退，但刚装好 | **开发者模式**被系统重置（常见于 iOS 更新后） | 重新打开开发者模式 + 重启 |
| 安装过程 **2 秒就中断**，无任何错误 | **杀软拦截**（卡巴斯基 / 联想电脑管家火绒引擎）。特征：`installations.db` 里 `last_error` 为空、`failures_count=0`、Windows 事件日志无崩溃记录 | 把 `%LOCALAPPDATA%\Sideloadly` 加进两个杀软的信任区 |
| `iDevice: <no devices detected>` | 充电线没有数据线芯 / USB hub / 手机锁屏 | 换原装线、直插主机后置口、先解锁 |
| `GSA returned a non-plist response (HTTP 503)` | 本机缺 **Apple Root CA**，TLS 建不起来 | 从 `apple.com/certificateauthority/` 下载 `AppleIncRootCertificate.cer`，装进「当前用户→受信任的根证书颁发机构」 |
| `Login failed (-22406)` | 密码错 **或** ADI 设备身份文件陈旧 | 先用 iTunes 登录一次该 Apple ID（顺带授权本机）；仍不行则重置 `C:\ProgramData\Apple Computer\iTunes\adi`（改名备份，别删） |
| `Could not create CoreFP key: Access is denied` | 首次运行需要管理员权限写系统密钥库 | 点 OK → UAC 选「是」，一次性 |
| 提示「无法验证 App」 | 证书被吊销，或手机时间严重偏差 | 重新侧载；检查系统时间与网络时间同步 |

**免费签名的限制**：7 天有效期、同设备最多 3 个自签 App、7 天内最多 10 个 App ID。
（Sideloadly 会把 Bundle ID 加上 Team ID 后缀，避免与正式包冲突。）

> App ID 剩余额度可以看 `%LOCALAPPDATA%\Sideloadly\account-appids.json`。
> 签名证书缓存是 `%APPDATA%\Sideloadly\cert-*.pem`，**千万别删**——删了要重新申请，
> 会消耗每周证书额度。

---

## 9. 代码结构

```
BackgroundRecorder/
├── BackgroundRecorder.xcodeproj/          手写工程 + 共享 scheme
├── .github/workflows/ios-build.yml        CI：macOS 上编译出未签名 ipa
├── tools/
│   ├── rebuild.py                         ★ 一条命令跑完整条流水线
│   ├── gh_api_push.py                     REST API 推送（绕开 git push）
│   └── make_icon.py                       图标生成（1024 纯 RGB，无透明通道）
├── docs/BUILD-AND-SIDELOAD.md             本文件
├── project.yml                            XcodeGen 备用工程描述
└── BackgroundRecorder/
    ├── BackgroundRecorderApp.swift        @main 入口
    ├── ContentView.swift                  首页：预览 / 状态 / 隐身覆盖层 / 录制按钮
    ├── StealthGestureLayer.swift          隐身手势层（双指长按 3 秒退出）
    ├── CameraRecorder.swift               ★ 核心：采集、分段、续录、降级、手电筒
    ├── RecordingSettings.swift            设置模型（画质/分段/容量），持久化
    ├── SettingsView.swift                 设置界面
    ├── RecordingIntents.swift             快捷指令动作（静默执行，不弹 dialog）
    ├── CameraPreviewView.swift            AVCaptureVideoPreviewLayer 包装
    ├── RecordingListView.swift            列表：播放 / 存相册 / 分享 / 删除
    ├── PlayerView.swift                   AVKit 播放器
    ├── RecordingLibrary.swift             文件扫描、删除、PHPhotoLibrary 导出
    ├── RecorderDiagnostics.swift          诊断日志 → Documents/diagnostics.log
    ├── Info.plist                         权限说明（刻意不声明 UIBackgroundModes）
    └── Assets.xcassets/
```

---

## 10. 架构边界（别承诺做不到的事）

**iPhone 上第三方 App 无法在切到后台后继续录像。** 这不是实现问题，是平台限制：
`AVCaptureSession.isMultitaskingCameraAccessSupported` 返回 true 需要「iPad + Stage Manager」
「`UIBackgroundModes` 含 `voip`」「专门 entitlement」三条同时满足，iPhone 一条都不满足。
离开前台约 0.1 秒内就会收到 `videoDeviceNotAvailableInBackground` 中断。

所以本 App 走的是**前台录制 + 屏幕伪装**：

- 录制期间屏幕全黑、亮度归零、隐藏状态栏与 Home 指示条
- 黑屏期间**单指轻点/滑动完全无响应**（不装 tap 识别器）
- 唯一出口：**双指长按 3 秒**，或侧边「操作按钮」（快捷指令，静默执行不弹窗）
- `defersSystemGestures(on: .all)`：上滑第一次由 App 接管，但**挡不住第二次** ——
  官方语义是「优先」不是「禁止」。要彻底锁死只能让用户开系统「引导式访问」
- `UIAccessibility.requestGuidedAccessSession` 对个人设备无效（官方要求 MDM 监管）
- App **无法自己退出进程**（无公开 API）

---

## 11. 交接时的当前状态

- 最后一次成功构建：见 `ipa\` 目录下文件时间
- 手机上的免费签名到期日：**2026-11-04**（`account-appids.json` 里的 `NearestTtl`）
- 已知风险：本机装了三套安全软件（卡巴斯基 21.27 + 联想电脑管家/火绒引擎 + Defender），
  会随机杀掉 Sideloadly 进程。**遇到无错误的安装中断，先查杀软白名单**
- Sideloadly 版本 0.71.2（会自更新；0.70.1 → 0.71.2 是 2026-10-28 自动升的）
- 账号 `1648671213@qq.com` 目前在用**远程 anisette**（认证数据经 sideloadly.io 服务器）；
  能切回本地 anisette 更安全

---

## 12. 复制给新任务的开场提示

```
项目在 c:\Users\wxw\Desktop\wxw-kf\BackgroundRecorder
先读 docs/BUILD-AND-SIDELOAD.md（构建与发布手册），
再读 README.md（架构边界）。

日常出包只要一条命令：
  cd c:\Users\wxw\Desktop\wxw-kf\BackgroundRecorder
  python tools/rebuild.py -m "提交说明"

注意：
1. 这台机器是 Windows，编译不了 iOS，一切编译都在 GitHub Actions 上跑
2. 推送用 tools/gh_api_push.py，不要用 git push
3. 新增 .swift 文件必须手工登记 project.pbxproj 的 4 个位置（见手册第 5 节）
4. SWIFT_VERSION 保持 5.0
5. 本机杀软会杀 Sideloadly，安装中断先查杀软
```
