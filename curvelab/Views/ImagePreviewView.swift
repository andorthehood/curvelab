import SwiftUI
import MetalKit
import CoreImage

struct ImagePreviewView: NSViewRepresentable {
    let image: CIImage?
    let hdrEnabled: Bool

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.delegate = context.coordinator
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true
        mtkView.framebufferOnly = false

        if let device = MTLCreateSystemDefaultDevice() {
            mtkView.device = device
            context.coordinator.setup(device: device, hdr: hdrEnabled)
            applyHDR(hdrEnabled, to: mtkView)
        }

        return mtkView
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.hdrEnabled != hdrEnabled {
            applyHDR(hdrEnabled, to: mtkView)
            if let device = mtkView.device {
                coordinator.setup(device: device, hdr: hdrEnabled)
            }
        }
        coordinator.ciImage = image
        mtkView.setNeedsDisplay(mtkView.bounds)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func applyHDR(_ enabled: Bool, to mtkView: MTKView) {
        if enabled {
            mtkView.colorPixelFormat = .rgba16Float
            if let metalLayer = mtkView.layer as? CAMetalLayer {
                metalLayer.wantsExtendedDynamicRangeContent = true
                metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            }
        } else {
            mtkView.colorPixelFormat = .bgra8Unorm_srgb
            if let metalLayer = mtkView.layer as? CAMetalLayer {
                metalLayer.wantsExtendedDynamicRangeContent = false
                metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            }
        }
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var ciImage: CIImage?
        var hdrEnabled = false
        private var ciContext: CIContext?
        private var commandQueue: MTLCommandQueue?
        private var device: MTLDevice?

        func setup(device: MTLDevice, hdr: Bool) {
            self.device = device
            self.hdrEnabled = hdr
            self.commandQueue = device.makeCommandQueue()
            let workingColorSpace = hdr
                ? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
                : CGColorSpace(name: CGColorSpace.linearSRGB)!
            self.ciContext = CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .workingColorSpace: workingColorSpace
            ])
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let ciImage,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let ciContext else { return }

            // Use actual texture dimensions to avoid stale drawableSize after format changes
            let drawableWidth = CGFloat(drawable.texture.width)
            let drawableHeight = CGFloat(drawable.texture.height)
            guard drawableWidth > 0, drawableHeight > 0 else { return }

            let imageExtent = ciImage.extent
            guard imageExtent.width > 0, imageExtent.height > 0 else { return }

            let scaleX = drawableWidth / imageExtent.width
            let scaleY = drawableHeight / imageExtent.height
            let scale = min(scaleX, scaleY)

            let scaledWidth = imageExtent.width * scale
            let scaledHeight = imageExtent.height * scale
            let offsetX = (drawableWidth - scaledWidth) / 2
            let offsetY = (drawableHeight - scaledHeight) / 2

            let transformed = ciImage
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

            let colorSpace = hdrEnabled
                ? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
                : CGColorSpace(name: CGColorSpace.sRGB)!

            let bounds = CGRect(x: 0, y: 0, width: drawableWidth, height: drawableHeight)

            let clearColor = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12))
                .cropped(to: bounds)
            let composited = transformed.composited(over: clearColor)

            // Synchronous render into the command buffer — avoids half-frame writes
            // when multiple draws fire in quick succession
            ciContext.render(composited, to: drawable.texture, commandBuffer: commandBuffer, bounds: bounds, colorSpace: colorSpace)

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
