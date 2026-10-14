import Foundation

/// 轻量诊断日志。
///
/// 排查「后台录制到底有没有被系统中断」时，只看 UI 是不够的——
/// 前后台切换、采集中断、会话启停、录制起止这些事件都需要时间线。
/// 这里把它们写到 <沙盒>/Documents/diagnostics.log，
/// 因为 Info.plist 里开了 UIFileSharingEnabled，
/// 可以直接在 iPhone 的「文件」App → 我的 iPhone → 后台录像 里查看。
final class RecorderDiagnostics {

    static let shared = RecorderDiagnostics()

    /// 日志大小上限，超出就重新开始，避免无限增长
    private let maxBytes = 256 * 1024

    private let queue = DispatchQueue(label: "com.wxw.BackgroundRecorder.diagnostics")
    private let fileURL: URL
    private let formatter: DateFormatter

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent("diagnostics.log")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.formatter = formatter
    }

    /// 记录一条事件。线程安全，可在任意队列上调用。
    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let url = fileURL
        let limit = maxBytes

        queue.async {
            let fileManager = FileManager.default
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? Int) ?? 0

            // 超限就直接重建文件，保留最近的日志
            if size > limit {
                try? data.write(to: url, options: .atomic)
                return
            }

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                // 文件还不存在
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
