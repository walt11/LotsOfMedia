import StoreKit
import SwiftUI
import UIKit

/// What LotsOfMedia Pro unlocks. Browsing, streaming and playing playlists stay free.
enum ProFeature: String, CaseIterable, Identifiable {
    case downloads, builtInPlayer, carPlay, siri, liveTV, homeUsers, playlists, radio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .downloads: "Downloads"
        case .builtInPlayer: "Built-in Player"
        case .carPlay: "CarPlay"
        case .siri: "Siri"
        case .liveTV: "Live TV & DVR"
        case .homeUsers: "Plex Home Users"
        case .playlists: "Playlist Editing"
        case .radio: "Radio"
        }
    }

    var detail: String {
        switch self {
        case .downloads: "Save movies, shows and music for offline, with smart episode downloads"
        case .builtInPlayer: "Play MKV, AVI, DTS and other formats directly, without server conversion"
        case .carPlay: "Your music library, playlists and downloads in the car"
        case .siri: "“Play Road Trip in LotsOfMedia”"
        case .liveTV: "Watch live channels and manage recordings"
        case .homeUsers: "Switch between the people in your Plex Home"
        case .playlists: "Create playlists and add to them"
        case .radio: "Endless stations built from any song"
        }
    }

    var systemImage: String {
        switch self {
        case .downloads: "arrow.down.circle.fill"
        case .builtInPlayer: "play.rectangle.on.rectangle.fill"
        case .carPlay: "car.fill"
        case .siri: "mic.fill"
        case .liveTV: "antenna.radiowaves.left.and.right"
        case .homeUsers: "person.2.fill"
        case .playlists: "music.note.list"
        case .radio: "dot.radiowaves.left.and.right"
        }
    }
}

/// The one-time "LotsOfMedia Pro" unlock (StoreKit 2, non-consumable, Family Sharing on).
/// The last known state is cached so offline launches, CarPlay and Siri know it right away.
@MainActor @Observable
final class ProStore {
    static let shared = ProStore()
    nonisolated static let productID = "net.jwalter.LotsOfMedia.pro"
    nonisolated static let cacheKey = "pro.unlocked"
    nonisolated static let didChange = Notification.Name("ProStore.didChange")
    /// Siri hands this to the app when someone without Pro asks it to play something.
    nonisolated static let siriUnlockActivity = "net.jwalter.LotsOfMedia.unlockPro"
    /// Tests that exercise Pro features set this instead of buying.
    nonisolated(unsafe) static var unlockedForTesting = false
    /// Tests turn this off so a locked feature doesn't cover later screens with the unlock screen.
    nonisolated(unsafe) static var showsPaywall = true

    /// Readable from any thread (the built-in player check, Siri, CarPlay).
    nonisolated static var isUnlocked: Bool {
        unlockedForTesting || UserDefaults.standard.bool(forKey: cacheKey)
    }

    private(set) var unlocked = ProStore.isUnlocked {
        didSet {
            guard unlocked != oldValue else { return }
            UserDefaults.standard.set(unlocked, forKey: Self.cacheKey)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }
    var isUnlocked: Bool { unlocked || Self.unlockedForTesting }
    private(set) var product: Product?
    private(set) var purchasing = false
    var message: String?
    @ObservationIgnored private var updates: Task<Void, Never>?

    /// Price as the App Store shows it, e.g. "$4.99".
    var price: String? { product?.displayPrice }

    func start() {
        guard updates == nil else { return }
        // Purchases from other devices, Family Sharing, offer codes, Ask to Buy, refunds.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task { await refresh(); await loadProduct() }
    }

    func loadProduct() async {
        guard product == nil else { return }
        product = try? await Product.products(for: [Self.productID]).first
    }

    /// Current entitlement from StoreKit (works offline once it has synced).
    func refresh() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil { owned = true }
        }
        unlocked = owned
    }

    func purchase() async {
        await loadProduct()
        guard let product else { message = "The App Store isn't available right now. Try again in a moment."; return }
        purchasing = true
        defer { purchasing = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let t)):
                await t.finish()
                await refresh()
                Haptics.success()
            case .success(.unverified):
                message = "The App Store couldn't verify the purchase."
            case .pending:
                message = "Waiting for approval. Pro unlocks as soon as it's approved."
            default: break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func restore() async {
        purchasing = true
        defer { purchasing = false }
        try? await AppStore.sync()
        await refresh()
        if !unlocked { message = "No previous purchase was found for this Apple Account." }
    }

    /// True when Pro is unlocked; otherwise shows the unlock screen and returns false.
    @discardableResult
    static func require(_ feature: ProFeature) -> Bool {
        if shared.isUnlocked { return true }
        presentPaywall(feature)
        return false
    }

    /// Shows the unlock screen over whatever is on screen, including other sheets. It waits a
    /// moment so a sheet that closes itself after the tap (download options) doesn't take it along.
    static func presentPaywall(_ feature: ProFeature?, after delay: Duration = .milliseconds(350)) {
        guard showsPaywall else { return }
        guard delay > .zero else { return showPaywall(feature) }
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            showPaywall(feature)
        }
    }

    private static func showPaywall(_ feature: ProFeature?) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let root = (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?
            .windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        if top is PaywallHostingController { return }
        let host = PaywallHostingController(rootView: AnyView(
            ProPaywallView(feature: feature).environment(ProStore.shared).modifier(ThemeTint()).preferredColorScheme(.dark)
        ))
        top.present(host, animated: true)
    }
}

final class PaywallHostingController: UIHostingController<AnyView> {}
