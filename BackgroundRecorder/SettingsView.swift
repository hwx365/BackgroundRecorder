import SwiftUI

/// 设置界面：画质、循环分段、容量上限、录制行为、存储与诊断信息
struct SettingsView: View {

    @ObservedObject var settings: RecordingSettings
    @ObservedObject var library: RecordingLibrary

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("画质", selection: $settings.quality) {
                        ForEach(RecordingQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                } header: {
                    Text("画质")
                } footer: {
                    Text(settings.quality.detail)
                }

                Section {
                    Picker("分段长度", selection: $settings.segment) {
                        ForEach(SegmentLength.allCases) { length in
                            Text(length.title).tag(length)
                        }
                    }
                    Picker("容量上限", selection: $settings.storageLimit) {
                        ForEach(StorageLimit.allCases) { limit in
                            Text(limit.title).tag(limit)
                        }
                    }
                } header: {
                    Text("循环分段与容量")
                } footer: {
                    Text("长时录制会自动切成多段，任何一段损坏都不影响其他段，单文件也不会大到难以管理。"
                         + "超出容量上限后会从最旧的开始自动删除（行车记录仪式循环覆盖）。")
                }

                Section {
                    Toggle("录制声音", isOn: $settings.recordAudio)
                    Toggle("隐身模式", isOn: $settings.stealthMode)
                    Toggle("中断后自动续录", isOn: $settings.autoResume)
                    Toggle("低电量 / 过热自动降画质", isOn: $settings.autoDowngrade)
                } header: {
                    Text("录制行为")
                } footer: {
                    Text("录制声音：关闭后录出的是没有音轨的纯视频（需要麦克风权限）。\n"
                         + "隐身模式：录制时屏幕全黑、亮度归零、隐藏状态栏。黑屏期间单指轻点没有反应，"
                         + "要退出请两指长按 3 秒，或按侧边操作按钮。\n"
                         + "中断后自动续录：被来电或其它 App 打断后，回到本 App 会自动接着录新的一段。")
                }

                Section {
                    Text("已内置 3 个快捷指令动作：「开始录像」「停止录像」「开始或停止录像」。\n"
                         + "绑定到侧边「操作按钮」：设置 → 操作按钮 → 滑到「快捷指令」→ 选择「开始或停止录像」。\n"
                         + "之后按一下操作按钮就开始录像（并进入黑屏隐身），再按一下停止。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("快捷指令 / 操作按钮")
                }

                Section("存储") {
                    LabeledContent("已占用", value: RecordingLibrary.formattedSize(library.totalSizeBytes))
                    LabeledContent("设备可用空间", value: RecordingLibrary.formattedSize(library.freeDiskSpaceBytes()))
                    LabeledContent("录像数量", value: "\(library.items.count) 个")
                }

                Section {
                    Text("iPhone 上第三方 App 无法在切到其他 App 后继续录像，这是 Apple 的平台限制"
                         + "（需要 iPad 机型 + 专门的 entitlement）。"
                         + "本 App 采用「前台录制 + 黑屏伪装」：录制期间屏幕全黑、看起来像待机，"
                         + "实际一直在录 —— 但不能切到其他 App。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("关于后台录制")
                }

                Section("诊断") {
                    Text("诊断日志：Documents/diagnostics.log，可用「文件」App 打开查看。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await library.refresh() }
        }
    }
}
