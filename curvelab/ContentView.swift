import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel        = ImageViewModel()
    @StateObject private var presetStore      = PresetStore()
    @StateObject private var recentFilesStore = RecentFilesStore()

    @State private var sidebarWidth: CGFloat = 320
    @State private var excludeClipEnds: Bool = false
    @State private var showingExportDialog = false

    private let minSidebarWidth:    CGFloat = 260
    private let minImageWidth:      CGFloat = 280
    private let presetsColumnWidth: CGFloat = 128
    private let recentFilesBarHeight: CGFloat = 96

    var body: some View {
        VStack(spacing: 0) {
        GeometryReader { geo in
            let clampedSidebar = max(minSidebarWidth,
                                    min(geo.size.width - minImageWidth - presetsColumnWidth, sidebarWidth))
            let dividerX = geo.size.width - clampedSidebar - presetsColumnWidth

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
                // dividerX = geo.width - clampedSidebar - presetsColumnWidth
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
                            let newWidth = geo.size.width - presetsColumnWidth - value.location.x
                            sidebarWidth = max(minSidebarWidth,
                                               min(geo.size.width - minImageWidth - presetsColumnWidth, newWidth))
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
                        HStack {
                            Spacer()
                            Toggle("Exclude clip ends", isOn: $excludeClipEnds)
                                .toggleStyle(.checkbox)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        LevelsView(
                            blackPoint: $viewModel.inputBlackPoint,
                            whitePoint: $viewModel.inputWhitePoint,
                            histogram: hist(viewModel.histogram),
                            onLinkedBlackPointChanged: { viewModel.setBlackPointWithCurves($0) },
                            linkedBlackPointMax: viewModel.linkedBlackPointMax,
                            onDragBegan: { viewModel.recordUndoPoint() }
                        )
                        .disabled(!hasImage)

                        // ── 4. After-levels histogram ─────────────────────────
                        if let levelsHistogram = viewModel.levelsHistogram {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("After Levels")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ResultHistogramView(histogram: hist(levelsHistogram))
                            }
                        }

                        Divider()

                        // ── 5. Curves ─────────────────────────────────────────
                        HStack {
                            ChannelPickerView(activeChannel: $viewModel.curves.activeChannel)
                            Spacer()
                            Button("Absorb BP") {
                                viewModel.absorbCurveBlackPoint()
                            }
                            .font(.caption)
                            .disabled(!hasImage || (viewModel.curves.activeCurve.sortedPoints.first?.x ?? 0) == 0)
                        }

                        CurveEditorView(
                            curves: viewModel.curves,
                            histogram: hist(viewModel.levelsHistogram ?? viewModel.histogram),
                            onDragBegan: { viewModel.recordUndoPoint() }
                        )
                        .frame(maxWidth: .infinity)

                        // ── 6. Output histogram ───────────────────────────────
                        if let outputHistogram = viewModel.outputHistogram {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Output")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ResultHistogramView(histogram: hist(outputHistogram))
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

                // Right: presets column
                PresetsView(store: presetStore, viewModel: viewModel)
                    .frame(width: presetsColumnWidth)
                    .background(Color(white: 0.14))
            }
            .coordinateSpace(name: "layout")
        } // GeometryReader

        Divider()

        RecentFilesView(store: recentFilesStore, viewModel: viewModel)
            .frame(height: recentFilesBarHeight)
            .background(Color(white: 0.11))

        } // VStack
        .navigationTitle(viewModel.fileName)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    viewModel.importImage()
                } label: {
                    Label("Import DNG", systemImage: "square.and.arrow.down")
                }

                Button {
                    showingExportDialog = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
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
                    viewModel.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!viewModel.canUndo)

                Button {
                    viewModel.resetCurves()
                } label: {
                    Label("Reset Curves", systemImage: "arrow.counterclockwise")
                }
                .disabled(viewModel.originalImage == nil)
            }
        }
        .onAppear {
            // Save outgoing file's thumbnail before a new file loads.
            viewModel.willLoadNewFile = { [weak viewModel, weak recentFilesStore] in
                guard let vm = viewModel, let store = recentFilesStore,
                      let url = vm.sourceURL,
                      let entry = store.files.first(where: { $0.url == url }) else { return }
                vm.renderSmallThumbnail { cg in
                    guard let cg else { return }
                    store.saveThumbnail(cg, for: entry.id)
                }
            }
        }
        .onChange(of: viewModel.sourceURL) { url in
            guard let url else { return }
            recentFilesStore.recordOpened(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            guard let url = viewModel.sourceURL,
                  let entry = recentFilesStore.files.first(where: { $0.url == url }) else { return }
            viewModel.renderSmallThumbnail { cg in
                guard let cg else { return }
                recentFilesStore.saveThumbnail(cg, for: entry.id)
            }
        }
        .sheet(isPresented: $showingExportDialog) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Export")
                    .font(.headline)

                Button("Export JPG") {
                    showingExportDialog = false
                    exportJPG()
                }
                .disabled(viewModel.previewImage == nil)

                Button("Export TIFF 16-bit (No Edits)") {
                    showingExportDialog = false
                    export16BitTIFF()
                }
                .disabled(viewModel.originalImage == nil)

                HStack {
                    Spacer()
                    Button("Close") {
                        showingExportDialog = false
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
    }

    // MARK: - Helpers

    /// Applies the clip-ends exclusion to an optional histogram based on the current toggle state.
    private func hist(_ h: HistogramData?) -> HistogramData? {
        guard let h else { return nil }
        return excludeClipEnds ? h.withClipEndsExcluded : h
    }

    private func exportJPG() {
        guard let previewImage = viewModel.previewImage else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "\(viewModel.fileName)_edited.jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        viewModel.isLoading = true
        let linear = viewModel.exportLinear
        Task.detached {
            ExportPipeline.writeJPEG(previewImage: previewImage, linear: linear, to: url)
            await MainActor.run {
                viewModel.isLoading = false
            }
        }
    }

    private func export16BitTIFF() {
        guard let originalImage = viewModel.originalImage else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tiff]
        panel.nameFieldStringValue = "\(viewModel.fileName)_inverted.tiff"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        viewModel.isLoading = true
        let rotation = viewModel.rotationAngle
        let cropRect = viewModel.exportCropRect
        Task.detached {
            let imageToExport = ExportPipeline.makeUneditedExportImage(
                from: originalImage,
                rotation: rotation,
                cropRect: cropRect
            )
            if let master = ExportPipeline.makeIntegerMaster(from: imageToExport) {
                ExportPipeline.write16BitTIFF(master: master, to: url)
            }
            await MainActor.run {
                viewModel.isLoading = false
            }
        }
    }
}

#Preview {
    ContentView()
}
