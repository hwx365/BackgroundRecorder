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
}

/// 录像文件仓库：负责扫描、删除、导出到相册
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
    nonisolated func makeNewRecordingURL() throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "REC_\(formatter.string(from: Date())).mov"
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

    // MARK: - 导出到相册

    func saveToPhotoLibrary(_ item: RecordingItem) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: item.url)
        }
    }

    // MARK: - 格式化

    static func formattedDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        // 手动补零，避免 String(format:) 里 %d 与 Swift Int 的位宽陷阱
        return h > 0 ? "\(h):\(pad(m)):\(pad(s))" : "\(pad(m)):\(pad(s))"
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
