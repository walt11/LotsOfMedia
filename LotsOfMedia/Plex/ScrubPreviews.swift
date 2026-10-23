import UIKit

/// Thumbnails of a video at points along its timeline, shown while scrubbing: Plex's preview
/// thumbnails (one BIF file of JPEGs) or Jellyfin's trickplay images (grids of thumbnails).
@MainActor
final class ScrubPreviews {
    private enum Source {
        /// Frames (start ms, JPEG) from a Plex BIF file.
        case bif([(ms: Int, range: Range<Int>)], Data)
        case trickplay(Trickplay)
    }

    struct Trickplay {
        let width: Int, height: Int, tileWidth: Int, tileHeight: Int, count: Int, intervalMs: Int
        let itemID: String, sourceID: String
        var perTile: Int { tileWidth * tileHeight }

        /// From the part's `indexes` ("jellyfin:w:h:tw:th:count:interval:item:source").
        init?(indexes: String) {
            let f = indexes.split(separator: ":").map(String.init)
            guard f.count == 9, f[0] == "jellyfin", let w = Int(f[1]), let h = Int(f[2]), let tw = Int(f[3]), let th = Int(f[4]),
                  let n = Int(f[5]), let i = Int(f[6]), tw > 0, th > 0, i > 0 else { return nil }
            width = w; height = h; tileWidth = tw; tileHeight = th; count = n; intervalMs = i; itemID = f[7]; sourceID = f[8]
        }
    }

    private let source: Source
    private let api: PlexServerAPI
    private var tiles: [Int: UIImage] = [:]
    private var frames: [Int: UIImage] = [:]

    private init(source: Source, api: PlexServerAPI) {
        self.source = source
        self.api = api
    }

    /// Previews for the item's chosen version, if the server made them (nil otherwise).
    static func load(api: PlexServerAPI, item: PlexMetadata) async -> ScrubPreviews? {
        guard let part = item.primaryPart, let indexes = part.indexes else { return nil }
        if api.isJellyfin {
            return Trickplay(indexes: indexes).map { ScrubPreviews(source: .trickplay($0), api: api) }
        }
        guard indexes.contains("sd"),
              let (data, _) = try? await api.data("/library/parts/\(part.id)/indexes/sd", query: [URLQueryItem(name: "interval", value: "10000")],
                                                  timeout: 30),
              let frames = parseBIF(data), !frames.isEmpty else { return nil }
        return ScrubPreviews(source: .bif(frames, data), api: api)
    }

    /// Frame offsets in a BIF file: a 64-byte header, then (timestamp, offset) pairs ending in 0xFFFFFFFF.
    nonisolated static func parseBIF(_ data: Data) -> [(ms: Int, range: Range<Int>)]? {
        let magic: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count > 64, Array(data.prefix(8)) == magic else { return nil }
        func u32(_ at: Int) -> Int {
            let b = data.startIndex + at
            return Int(data[b]) | Int(data[b + 1]) << 8 | Int(data[b + 2]) << 16 | Int(data[b + 3]) << 24
        }
        let count = u32(12)
        let separation = u32(16) == 0 ? 1000 : u32(16)
        guard count > 0, 64 + (count + 1) * 8 <= data.count else { return nil }
        var out: [(ms: Int, range: Range<Int>)] = []
        for i in 0..<count {
            let start = u32(64 + i * 8 + 4), end = u32(64 + (i + 1) * 8 + 4)
            guard start < end, end <= data.count else { continue }
            out.append((u32(64 + i * 8) * separation, start..<end))
        }
        return out
    }

    /// The thumbnail nearest `ms`.
    func image(atMs ms: Int) async -> UIImage? {
        switch source {
        case .bif(let list, let data):
            guard let i = list.lastIndex(where: { $0.ms <= ms }) ?? list.indices.first else { return nil }
            if let cached = frames[i] { return cached }
            let image = UIImage(data: data.subdata(in: list[i].range))
            frames[i] = image
            return image
        case .trickplay(let t):
            let n = min(max(ms / t.intervalMs, 0), max(t.count - 1, 0))
            let tileIndex = n / t.perTile
            let tile: UIImage
            if let cached = tiles[tileIndex] { tile = cached } else {
                let url = api.url("/Videos/\(t.itemID)/Trickplay/\(t.width)/\(tileIndex).jpg",
                                  query: [URLQueryItem(name: "mediaSourceId", value: t.sourceID)], includeToken: true)
                guard let loaded = await ImageLoader.shared.image(for: url) else { return nil }
                tiles[tileIndex] = loaded
                tile = loaded
            }
            let pos = n % t.perTile
            let scale = tile.scale
            let rect = CGRect(x: CGFloat(pos % t.tileWidth * t.width) * scale, y: CGFloat(pos / t.tileWidth * t.height) * scale,
                              width: CGFloat(t.width) * scale, height: CGFloat(t.height) * scale)
            guard let cg = tile.cgImage?.cropping(to: rect) else { return nil }
            return UIImage(cgImage: cg, scale: scale, orientation: .up)
        }
    }
}
