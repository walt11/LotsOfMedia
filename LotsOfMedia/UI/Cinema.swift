import SwiftUI

/// Shared look for the "Cinema" design: deep near-black ground, artwork-led
/// pages, clear display titles, glass controls and quality chips.
enum Cinema {
    /// Poster width in every grid: three columns on iPhone, filling their cells.
    static let gridPosterWidth: CGFloat = 108
    /// The app's colors (shared with Apple TV and the widgets).
    static var accent: Color { AppTheme.accent }
    static var background: Color { AppTheme.background }
    static var glass: Color { AppTheme.glass }
    static var muted: Color { AppTheme.muted }
    /// Solid card / tile surface, a step up from the background.
    static var surface: Color { AppTheme.surface }
    /// Artwork placeholder and unselected chip fill.
    static var placeholder: Color { AppTheme.placeholder }
    /// "Server is converting" state, kept distinct from the accent used for downloading.
    static let converting = AppTheme.converting

    /// Bold display face for titles over artwork.
    static func title(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold)
    }

    /// A dark, saturated version of an artwork color, used to tint a whole page.
    static func tint(from color: UIColor) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(0.85, max(0.35, s * 1.25))), brightness: 0.24)
    }
}

/// App icon designs (Settings → App Icon), all in the icon's green, with dark and tinted
/// versions; the artwork is made by scripts/make-icons.py.
enum AppIconStyle: String, CaseIterable, Identifiable {
    case lettermark = "Lettermark", stacked = "Stacked", retroTV = "RetroTV"
    case tvNote = "TVNote", playNote = "PlayNote", speaker = "Speaker"
    case cassette = "Cassette", vhs = "VHS", vinyl = "Vinyl", glow = "Glow"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .retroTV: "Retro TV"
        case .tvNote: "TV & Note"
        case .playNote: "Play & Note"
        case .stacked: "Stacked Media"
        case .speaker: "Speaker"
        case .cassette: "Cassette"
        case .vhs: "VHS"
        case .vinyl: "Vinyl"
        case .lettermark: "LoM"
        case .glow: "Glow"
        }
    }

    /// The alternate icon for this design; nil is the primary icon (LoM).
    var iconName: String? { self == .lettermark ? nil : "Icon-\(rawValue)-Forest" }

    /// Small picture for the picker; `dark` is the dark home-screen version.
    func previewName(dark: Bool = false) -> String {
        "IconPreviews/\(rawValue)-Forest" + (dark ? "-Dark" : "")
    }
}

/// The app icon design chosen in Settings.
@Observable
final class AppIconStore {
    static let shared = AppIconStore()

    var iconStyle: AppIconStyle {
        didSet { MainActor.assumeIsolated { applyIcon() } }
    }

    /// Read from the icon actually showing: one from an older version (another color, now
    /// removed) has fallen back to the primary icon.
    private init() {
        let current = MainActor.assumeIsolated { UIApplication.shared.alternateIconName }
        iconStyle = AppIconStyle.allCases.first { $0.iconName == current } ?? .lettermark
    }

    /// UIKit pieces (alerts, menus, the video player's controls) take the window's tint.
    @MainActor static func applyToWindows() {
        let tint = UIColor(AppTheme.accent)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.tintColor = tint }
        }
    }

    @MainActor private func applyIcon() {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.alternateIconName != iconStyle.iconName else { return }
        app.setAlternateIconName(iconStyle.iconName) { _ in }
    }
}

/// Tints everything below with the accent and keeps UIKit windows in step. Switches use
/// the system green.
struct ThemeTint: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(Cinema.accent)
            .toggleStyle(GreenSwitch())
            .onAppear { AppIconStore.applyToWindows() }
    }
}

struct GreenSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(Cinema.accent)
    }
}

/// Keeps badges at readable sizes, wrapping when the available width changes.
private struct QualityChipLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(subviews, width: bounds.width).positions
        for (view, frame) in zip(subviews, positions) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, positions: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var positions: [CGRect] = []
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = ideal.width <= width ? ideal : view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), positions)
    }
}

/// Small rounded labels: NEW, 4K, HDR, DOLBY VISION, 5.1, rating.
struct QualityChips: View {
    let item: PlexMetadata
    var includeRating = true

    var body: some View {
        let chips = Self.chips(for: item, includeRating: includeRating)
        if !chips.isEmpty {
            QualityChipLayout(spacing: 5) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    Text(chip)
                        .font(.caption2.weight(.semibold))
                        .tracking(0.4)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    static func chips(for item: PlexMetadata, includeRating: Bool = true) -> [String] {
        var out: [String] = []
        if let added = item.addedAt, Date().timeIntervalSince1970 - Double(added) < 14 * 86_400, item.viewCount ?? 0 == 0 {
            out.append("NEW")
        }
        if let rating = item.contentRating, includeRating { out.append(rating) }
        if let media = item.primaryMedia {
            if let res = media.resolutionLabel { out.append(res) }
            let video = media.parts.first?.streams.first { $0.streamType == 1 }
            if video?.doviPresent == true { out.append("DOLBY VISION") }
            else if video?.colorTrc == "smpte2084" { out.append("HDR10") }
            else if video?.colorTrc == "arib-std-b67" { out.append("HLG") }
            if let ch = media.audioChannels, ch > 2 { out.append(ch >= 8 ? "7.1" : ch >= 6 ? "5.1" : "\(ch)CH") }
        }
        if includeRating, let r = item.audienceRating ?? item.rating { out.append(String(format: "★ %.1f", r)) }
        return out
    }
}

/// White primary action used over artwork.
struct CinemaPlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(.white, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Round glass button for secondary actions (download, watched, info).
struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.1)))
    }
}

extension View {
    func glassCircle() -> some View { modifier(GlassCircle()) }

    /// Filled accent button with black text, like every other label drawn on the accent.
    func prominentButton() -> some View {
        buttonStyle(.borderedProminent).foregroundStyle(.black)
    }
}

/// Tabs drawn as text with an underline, as in the Cinema detail page.
struct CinemaTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let label: (Tab) -> String
    var underline: Color = Cinema.accent

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(tabs) { tab in
                    let on = tab == selection
                    Button { withAnimation(.easeInOut(duration: 0.2)) { selection = tab } } label: {
                        VStack(spacing: 6) {
                            Text(label(tab))
                                .font(.system(size: 15, weight: on ? .bold : .semibold))
                                .foregroundStyle(on ? Color.white : Cinema.muted)
                            Capsule().fill(on ? underline : .clear).frame(height: 3)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal)
        }
    }
}
