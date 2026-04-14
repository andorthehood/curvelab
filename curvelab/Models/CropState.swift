import CoreImage

struct CropState {
    var rect: CGRect   // image pixel coordinate space, CIImage origin (bottom-left)
    var isActive: Bool // true after Apply Crop, false after reset or new import

    static let minimumSize: CGFloat = 32

    static func full(for image: CIImage) -> CropState {
        CropState(rect: image.extent, isActive: false)
    }

    func clamped(to extent: CGRect) -> CropState {
        var r = rect.intersection(extent)
        if r.width < CropState.minimumSize { r.size.width = CropState.minimumSize }
        if r.height < CropState.minimumSize { r.size.height = CropState.minimumSize }
        return CropState(rect: r, isActive: isActive)
    }
}
