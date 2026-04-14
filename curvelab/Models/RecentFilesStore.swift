import AppKit
import Foundation

@MainActor
class RecentFilesStore: ObservableObject {
    @Published private(set) var files: [RecentFile] = []

    private let storeURL: URL
    private let thumbnailsDir: URL

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("CurveLab")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        storeURL     = dir.appendingPathComponent("recentfiles.json")
        thumbnailsDir = dir.appendingPathComponent("thumbnails")
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)

        load()
        pruneDeleted()
    }

    // MARK: - List management

    /// Adds `url` to the front if new; otherwise just updates lastOpened in place.
    @discardableResult
    func recordOpened(_ url: URL) -> RecentFile {
        if let idx = files.firstIndex(where: { $0.url == url }) {
            files[idx].lastOpened = Date()
            save()
            return files[idx]
        }
        let entry = RecentFile(id: UUID(), url: url, lastOpened: Date())
        files.insert(entry, at: 0)
        save()
        return entry
    }

    func remove(id: UUID) {
        deleteThumbnail(for: id)
        files.removeAll { $0.id == id }
        save()
    }

    // MARK: - Thumbnails

    func thumbnailURL(for id: UUID) -> URL {
        thumbnailsDir.appendingPathComponent("\(id.uuidString).jpg")
    }

    func saveThumbnail(_ cgImage: CGImage, for id: UUID) {
        let url = thumbnailURL(for: id)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cgImage,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    func loadThumbnail(for id: UUID) -> NSImage? {
        NSImage(contentsOf: thumbnailURL(for: id))
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([RecentFile].self, from: data) else { return }
        files = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(files) else { return }
        try? data.write(to: storeURL)
    }

    /// Remove entries whose source file no longer exists on disk.
    private func pruneDeleted() {
        let before = files.count
        files.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        if files.count != before { save() }
    }

    private func deleteThumbnail(for id: UUID) {
        try? FileManager.default.removeItem(at: thumbnailURL(for: id))
    }
}
