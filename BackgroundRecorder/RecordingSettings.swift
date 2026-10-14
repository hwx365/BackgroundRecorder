import AVFoundation
import Combine
import Foundation

/// 录像画质档位
enum RecordingQuality: String, CaseIterable, Identifiable {
    case hd1080p
    case hd720p
    case vga

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hd1080p: return "1080p 高清"
        case .hd720p: return "720p 均衡"
        case .vga: return "480p 省空间"
        }
    }

    var detail: String {
        switch self {
        case .hd1080p: return "画质最好，约 200 MB/分钟"
        case .hd720p: return "清晰度与体积平衡，约 90 MB/分钟"
        case .vga: return "体积最小，约 30 MB/分钟"
        }
    }

    var preset: AVCaptureSession.Preset {
        switch self {
        case .hd1080p: return .high
        case .hd720p: return .hd1280x720
        case .vga: return .vga640x480
        }
    }

    /// 画质档位高低（数值越大越清晰）。用于自动降级时取较低档
    var rank: Int {
        switch self {
        case .vga: return 0
        case .hd720p: return 1
        case .hd1080p: return 2
        }
    }

    /// 取两个档位里较低的那个
    static func lower(_ a: RecordingQuality, _ b: RecordingQuality) -> RecordingQuality {
        a.rank <= b.rank ? a : b
    }
}

/// 分段时长。长时录制切成多段，任何一段损坏都不会影响其他段
enum SegmentLength: Int, CaseIterable, Identifiable {
    case unlimited = 0
    case fiveMinutes = 5
    case tenMinutes = 10
    case thirtyMinutes = 30
    case oneHour = 60

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .unlimited: return "不分割（单个大文件）"
        case .fiveMinutes: return "每 5 分钟一段"
        case .tenMinutes: return "每 10 分钟一段"
        case .thirtyMinutes: return "每 30 分钟一段"
        case .oneHour: return "每 1 小时一段"
        }
    }

    var seconds: Double { Double(rawValue) * 60 }
}

/// 录像占用容量上限，超出后自动淘汰最旧的文件（行车记录仪式循环覆盖）
enum StorageLimit: Int, CaseIterable, Identifiable {
    case unlimited = 0
    case twoGB = 2
    case fiveGB = 5
    case tenGB = 10
    case twentyGB = 20

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .unlimited: return "不限（录满为止）"
        case .twoGB: return "最多占用 2 GB"
        case .fiveGB: return "最多占用 5 GB"
        case .tenGB: return "最多占用 10 GB"
        case .twentyGB: return "最多占用 20 GB"
        }
    }

    var bytes: Int64 { Int64(rawValue) * 1024 * 1024 * 1024 }
}

/// 用户设置，持久化到 UserDefaults。
///
/// 刻意不加 `@MainActor`：录制线程（非主线程）也需要读取这些值，
/// 做成普通类可以避免全局 actor 隔离带来的跨线程访问限制。
/// 并发安全由使用方式保证——写入只发生在设置界面。
final class RecordingSettings: ObservableObject {

    @Published var quality: RecordingQuality { didSet { save() } }
    @Published var segment: SegmentLength { didSet { save() } }
    @Published var storageLimit: StorageLimit { didSet { save() } }

    /// 是否录制声音（需要麦克风权限）。关闭后录出的是无音轨的纯视频
    @Published var recordAudio: Bool { didSet { save() } }

    /// 隐身模式：录制时全屏纯黑 + 亮度归零，长按才能停止
    @Published var stealthMode: Bool { didSet { save() } }
    /// 被系统中断后，回到前台自动接着录（新起一段）
    @Published var autoResume: Bool { didSet { save() } }
    /// 低电量或机身过热时，自动降到 720p 以降低负载
    @Published var autoDowngrade: Bool { didSet { save() } }

    private let defaults: UserDefaults

    private enum Keys {
        static let recordAudio = "settings.recordAudio"
        static let quality = "settings.quality"
        static let segment = "settings.segment"
        static let storageLimit = "settings.storageLimit"
        static let stealth = "settings.stealth"
        static let autoResume = "settings.autoResume"
        static let autoDowngrade = "settings.autoDowngrade"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let quality = RecordingQuality(rawValue: defaults.string(forKey: Keys.quality) ?? "") ?? .hd1080p

        let segment: SegmentLength
        if let raw = defaults.object(forKey: Keys.segment) as? Int,
           let value = SegmentLength(rawValue: raw) {
            segment = value
        } else {
            segment = .fiveMinutes          // 默认分段，避免单文件过大
        }

        let storageLimit: StorageLimit
        if let raw = defaults.object(forKey: Keys.storageLimit) as? Int,
           let value = StorageLimit(rawValue: raw) {
            storageLimit = value
        } else {
            storageLimit = .fiveGB
        }

        self.recordAudio = defaults.object(forKey: Keys.recordAudio) as? Bool ?? true
        self.quality = quality
        self.segment = segment
        self.storageLimit = storageLimit
        self.stealthMode = defaults.object(forKey: Keys.stealth) as? Bool ?? true
        self.autoResume = defaults.object(forKey: Keys.autoResume) as? Bool ?? true
        self.autoDowngrade = defaults.object(forKey: Keys.autoDowngrade) as? Bool ?? true
    }

    private func save() {
        defaults.set(recordAudio, forKey: Keys.recordAudio)
        defaults.set(quality.rawValue, forKey: Keys.quality)
        defaults.set(segment.rawValue, forKey: Keys.segment)
        defaults.set(storageLimit.rawValue, forKey: Keys.storageLimit)
        defaults.set(stealthMode, forKey: Keys.stealth)
        defaults.set(autoResume, forKey: Keys.autoResume)
        defaults.set(autoDowngrade, forKey: Keys.autoDowngrade)
    }
}
