import AVKit
import SwiftUI

struct PlayerView: View {
    let item: RecordingItem

    @State private var player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    init(item: RecordingItem) {
        self.item = item
        _player = State(initialValue: AVPlayer(url: item.url))
    }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(item.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("完成") {
                            player.pause()
                            dismiss()
                        }
                    }
                }
        }
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }
}
