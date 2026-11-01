import SwiftUI

// MARK: - Spotlight (what's focused)

/// The Continue Watching item under focus on Home. The page's backdrop and the spotlight follow it.
/// Changes settle for a moment first, so sweeping across a row doesn't flicker through artwork.
@MainActor @Observable
final class TVSpotlight {
    static let shared = TVSpotlight()
    private(set) var item: PlexMetadata?
    @ObservationIgnored private var pending: Task<Void, Never>?

    func focus(_ item: PlexMetadata) {
        guard item.ratingKey != self.item?.ratingKey else { pending?.cancel(); return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) { self.item = item }
        }
    }

    /// Focus moved to a row other than Continue Watching: the backdrop goes blank.
    func clear() {
        pending?.cancel()
        guard item != nil else { return }
        pending = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) { self.item = nil }
        }
    }

    /// The first thing shown before anything is focused (once per launch).
    @ObservationIgnored private var seeded = false
    func seed(_ item: PlexMetadata?) {
        guard !seeded, self.item == nil, let item else { return }
        seeded = true
        self.item = item
    }

    /// A different profile, server or account: drop the old one's artwork and let its Home seed again.
    func reset() {
        pending?.cancel()
        pending = nil
        item = nil
        seeded = false
    }
}

private struct SpotlightClearer: ViewModifier {
    @Environment(\.isFocused) private var focused
    func body(content: Content) -> some View {
        content.onChange(of: focused) { _, now in if now { TVSpotlight.shared.clear() } }
    }
}

private struct SpotlightReporter: ViewModifier {
    @Environment(\.isFocused) private var focused
    let item: PlexMetadata
    func body(content: Content) -> some View {
        content.onChange(of: focused) { _, now in if now { TVSpotlight.shared.focus(item) } }
    }
}

extension View {
    /// Put inside a button's label: focusing the button makes `item` the spotlight.
    func reportsSpotlight(_ item: PlexMetadata) -> some View { modifier(SpotlightReporter(item: item)) }
    /// Put inside a button's label: focusing it clears the spotlight (rows other than Continue Watching).
    func clearsSpotlight() -> some View { modifier(SpotlightClearer()) }
}

// MARK: - Buttons

/// The app's button look (same as Settings): dark slate, white text, white and lifted under focus.
/// Sized to the tab bar: the same height as its pills, with text at its labels' size.
/// `selected` marks the current choice in a row of options (a lighter slate); `compact` is a
/// smaller size for rows of filters.
struct TVActionStyle: ButtonStyle {
    var selected = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, selected: selected, compact: compact) }

    private struct Face: View {
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var enabled
        let configuration: Configuration
        let selected: Bool
        let compact: Bool

        var body: some View {
            configuration.label
                .font(compact ? .caption.weight(selected ? .bold : .medium) : .callout.weight(selected ? .bold : .semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, compact ? 20 : 28)
                .padding(.vertical, compact ? 8 : 11)
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(focused ? Color.white : (selected ? Color.white.opacity(0.24) : TVTheme.surface),
                            in: RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 14)
                    .strokeBorder(focused ? .clear : AppTheme.border, lineWidth: 1))
                .scaleEffect(reduceMotion ? 1 : (focused ? 1.04 : (configuration.isPressed ? 0.97 : 1)))
                .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 16, y: 8)
                .opacity(enabled ? 1 : 0.45)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: focused)
        }
    }
}

// MARK: - Ambient backdrop

/// Full-screen artwork of the spotlight item behind the page, dimmed so text stays readable,
/// crossfading as focus moves.
struct TVAmbientBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var item: PlexMetadata?
    /// How much of the artwork shows (Home's top is brighter; other pages stay subtle).
    var strength: Double = 1

    var body: some View {
        ZStack {
            TVTheme.background
            if let item, let path = item.tvBackdropPath {
                TVImage(path: path, width: 1920, height: 1080, placeholderIcon: "")
                    .id(item.ratingKey)
                    .transition(.opacity)
                    .opacity(0.9 * strength)
            }
            // Darken toward the bottom and left, where the rows and text sit.
            LinearGradient(colors: [.clear, TVTheme.background.opacity(0.75), TVTheme.background],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [TVTheme.background.opacity(0.85), TVTheme.background.opacity(0.2), .clear],
                           startPoint: .leading, endPoint: .trailing)
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: item?.ratingKey)
    }
}

/// Home's spotlight: big title, details, quality and summary of the focused item.
struct TVSpotlightHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var item: PlexMetadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let item {
                if item.kind == .episode, let show = item.grandparentTitle {
                    Text(show.uppercased()).font(.caption.weight(.bold)).tracking(2).foregroundStyle(TVTheme.accent)
                }
                Text(item.kind == .episode ? item.title : item.tvCardTitle)
                    .font(TVTheme.title(64))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 14) {
                    let meta = item.tvMetaLine
                    if !meta.isEmpty { Text(meta).font(.callout).foregroundStyle(TVTheme.secondary) }
                    TVQualityChips(item: item)
                }
                if let summary = item.summary, !summary.isEmpty {
                    Text(summary).font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(3)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
            }
        }
        .id(item?.ratingKey)
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: item?.ratingKey)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Quality chips

/// 4K / HDR / Dolby Vision / 5.1 / rating, like on iPhone.
struct TVQualityChips: View {
    let item: PlexMetadata

    var body: some View {
        let chips = Self.chips(for: item)
        if !chips.isEmpty {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    Text(chip)
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    static func chips(for item: PlexMetadata) -> [String] {
        var out: [String] = []
        if let media = item.primaryMedia {
            if let res = media.resolutionLabel { out.append(res) }
            let video = media.parts.first?.streams.first { $0.streamType == 1 }
            if video?.doviPresent == true { out.append("DOLBY VISION") }
            else if video?.colorTrc == "smpte2084" { out.append("HDR10") }
            else if video?.colorTrc == "arib-std-b67" { out.append("HLG") }
            if let ch = media.audioChannels, ch > 2 { out.append(ch >= 8 ? "7.1" : ch >= 6 ? "5.1" : "\(ch)CH") }
        }
        let scores = item.externalScores
        if scores.isEmpty, let r = item.audienceRating ?? item.rating { out.append(String(format: "★ %.1f", r)) }
        for score in scores.prefix(3) {
            switch score.site {
            case .imdb: out.append("IMDb \(score.text)")
            case .tomatoes: out.append("\(score.positive ? "🍅" : "🟢") \(score.text)")
            case .tomatoesAudience: out.append("🍿 \(score.text)")
            case .tmdb: out.append("TMDB \(score.text)")
            case .tvdb: out.append("TVDB \(score.text)")
            case .community: out.append("★ \(score.text)")
            }
        }
        return out
    }
}

extension PlexMetadata {
    /// Wide artwork for backdrops: the item's own, or its show's / album's.
    var tvBackdropPath: String? { art ?? grandparentArt ?? (kind == .episode ? thumb : nil) }
}

// MARK: - Page scrolling

extension Notification.Name {
    /// Focus moved up into the tab bar: pages scroll back to their top.
    static let tvFocusEnteredTabBar = Notification.Name("tvFocusEnteredTabBar")
}

/// Watches the focus engine and announces when focus moves from a page into the tab bar.
/// tvOS leaves the tab bar pinned at the screen's edge while the page underneath stays
/// scrolled down; scrolling the page back to the top puts the tab bar where it belongs.
@MainActor
enum TVTabBarFocusWatcher {
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { note in
            guard let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            MainActor.assumeIsolated {
                if isInTabBar(context.nextFocusedItem), !isInTabBar(context.previouslyFocusedItem) {
                    NotificationCenter.default.post(name: .tvFocusEnteredTabBar, object: nil)
                }
            }
        }
    }

    private static func isInTabBar(_ item: UIFocusItem?) -> Bool {
        var view = item as? UIView
        while let v = view {
            if v is UITabBar || String(describing: type(of: v)).contains("TabBar") { return true }
            view = v.superview
        }
        return false
    }
}

/// A page's vertical scroll view that returns to the top when focus goes up to the tab bar.
struct TVPageScrollView<Content: View>: View {
    var showsIndicators = true
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: showsIndicators) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.topID)
                    content
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .tvFocusEnteredTabBar)) { _ in
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.topID, anchor: .top) }
            }
        }
    }

    private static var topID: String { "tv.page.top" }
}

// MARK: - PIN pad

/// A Plex Home profile's 4-digit PIN on a number pad, checked as soon as the fourth digit is in:
/// no keyboard and no Continue button. A wrong PIN shakes and clears for another try. Back deletes
/// a digit, or cancels when none are entered.
struct TVPinPad: View {
    let user: PlexHomeUser
    /// Switches to the profile with this PIN; throws if it's wrong.
    let submit: (String) async throws -> Void
    let cancel: () -> Void
    @State private var digits = ""
    @State private var error: String?
    @State private var checking = false
    @State private var shakes = 0
    @FocusState private var focusedKey: String?

    private static let length = 4
    private static let delete = "delete"
    private static let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", delete]

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 16) {
                TVAvatar(path: user.thumb, name: user.title, size: 110)
                Text("Enter PIN for \(user.title)").font(.title2.weight(.semibold))
            }
            HStack(spacing: 30) {
                ForEach(0..<Self.length, id: \.self) { i in
                    Circle().fill(.white.opacity(i < digits.count ? 1 : 0.2)).frame(width: 28, height: 28)
                }
            }
            .modifier(Shake(animatableData: CGFloat(shakes)))
            Group {
                if checking { ProgressView() } else { Text(error ?? " ").foregroundStyle(.red) }
            }
            .font(.callout)
            .frame(height: 36)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(180), spacing: 50), count: 3), spacing: 40) {
                ForEach(Self.keys, id: \.self) { key in
                    if key.isEmpty {
                        Color.clear.frame(width: 140, height: 70)
                    } else {
                        Button { press(key) } label: {
                            Group {
                                if key == Self.delete { Image(systemName: "delete.left") } else { Text(key) }
                            }
                            .font(.system(size: 40, weight: .semibold))
                            .frame(width: 140, height: 70)
                        }
                        .focused($focusedKey, equals: key)
                    }
                }
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TVTheme.background.ignoresSafeArea())
        .defaultFocus($focusedKey, "5")
        .onExitCommand { if digits.isEmpty || checking { cancel() } else { digits.removeLast() } }
        // A keyboard or a remote with number keys types straight in.
        .onKeyPress(characters: .decimalDigits, phases: .down) { press($0.characters); return .handled }
        .onKeyPress(.delete, phases: .down) { _ in press(Self.delete); return .handled }
    }

    private func press(_ key: String) {
        guard !checking else { return }
        if key == Self.delete {
            if !digits.isEmpty { digits.removeLast() }
            return
        }
        guard digits.count < Self.length else { return }
        error = nil
        digits += key
        if digits.count == Self.length { Task { await check() } }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            try await submit(digits)
        } catch {
            self.error = error.localizedDescription
            digits = ""
            withAnimation(.linear(duration: 0.4)) { shakes += 1 }
        }
    }

    private struct Shake: GeometryEffect {
        var animatableData: CGFloat
        func effectValue(size: CGSize) -> ProjectionTransform {
            ProjectionTransform(CGAffineTransform(translationX: 16 * sin(animatableData * .pi * 4), y: 0))
        }
    }
}
