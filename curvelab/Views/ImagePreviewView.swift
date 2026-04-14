import SwiftUI
import MetalKit
import CoreImage

struct ImagePreviewView: NSViewRepresentable {
    let image: CIImage?

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.delegate = context.coordinator
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true
        mtkView.framebufferOnly = false
        mtkView.colorPixelFormat = .bgra8Unorm

        if let device = MTLCreateSystemDefaultDevice() {
            mtkView.device = device
            context.coordinator.setup(device: device)
        }
        return mtkView
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        context.coordinator.ciImage = image
        mtkView.setNeedsDisplay(mtkView.bounds)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MTKViewDelegate {
        var ciImage: CIImage?
        private var ciContext: CIContext?
        private var commandQueue: MTLCommandQueue?

        func setup(device: MTLDevice) {
            commandQueue = device.makeCommandQueue()
            ciContext = CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!
            ])
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let ciImage,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let ciContext else { return }

            let drawableWidth  = CGFloat(drawable.texture.width)
            let drawableHeight = CGFloat(drawable.texture.height)
            guard drawableWidth > 0, drawableHeight > 0 else { return }

            let imageExtent = ciImage.extent
            guard imageExtent.width > 0, imageExtent.height > 0 else { return }

            let scale   = min(drawableWidth / imageExtent.width, drawableHeight / imageExtent.height)
            let offsetX = (drawableWidth  - imageExtent.width  * scale) / 2
            let offsetY = (drawableHeight - imageExtent.height * scale) / 2

            let transformed = ciImage
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

            let bounds = CGRect(x: 0, y: 0, width: drawableWidth, height: drawableHeight)
            let composited = transformed.composited(over:
                CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12)).cropped(to: bounds))

            ciContext.render(composited, to: drawable.texture,
                             commandBuffer: commandBuffer, bounds: bounds,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
