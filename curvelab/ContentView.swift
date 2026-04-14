import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ImageViewModel()

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // Left: Image preview + crop overlay
                let previewSize = CGSize(width: geo.size.width / 2, height: geo.size.height)
                ZStack {
                    Color(white: 0.12)
                    if viewModel.isLoading {
                        ProgressView("Loading…")
                            .foregroundStyle(.white)
                    } else if viewModel.previewImage != nil {
                        ImagePreviewView(image: viewModel.previewImage)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 48))
                                .foregroundStyle(.gray)
                            Text("Import a DNG to get started")
                                .foregroundStyle(.gray)
                        }
                    }
                    if viewModel.hasCachedImage && viewModel.showCropOverlay {
                        CropOverlayView(
                            cropState: $viewModel.cropState,
                            imageSize: viewModel.imageSize,
                            viewSize: previewSize
                        )
                    }
                }
                .frame(width: geo.size.width / 2)

                Divider()

                // Right: Curve editor panel
                VStack(spacing: 16) {
                    ChannelPickerView(activeChannel: $viewModel.curves.activeChannel)

                    LevelsView(
                        blackPoint: $viewModel.inputBlackPoint,
                        whitePoint: $viewModel.inputWhitePoint,
                        histogram: viewModel.histogram
                    )
                    .disabled(viewModel.originalImage == nil)

                    if let levelsHistogram = viewModel.levelsHistogram {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("After Levels")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ResultHistogramView(
                                histogram: levelsHistogram,
                                activeChannel: .rgb
                            )
                        }
                    }

                    CurveEditorView(
                        curves: viewModel.curves,
                        histogram: viewModel.levelsHistogram ?? viewModel.histogram,
                        blackPoint: 0,
                        whitePoint: 1
                    )
                    .frame(maxWidth: .infinity)

                    if let outputHistogram = viewModel.outputHistogram {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Output")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ResultHistogramView(
                                histogram: outputHistogram,
                                activeChannel: .rgb
                            )
                        }
                    }

                    Toggle("Linear Export", isOn: $viewModel.exportLinear)
                        .toggleStyle(.checkbox)
                        .disabled(viewModel.originalImage == nil)

                    Toggle("Negative", isOn: $viewModel.isNegative)
                        .toggleStyle(.checkbox)
                        .disabled(viewModel.originalImage == nil)

                    Toggle("Show Crop", isOn: $viewModel.showCropOverlay)
                        .toggleStyle(.checkbox)
                        .disabled(viewModel.originalImage == nil)

                    HStack {
                        Button("Apply Crop") { viewModel.applyCrop() }
                            .disabled(viewModel.originalImage == nil)
                        Button("Reset Crop") { viewModel.resetCrop() }
                            .disabled(!viewModel.cropState.isActive)
                    }
                    .disabled(!viewModel.showCropOverlay)

                    Spacer()
                }
                .padding()
                .frame(width: geo.size.width / 2)
            }
        }
        .navigationTitle(viewModel.fileName)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    viewModel.importImage()
                } label: {
                    Label("Import DNG", systemImage: "square.and.arrow.down")
                }

                Button {
                    viewModel.exportJPG()
                } label: {
                    Label("Export JPG", systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.previewImage == nil)

                Button {
                    viewModel.rotateLeft()
                } label: {
                    Label("Rotate Left", systemImage: "rotate.left")
                }
                .disabled(viewModel.originalImage == nil)

                Button {
                    viewModel.rotateRight()
                } label: {
                    Label("Rotate Right", systemImage: "rotate.right")
                }
                .disabled(viewModel.originalImage == nil)

                Button {
                    viewModel.resetCurves()
                } label: {
                    Label("Reset Curves", systemImage: "arrow.counterclockwise")
                }
                .disabled(viewModel.originalImage == nil)
            }
        }
    }
}

#Preview {
    ContentView()
}
