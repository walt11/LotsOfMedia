import SwiftUI
import UIKit
import CoreImage

/// Memory + disk cached image loading for Plex artwork.
actor ImageLoader {
    static let shared = ImageLoader()

    private nonisolated let memory = ImageMemoryCache()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        // Decoded images live in `memory`; the URL cache only needs disk. Server-side
        // resizing keeps files small, so 150 MB holds thousands of posters.
        config.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 150 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    init() {}

    nonisolated func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    private var colors: [URL: UIColor] = [:]

    /// The image's average color, for tinting a page to match its artwork.
    func averageColor(for url: URL) async -> UIColor? {
        if let c = colors[url] { return c }
        guard let image = await image(for: url), let c = image.averageColor else { return nil }
        if colors.count > 500 { colors.removeAll() }   // a long browse shouldn't grow this forever
        colors[url] = c
        return c
    }

    func image(for url: URL) async -> UIImage? {
        if let img = memory.object(forKey: url as NSURL) { return img }
        if let task = inflight[url] { return await task.value }
        let session = self.session
        // Detached: download and decode in parallel, not one at a time on this actor.
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let (data, resp) = try? await session.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let image = UIImage(data: data) else { return nil }
            return image.preparingForDisplay() ?? image
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image {
            memory.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        }
        return image
    }
}

#if os(iOS)
/// Plex artwork view. Falls back to a locally saved file (for downloads) and
/// then to a placeholder, so offline browsing still shows posters.
struct PlexImage: View {
    @Environment(AppState.self) private var app
    let path: String?
    var width: Int = 300
    var height: Int = 450
    var localFile: URL? = nil
    var placeholderIcon: String = "film"
    var contentMode: ContentMode = .fill
    var background: Color = Cinema.placeholder

    /// Kept with what it was loaded for: when the view moves to other artwork, the old picture isn't shown.
    @State private var loaded: (key: String, image: UIImage)?
    private var key: String { localFile?.path ?? url?.absoluteString ?? "" }

    private var url: URL? {
        // Absolute URLs (plex.tv avatars, provider artwork) load directly.
        if let path, path.hasPrefix("http") { return URL(string: path) }
        return app.imageURL(path, width: width, height: height)
    }

    var body: some View {
        // Already in memory (e.g. scrolling back): draw it now instead of flashing the placeholder.
        let key = self.key
        let shown = loaded.flatMap { $0.key == key ? $0.image : nil } ?? (localFile == nil ? url.flatMap { ImageLoader.shared.cached($0) } : nil)
        // The base view takes exactly the proposed size; the image is drawn as a
        // clipped overlay so a wide image can never widen its container.
        Rectangle()
            .fill(background)
            .overlay {
                if let image = shown {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                } else {
                    Image(systemName: placeholderIcon).font(.title).foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: key) { await load() }
    }

    private func load() async {
        let key = self.key
        if let localFile {
            // Decode off the main thread so scrolling stays smooth.
            let path = localFile.path
            if let img = await Task.detached(priority: .userInitiated, operation: {
                UIImage(contentsOfFile: path)?.preparingForDisplay()
            }).value {
                loaded = (key, img)
                return
            }
        }
        guard let url else { return }
        if let cached = ImageLoader.shared.cached(url) { loaded = (key, cached); return }
        // Fresh downloads fade in; already-cached artwork appears at once.
        if let image = await ImageLoader.shared.image(for: url) { withAnimation(.easeOut(duration: 0.25)) { loaded = (key, image) } }
    }
}

#endif

extension UIImage {
    /// Creating a CIContext is expensive; one is reused for every page tint.
    fileprivate static let averagingContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// Average color via a 1×1 CIAreaAverage reduction.
    var averageColor: UIColor? {
        guard let input = CIImage(image: self) else { return nil }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent),
        ])
        guard let output = filter?.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        UIImage.averagingContext
            .render(output, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }
}

/// NSCache synchronizes its own access; expose only its thread-safe operations.
private final class ImageMemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSURL, UIImage>()
    init() { cache.totalCostLimit = 96 * 1024 * 1024 }
    func object(forKey key: NSURL) -> UIImage? { cache.object(forKey: key) }
    func setObject(_ image: UIImage, forKey key: NSURL, cost: Int) { cache.setObject(image, forKey: key, cost: cost) }
}
