import SwiftUI
import CoreImage
import Combine
import UniformTypeIdentifiers

@MainActor
class ImageViewModel: ObservableObject {
    @Published var originalImage: CIImage?
    @Published var previewImage: CIImage?
    @Published var curves = CurveModel()
    @Published var isLoading = false
    @Published var fileName = "CurveLab"
    @Published var histogram: HistogramData?

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Subscribe to curve changes with debounce for live preview
        curves.objectWillChange
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updatePreview()
            }
            .store(in: &cancellables)
    }

    func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.rawImage, .tiff, .png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isLoading = true
        fileName = url.deletingPathExtension().lastPathComponent

        Task.detached { [weak self] in
            let image = DNGLoader.load(url: url)
            let histData = image.flatMap { HistogramData.compute(from: $0) }
            await MainActor.run {
                self?.originalImage = image
                self?.histogram = histData
                self?.curves.reset()
                self?.updatePreview()
                self?.isLoading = false
            }
        }
    }

    func updatePreview() {
        guard let originalImage else {
            previewImage = nil
            return
        }
        previewImage = LUTGenerator.applyFilter(to: originalImage, curves: curves)
    }

    func exportJPG() {
        guard let previewImage else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "\(fileName)_edited.jpg"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isLoading = true
        let imageToExport = previewImage
        let context = ciContext

        Task.detached {
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            try? context.writeJPEGRepresentation(
                of: imageToExport,
                to: url,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]
            )
            await MainActor.run { [weak self] in
                self?.isLoading = false
            }
        }
    }

    func resetCurves() {
        curves.reset()
        updatePreview()
    }
}
