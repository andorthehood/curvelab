import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ImageViewModel()

    var body: some View {
        HSplitView {
            // Left: Image preview
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
            }
            .frame(minWidth: 400)

            // Right: Curve editor panel
            VStack(spacing: 16) {
                ChannelPickerView(activeChannel: $viewModel.curves.activeChannel)

                CurveEditorView(curves: viewModel.curves, histogram: viewModel.histogram)
                    .frame(maxWidth: .infinity)

                if let histogram = viewModel.histogram {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Output")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ResultHistogramView(
                            histogram: histogram.remapped(through: viewModel.curves),
                            activeChannel: viewModel.curves.activeChannel
                        )
                    }
                }

                Spacer()
            }
            .padding()
            .frame(width: 300)
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
