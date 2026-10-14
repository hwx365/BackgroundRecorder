import SwiftUI
import UIKit

/// 隐身模式下的全屏手势层。
///
/// ## 为什么不用 SwiftUI 的原生手势
///
/// `onLongPressGesture` 只能识别**单指**长按。而隐身模式屏幕全黑、亮度为 0，
/// 手机装在口袋里时单指长按极易误触 —— 而误触的代价是直接停录。
/// 「双指 + 3 秒」是口袋里几乎不可能复现的组合。
///
/// SwiftUI 没有提供「需要几根手指」这个参数，所以只能下沉到 UIKit 的
/// `UILongPressGestureRecognizer`（`numberOfTouchesRequired`）。
///
/// ## 为什么两个手势都放在这一层
///
/// 「轻点唤出控件」和「双指长按退出」如果分别用 SwiftUI 与 UIKit 实现，
/// 会牵扯到两者的命中测试优先级（UIKit 视图在最上层时会吞掉 SwiftUI 的点击）。
/// 放在同一个 UIKit 视图里，行为完全确定：手指数不同，两个识别器天然互斥。
struct StealthGestureLayer: UIViewRepresentable {

    /// 单指轻点次数：自增表示「要唤出控件」
    @Binding var tapCount: Int
    /// 双指长按成功次数：自增表示「要退出隐身」
    @Binding var exitCount: Int

    /// 退出需要的手指数
    var exitTouches: Int = 2
    /// 退出需要的按住时长
    var exitHoldDuration: TimeInterval = 3

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.numberOfTouchesRequired = 1
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        let hold = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleHold(_:))
        )
        hold.numberOfTouchesRequired = exitTouches
        hold.minimumPressDuration = exitHoldDuration
        // 按住 3 秒手难免轻微移动，放宽一点，否则会被判为失败
        hold.allowableMovement = 30
        hold.cancelsTouchesInView = false
        view.addGestureRecognizer(hold)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Binding 要跟着刷新，否则 SwiftUI 重建视图后回调会写到旧的 State 上
        context.coordinator.tapCount = $tapCount
        context.coordinator.exitCount = $exitCount
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(tapCount: $tapCount, exitCount: $exitCount)
    }

    /// 只负责把「识别成功」转成计数自增。
    ///
    /// 刻意不在这里做任何 UI 操作（震动、播报等）：那些要 MainActor，
    /// 而这个类是非隔离的。震动交给 SwiftUI 的 `sensoryFeedback`，
    /// 由计数变化驱动，职责更清楚。
    final class Coordinator: NSObject {

        var tapCount: Binding<Int>
        var exitCount: Binding<Int>

        init(tapCount: Binding<Int>, exitCount: Binding<Int>) {
            self.tapCount = tapCount
            self.exitCount = exitCount
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            tapCount.wrappedValue += 1
        }

        @objc func handleHold(_ recognizer: UILongPressGestureRecognizer) {
            // 只在「刚刚识别成功」的那一次触发；按住过程中的 changed / ended 全部忽略，
            // 否则一次长按会被记成很多次。
            guard recognizer.state == .began else { return }
            exitCount.wrappedValue += 1
        }
    }
}
