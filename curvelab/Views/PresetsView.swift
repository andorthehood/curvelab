import SwiftUI

struct PresetsView: View {
    @ObservedObject var store: PresetStore
    @ObservedObject var viewModel: ImageViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Presets")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let preset = viewModel.capturePreset()
                    store.add(preset)
                    viewModel.renderThumbnails(for: store.presets)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.hasCachedImage)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 4) {
                    ForEach(store.presets) { preset in
                        thumbnailCell(for: preset)
                    }
                }
                .padding(4)
            }
        }
        .onChange(of: viewModel.cacheVersion) { _ in
            viewModel.renderThumbnails(for: store.presets)
        }
        .onChange(of: store.presets.count) { _ in
            viewModel.renderThumbnails(for: store.presets)
        }
    }

    @ViewBuilder
    private func thumbnailCell(for preset: Preset) -> some View {
        Button {
            viewModel.applyPreset(preset)
        } label: {
            Group {
                if let cg = viewModel.presetThumbnails[preset.id] {
                    Image(nsImage: NSImage(cgImage: cg, size: .zero))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color(white: 0.18)
                        .aspectRatio(
                            viewModel.imageSize.width > 0
                                ? viewModel.imageSize.width / viewModel.imageSize.height
                                : 3 / 2,
                            contentMode: .fit
                        )
                }
            }
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) {
                store.delete(id: preset.id)
            }
        }
    }
}
