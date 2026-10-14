import AVFoundation
import SwiftUI
import UIKit

/// 承载 `AVSampleBufferDisplayLayer` 的容器视图。
///
/// 该层身兼两职：
/// 1. App 内的全屏实时预览（替代 AVCaptureVideoPreviewLayer）；
/// 2. 画中画（PiP）的内容源 —— 这是换掉 previewLayer 的真正原因：
///    `AVCaptureVideoPreviewLayer` 不能作为 PiP 内容源，成熟后台录像 App
///    都用 sample buffer 显示层 + 视频数据输出来喂帧。
final class SampleBufferContainerView: UIView {

    var contentLayer: CALayer? {
        didSet {
            if let contentLayer, contentLayer.superlayer !== layer {
                layer.addSublayer(contentLayer)
                setNeedsLayout()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentLayer?.frame = bounds
    }
}

struct CameraPreviewView: UIViewRepresentable {

    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> SampleBufferContainerView {
        let view = SampleBufferContainerView()
        view.backgroundColor = .black
        displayLayer.videoGravity = .resizeAspectFill
        view.contentLayer = displayLayer
        return view
    }

    func updateUIView(_ uiView: SampleBufferContainerView, context: Context) {
        if uiView.contentLayer !== displayLayer {
            uiView.contentLayer = displayLayer
        }
    }
}
