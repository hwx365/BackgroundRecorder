import SwiftUI

@MainActor
struct RecordingListView: View {
    @ObservedObject var library: RecordingLibrary

    @Environment(\.dismiss) private var dismiss
    @State private var playingItem: RecordingItem?
    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if library.items.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(library.items) { item in
                            Button {
                                playingItem = item
                            } label: {
                                row(item)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    library.delete(item)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }

                                Button {
                                    saveToAlbum(item)
                                } label: {
                                    Label("存相册", systemImage: "square.and.arrow.down")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    saveToAlbum(item)
                                } label: {
                                    Label("保存到相册", systemImage: "square.and.arrow.down")
                                }
                                ShareLink(item: item.url) {
                                    Label("分享 / 导出", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    library.delete(item)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("录像 · \(library.items.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            library.deleteAll()
                        } label: {
                            Label("删除全部", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(library.items.isEmpty)
                }
            }
            .task { await library.refresh() }
            .refreshable { await library.refresh() }
            .sheet(item: $playingItem) { PlayerView(item: $0) }
            .alert("提示", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("好", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    // MARK: - 子视图

    private func row(_ item: RecordingItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(RecordingLibrary.formattedDuration(item.duration))
                    Text("·")
                    Text(RecordingLibrary.formattedSize(item.fileSize))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("还没有录像")
                .font(.headline)
            Text("回到首页点击红色按钮开始录制，App 退到后台也会继续录。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 46)
        }
    }

    // MARK: - 逻辑

    private func saveToAlbum(_ item: RecordingItem) {
        Task {
            do {
                try await library.saveToPhotoLibrary(item)
                alertMessage = "已保存到系统相册"
            } catch {
                alertMessage = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}
