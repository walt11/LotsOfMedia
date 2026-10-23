import TVServices

/// The Top Shelf for LotsOfMedia: Continue Watching from the app's last visit to Home,
/// for the profile that visited; its links open the app as that profile.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> TVTopShelfContent? {
        guard let snapshot = TopShelfSnapshot.load(), snapshot.posterArt == true, !snapshot.items.isEmpty else { return nil }
        let items = snapshot.items.map { entry -> TVTopShelfSectionedItem in
            let item = TVTopShelfSectionedItem(identifier: entry.ratingKey)
            item.title = entry.subtitle.map { "\(entry.title) · \($0)" } ?? entry.title
            item.imageShape = .poster
            if let url = entry.imageURL {
                item.setImageURL(url, for: .screenScale1x)
                item.setImageURL(url, for: .screenScale2x)
            }
            if let p = entry.progress { item.playbackProgress = p }
            item.displayAction = TVTopShelfAction(url: TopShelfSnapshot.link("item", entry.ratingKey, server: snapshot.serverID, user: snapshot.userID))
            item.playAction = TVTopShelfAction(url: TopShelfSnapshot.link("play", entry.ratingKey, server: snapshot.serverID, user: snapshot.userID))
            return item
        }
        let section = TVTopShelfItemCollection(items: items)
        section.title = snapshot.userName.map { "Continue Watching · \($0)" } ?? "Continue Watching"
        return TVTopShelfSectionedContent(sections: [section])
    }
}
