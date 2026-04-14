import SwiftUI

struct RecentFilesView: View {
    @ObservedObject var store: RecentFilesStore
    @ObservedObject var viewModel: ImageViewModel

    private let cellWidth: CGFloat  = 120
    private let cellHeight: CGFloat = 80

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(spacing: 4) {
                ForEach(store.files) { file in
                    cell(for: file)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func cell(for file: RecentFile) -> some View {
        let isActive = viewModel.sourceURL == file.url

        Button {
            guard !isActive else { return }
            viewModel.openURL(file.url)
        } label: {
            ZStack {
                thumbnailImage(for: file, isActive: isActive)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cellWidth, height: cellHeight)
                    .clipped()
                    .cornerRadius(4)

                if isActive {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: cellWidth, height: cellHeight)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: cellWidth, height: cellHeight)
        .contextMenu {
            Button("Remove from Recents", role: .destructive) {
                store.remove(id: file.id)
            }
        }
    }

    private func thumbnailImage(for file: RecentFile, isActive: Bool) -> Image {
        // Active file shows the live thumbnail
        if isActive, let cg = viewModel.activeFileLiveThumbnail {
            return Image(nsImage: NSImage(cgImage: cg, size: .zero))
        }
        // Inactive files load the stored JPEG from disk
        if let ns = store.loadThumbnail(for: file.id) {
            return Image(nsImage: ns)
        }
        // Placeholder (no thumbnail stored yet)
        return Image(systemName: "photo")
    }
}
