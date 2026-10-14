import AVFoundation
import Combine
import Foundation
import Photos

/// 一条录像记录
struct RecordingItem: Identifiable, Hashable {
    var id: URL { url }

    let url: URL
    let createdAt: Date
    let duration: TimeInterval
    let fileSize: Int64

    var displayName: String { url.deletingPathExtension().lastPathComponent }

    /// 分段序号（文件名里的 `_sNN`）。没有分段时返回 nil
    var segmentNumber: Int? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let range = name.range(of: "_s", options: .backwards) else { return nil }
        return Int(name[range.upperBound...])
    }
}

/// 录像文件仓库：扫描、删除、容量管理、导出到相册
@MainActor
final class RecordingLibrary: ObservableObject {

    @Published private(set) var items: [RecordingItem] = []

    /// 录像存放目录：<沙盒>/Documents/Recordings
    /// 因为 Info.plist 打开了 UIFileSharingEnabled，用户也能在「文件」App 里直接取走
    ///
    /// 标记 nonisolated：录制入口不在主线程上也要读这个路径。URL 是 Sendable 值类型，跨线程读取安全。
    nonisolated let directory: URL

    private let fileManager = FileManager.default

    init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Recordings", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - 文件创建

    /// 生成新录像文件的 URL。
    ///
    /// 标记 nonisolated：`CameraRecorder.startRecording()` 是同步的非主线程隔离上下文，
    /// 需要在其中取文件名。本方法只做文件系统操作、不触碰任何 UI 状态，所以跨线程安全。
    nonisolated func makeNewRecordingURL(segmentIndex: Int = 0) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())

        // 手动补零，避免 String(format:) 里 %d 与 Swift Int 的位宽陷阱
        let name: String
        if segmentIndex > 0 {
            let padded = segmentIndex < 10 ? "0\(segmentIndex)" : "\(segmentIndex)"
            name = "REC_\(stamp)_s\(padded).mov"
        } else {
            name = "REC_\(stamp).mov"
        }
        return directory.appendingPathComponent(name)
    }

    // MARK: - 扫描

    func refresh() async {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        var result: [RecordingItem] = []

        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "mov" || ext == "mp4" || ext == "m4v" else { continue }

            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            guard size > 0 else { continue }

            var seconds: Double = 0
            let asset = AVURLAsset(url: url)
            if let cmDuration = try? await asset.load(.duration) {
                let value = CMTimeGetSeconds(cmDuration)
                if value.isFinite, value > 0 { seconds = value }
            }

            result.append(RecordingItem(
                url: url,
                createdAt: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                duration: seconds,
                fileSize: size
            ))
        }

        items = result.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - 删除

    func delete(_ item: RecordingItem) {
        try? fileManager.removeItem(at: item.url)
        items.removeAll { $0.id == item.id }
    }

    func deleteAll() {
        for item in items {
            try? fileManager.removeItem(at: item.url)
        }
        items.removeAll()
    }

    // MARK: - 存储管理

    var totalSizeBytes: Int64 {
        items.reduce(0) { $0 + $1.fileSize }
    }

    /// 设备可用空间（系统为「重要用途」保留统计口径，比 volumeAvailableCapacity 更贴近实际可写容量）。
    /// 标记 nonisolated：录制线程需要它做写入前的空间检查。
    nonisolated func freeDiskSpaceBytes() -> Int64 {
        let url = directory
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// 按容量上限淘汰最旧的文件（行车记录仪式循环覆盖）。
    ///
    /// 标记 nonisolated，且完全自扫磁盘、不触碰 `items`：
    /// 这样录制线程可以直接调用，不必回到主线程。
    /// 返回删除的文件数；调用方负责随后刷新列表。
    nonisolated func enforceStorageLimitOnDisk(limitBytes: Int64) -> Int {
        guard limitBytes > 0 else { return 0 }

        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var files: [(url: URL, date: Date, size: Int64)] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "mov" || ext == "mp4" || ext == "m4v" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            guard size > 0 else { continue }
            let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            files.append((url, date, size))
        }

        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > limitBytes else { return 0 }

        var removed = 0
        for file in files.sorted(by: { $0.date < $1.date }) {
            if total <= limitBytes { break }
            // 跳过最近 15 秒内写入的，避免删掉正在录制的分段
            if Date().timeIntervalSince(file.date) < 15 { continue }
            do {
                try fileManager.removeItem(at: file.url)
                total -= file.size
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }

    // MARK: - 导出到相册

    func saveToPhotoLibrary(_ item: RecordingItem) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: item.url)
        }
    }

    // MARK: - 格式化

    /// 标记 nonisolated：录制线程（非主线程）也要格式化剩余空间用于日志
    nonisolated static func formattedDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        // 手动补零，避免 String(format:) 里 %d 与 Swift Int 的位宽陷阱
        return h > 0 ? "\(h):\(pad(m)):\(pad(s))" : "\(pad(m)):\(pad(s))"
    }

    nonisolated static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    nonisolated private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
