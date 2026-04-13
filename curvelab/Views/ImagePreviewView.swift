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

        if let device = MTLCreateSystemDefaultDevice() {
            mtkView.device = device
            mtkView.colorPixelFormat = .bgra8Unorm_srgb
            context.coordinator.setup(device: device)
        }

        return mtkView
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        context.coordinator.ciImage = image
        mtkView.setNeedsDisplay(mtkView.bounds)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var ciImage: CIImage?
        private var ciContext: CIContext?
        private var commandQueue: MTLCommandQueue?

        func setup(device: MTLDevice) {
            commandQueue = device.makeCommandQueue()
            ciContext = CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false
            ])
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let ciImage,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let ciContext else { return }

            let drawableSize = view.drawableSize
            guard drawableSize.width > 0, drawableSize.height > 0 else { return }

            let imageExtent = ciImage.extent
            guard imageExtent.width > 0, imageExtent.height > 0 else { return }

            // Scale image to fit drawable maintaining aspect ratio
            let scaleX = drawableSize.width / imageExtent.width
            let scaleY = drawableSize.height / imageExtent.height
            let scale = min(scaleX, scaleY)

            let scaledWidth = imageExtent.width * scale
            let scaledHeight = imageExtent.height * scale
            let offsetX = (drawableSize.width - scaledWidth) / 2
            let offsetY = (drawableSize.height - scaledHeight) / 2

            let transformed = ciImage
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

            let destination = CIRenderDestination(
                width: Int(drawableSize.width),
                height: Int(drawableSize.height),
                pixelFormat: view.colorPixelFormat,
                commandBuffer: commandBuffer,
                mtlTextureProvider: { drawable.texture }
            )
            destination.isFlipped = false

            // Clear the drawable to dark gray
            let clearColor = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12))
                .cropped(to: CGRect(origin: .zero, size: drawableSize))

            let composited = transformed.composited(over: clearColor)

            try? ciContext.startTask(toRender: composited, to: destination)

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
