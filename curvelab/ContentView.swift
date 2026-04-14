import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ImageViewModel()

    @State private var sidebarWidth: CGFloat = 320

    private let minSidebarWidth: CGFloat = 260
    private let minImageWidth:   CGFloat = 280

    var body: some View {
        GeometryReader { geo in
            let clampedSidebar = max(minSidebarWidth,
                                    min(geo.size.width - minImageWidth, sidebarWidth))
            let dividerX = geo.size.width - clampedSidebar  // left edge of divider in layout space

            HStack(spacing: 0) {
                // Left: Image preview + crop overlay
                let previewSize = CGSize(width: dividerX - 6, height: geo.size.height)
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
                            viewSize: previewSize,
                            aspectRatio: viewModel.cropAspectRatio
                        )
                    }
                }
                .frame(width: dividerX - 6)

                // Divider — gesture uses named coordinate space so value.location.x
                // is always in the stable HStack frame, not the divider's moving frame.
                ZStack {
                    Color(white: 0.18)
                    Color(white: 0.3).frame(width: 1)
                }
                .frame(width: 6)
                .onHover { hovering in
                    if hovering { NSCursor.resizeLeftRight.push() }
                    else        { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("layout"))
                        .onChanged { value in
                            let newWidth = geo.size.width - value.location.x
                            sidebarWidth = max(minSidebarWidth,
                                               min(geo.size.width - minImageWidth, newWidth))
                        }
                )

                // Right: editing panel — ordered to match the processing pipeline
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 16) {
                        let hasImage = viewModel.originalImage != nil

                        // ── 1. Negative ──────────────────────────────────────
                        Toggle("Negative", isOn: $viewModel.isNegative)
                            .toggleStyle(.checkbox)
                            .disabled(!hasImage)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        // ── 2. Crop ───────────────────────────────────────────
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Show Crop", isOn: $viewModel.showCropOverlay)
                                .toggleStyle(.checkbox)
                                .disabled(!hasImage)

                            // Aspect ratio toggle buttons
                            let presets: [(String, CGSize?)] = [
                                ("Free", nil),
                                ("1:1",  CGSize(width: 1,  height: 1)),
                                ("2:3",  CGSize(width: 2,  height: 3)),
                                ("3:2",  CGSize(width: 3,  height: 2)),
                                ("4:5",  CGSize(width: 4,  height: 5)),
                                ("5:4",  CGSize(width: 5,  height: 4)),
                                ("16:9", CGSize(width: 16, height: 9)),
                            ]
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 48, maximum: 72))],
                                spacing: 4
                            ) {
                                ForEach(presets, id: \.0) { label, size in
                                    let selected = viewModel.cropAspectRatio == size
                                    Button(label) {
                                        viewModel.cropAspectRatio = selected ? nil : size
                                    }
                                    .buttonStyle(.plain)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                                    .background(selected
                                        ? Color.accentColor
                                        : Color(white: 0.25))
                                    .foregroundStyle(selected
                                        ? Color.white
                                        : Color.secondary)
                                    .cornerRadius(4)
                                }
                            }
                            .disabled(!viewModel.showCropOverlay || !hasImage)

                            HStack {
                                Button("Apply Crop") { viewModel.applyCrop() }
                                    .disabled(!hasImage)
                                Button("Reset Crop") { viewModel.resetCrop() }
                                    .disabled(!viewModel.cropState.isActive)
                            }
                            .disabled(!viewModel.showCropOverlay)
                        }

                        Divider()

                        // ── 3. Input levels ───────────────────────────────────
                        LevelsView(
                            blackPoint: $viewModel.inputBlackPoint,
                            whitePoint: $viewModel.inputWhitePoint,
                            histogram: viewModel.histogram
                        )
                        .disabled(!hasImage)

                        // ── 4. After-levels histogram ─────────────────────────
                        if let levelsHistogram = viewModel.levelsHistogram {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("After Levels")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ResultHistogramView(histogram: levelsHistogram)
                            }
                        }

                        Divider()

                        // ── 5. Curves ─────────────────────────────────────────
                        ChannelPickerView(activeChannel: $viewModel.curves.activeChannel)

                        CurveEditorView(
                            curves: viewModel.curves,
                            histogram: viewModel.levelsHistogram ?? viewModel.histogram
                        )
                        .frame(maxWidth: .infinity)

                        // ── 6. Output histogram ───────────────────────────────
                        if let outputHistogram = viewModel.outputHistogram {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Output")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ResultHistogramView(histogram: outputHistogram)
                            }
                        }

                        Divider()

                        // ── 7. Export ─────────────────────────────────────────
                        Toggle("Linear Export", isOn: $viewModel.exportLinear)
                            .toggleStyle(.checkbox)
                            .disabled(!hasImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
                .frame(width: clampedSidebar)
            }
            .coordinateSpace(name: "layout")
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
