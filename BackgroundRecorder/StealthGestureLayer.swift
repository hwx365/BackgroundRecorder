import SwiftUI
import UIKit

/// 隐身模式下的全屏手势层：**只认「双指长按 3 秒」这一件事**。
///
/// ## 为什么单指轻点刻意不装识别器
///
/// 隐身的目的是「看起来像息屏」。任何单指就能触发的响应 —— 唤出控件、亮屏、退出 ——
/// 都会在口袋里被误触：轻则屏幕亮起来暴露，重则直接把录像停掉。
/// 所以这里**故意没有** `UITapGestureRecognizer`，黑屏期间轻点屏幕完全无反应。
///
/// ## 为什么要下沉到 UIKit
///
/// SwiftUI 的 `onLongPressGesture` 只能识别**单指**长按，没有「需要几根手指」这个参数。
/// 而「双指同时按住 3 秒」是口袋里几乎不可能复现的组合，正好用来当唯一的出口。
/// UIKit 的 `UILongPressGestureRecognizer.numberOfTouchesRequired` 能做这件事。
struct StealthGestureLayer: UIViewRepresentable {

    /// 长按识别成功次数：自增表示「要退出隐身」
    @Binding var exitCount: Int

    /// 需要的手指数量
    var touchesRequired: Int = 2
    /// 需要按住的时长
    var holdDuration: TimeInterval = 3

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let hold = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleHold(_:))
        )
        hold.numberOfTouchesRequired = touchesRequired
        hold.minimumPressDuration = holdDuration
        // 按住 3 秒手难免轻微移动，放宽一点，否则会被判为失败
        hold.allowableMovement = 30
        view.addGestureRecognizer(hold)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Binding 要跟着刷新，否则 SwiftUI 重建视图后回调会写到旧的 State 上
        context.coordinator.exitCount = $exitCount
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(exitCount: $exitCount)
    }

    /// 只负责把「识别成功」转成计数自增。
    ///
    /// 刻意不在这里做任何 UI 操作（震动等）：那些需要 MainActor，而这个类是非隔离的。
    /// 震动交给 SwiftUI 的 `sensoryFeedback`，由计数变化驱动，职责更清楚。
    final class Coordinator: NSObject {

        var exitCount: Binding<Int>

        init(exitCount: Binding<Int>) {
            self.exitCount = exitCount
        }

        @objc func handleHold(_ recognizer: UILongPressGestureRecognizer) {
            // 只在「刚刚识别成功」的那一次触发；按住过程中的 changed / ended 全部忽略，
            // 否则一次长按会被记成很多次。
            guard recognizer.state == .began else { return }
            exitCount.wrappedValue += 1
        }
    }
}
