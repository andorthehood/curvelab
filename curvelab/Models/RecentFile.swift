import Foundation

struct RecentFile: Codable, Identifiable {
    let id: UUID
    var url: URL
    var lastOpened: Date
}
