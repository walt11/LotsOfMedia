import SwiftUI

/// A photo album to open from a photo library's grid.
struct TVPhotoAlbum: Hashable {
    let item: PlexMetadata
}

/// Albums and photos in a grid: albums open, photos open full screen.
struct TVPhotoGrid: View {
    let items: [PlexMetadata]
    var onLastAppear: () -> Void = {}
    @State private var viewing: TVPhotoViewer.Start?
    private let columns = [GridItem(.adaptive(minimum: 340, maximum: 360), spacing: 40)]
    private var photos: [PlexMetadata] { items.filter { $0.kind == .photo } }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 50) {
            ForEach(items) { item in
                Group {
                    if item.kind == .photo {
                        Button { viewing = .init(index: photos.firstIndex { $0.id == item.id } ?? 0) } label: { tile(item) }
                    } else {
                        NavigationLink(value: TVPhotoAlbum(item: item)) { tile(item) }
                    }
                }
                .buttonStyle(.borderless)
                .onAppear { if item.id == items.last?.id { onLastAppear() } }
            }
        }
        .focusSection()
        .fullScreenCover(item: $viewing) { start in TVPhotoViewer(photos: photos, index: start.index) }
    }

    private func tile(_ item: PlexMetadata) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TVImage(path: item.thumb, width: 700, height: 460, placeholderIcon: item.kind == .photo ? "photo" : "photo.stack")
                .frame(width: 340, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if item.kind != .photo {
                Label(item.title, systemImage: "photo.stack").font(.caption.weight(.semibold)).lineLimit(1)
            }
        }
    }
}

/// An album's photos (and albums inside it).
struct TVPhotoAlbumView: View {
    @Environment(TVSession.self) private var session
    let album: TVPhotoAlbum
    @State private var items: [PlexMetadata] = []

    var body: some View {
        TVPageScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text(album.item.title).font(TVTheme.title(60))
                TVPhotoGrid(items: items)
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 50)
        }
        .task { items = (try? await session.api?.children(album.item.ratingKey)) ?? [] }
    }
}

/// Full-screen photos: left and right move, Play/Pause starts a slideshow, select shows details.
struct TVPhotoViewer: View {
    struct Start: Identifiable { let index: Int; var id: Int { index } }

    @Environment(TVSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let photos: [PlexMetadata]
    @State var index: Int
    @State private var slideshow = false
    @State private var showInfo = false
    @State private var result: (index: Int, image: UIImage?)?
    @State private var retry = 0
    static let slideSeconds = 6

    private var photo: PlexMetadata? { photos.indices.contains(index) ? photos[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let result, result.index == index {
                if let image = result.image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .ignoresSafeArea()
                        .id(index)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 12) {
                        Label("Photo Unavailable", systemImage: "photo")
                            .font(.title3.bold())
                        Text("Press Select to try again.").foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView("Loading photo…")
            }
            if showInfo || slideshow, let photo, result?.index == index, result?.image != nil {
                VStack {
                    Spacer()
                    HStack(spacing: 16) {
                        if slideshow { Label("Slideshow", systemImage: "play.fill").font(.caption.weight(.bold)) }
                        Text(photo.title).font(.headline).lineLimit(1)
                        if let date = photo.originallyAvailableAt { Text(date).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text("\(index + 1) of \(photos.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 60).padding(.vertical, 30)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                }
                .ignoresSafeArea()
            }
        }
        .focusable()
        .onMoveCommand { dir in
            switch dir {
            case .left: move(-1)
            case .right: move(1)
            default: break
            }
        }
        .onTapGesture {
            if result?.index == index, result?.image == nil { retry += 1 }
            else { withAnimation { showInfo.toggle() } }
        }
        .onPlayPauseCommand { slideshow.toggle() }
        .onExitCommand { dismiss() }
        .task(id: "\(index)-\(retry)") { await loadImage() }
        // Slideshow: the next photo every few seconds, looping, until stopped.
        .task(id: slideshow) {
            while slideshow, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.slideSeconds))
                guard slideshow, !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.8)) { index = (index + 1) % max(photos.count, 1) }
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func move(_ delta: Int) {
        let next = index + delta
        guard photos.indices.contains(next) else { return }
        withAnimation(.easeInOut(duration: 0.3)) { index = next }
    }

    private func loadImage() async {
        let requestedIndex = index
        result = nil
        let path = photo?.media.first?.parts.first?.key ?? photo?.thumb
        var loaded: UIImage?
        if let url = session.imageURL(path, width: 3840, height: 2160) {
            loaded = await ImageLoader.shared.image(for: url)
        }
        guard !Task.isCancelled, requestedIndex == index else { return }
        withAnimation(.easeInOut(duration: 0.5)) { result = (requestedIndex, loaded) }
    }
}
