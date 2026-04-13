import CoreImage

enum DNGLoader {
    static func load(url: URL) -> CIImage? {
        guard let rawFilter = CIRAWFilter(imageURL: url) else {
            // Fallback for non-raw DNG or standard image files
            return CIImage(contentsOf: url)
        }

        // Disable automatic adjustments to get the flat scan data
        rawFilter.boostAmount = 0
        rawFilter.isGamutMappingEnabled = false

        return rawFilter.outputImage
    }
}
