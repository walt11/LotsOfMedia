import StoreKit
import SwiftUI

/// The LotsOfMedia Pro unlock screen. `feature` is what the person tapped, shown first.
struct ProPaywallView: View {
    var feature: ProFeature? = nil
    /// Shown in place of a tab's content: no Close button and no navigation stack of its own.
    var inline = false
    @Environment(ProStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var redeeming = false

    private var features: [ProFeature] {
        guard let feature else { return ProFeature.allCases }
        return [feature] + ProFeature.allCases.filter { $0 != feature }
    }

    var body: some View {
        if inline { page } else { NavigationStack { page } }
    }

    private var page: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                if store.isUnlocked { unlockedNote } else { featureList }
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) { if !store.isUnlocked { buyBar } }
        .background(Cinema.background)
        .toolbar {
            if !inline { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .alert("LotsOfMedia Pro", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
        .offerCodeRedemption(isPresented: $redeeming) { _ in Task { await store.refresh() } }
        .task {
            // The price comes from the App Store; try again briefly if it isn't available yet.
            for _ in 0..<4 where store.product == nil {
                await store.loadProduct()
                if store.product == nil { try? await Task.sleep(for: .seconds(3)) }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Cinema.accent)
                .padding(.top, 8)
            Text("LotsOfMedia Pro").font(Cinema.title(34))
            Text(feature.map { "Unlock \($0.title) and everything below with one purchase, for good." }
                 ?? "One purchase unlocks everything below, for good.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(features) { f in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: f.systemImage)
                        .font(.title3)
                        .foregroundStyle(Cinema.accent)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.title).font(.headline)
                        Text(f.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Browsing, streaming and playing your playlists stay free.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(18)
        .background(Cinema.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var unlockedNote: some View {
        VStack(spacing: 12) {
            Label("Pro is unlocked", systemImage: "checkmark.seal.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Cinema.accent)
            Text("Thank you for supporting LotsOfMedia.").foregroundStyle(.secondary)
            Button("Done") { dismiss() }.prominentButton().padding(.top, 8)
        }
        .padding(.top, 20)
    }

    private var buyBar: some View {
        VStack(spacing: 10) {
            Button { Task { await store.purchase() } } label: {
                Group {
                    if store.purchasing { ProgressView() }
                    else { Text(store.price.map { "Unlock Pro · \($0)" } ?? "Unlock Pro") }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .prominentButton()
            .disabled(store.purchasing)
            Text(store.price == nil ? "Getting the price from the App Store…" : "One-time purchase. Family Sharing included.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Button("Restore Purchase") { Task { await store.restore() } }
                Button("Redeem Code") { redeeming = true }
            }
            .font(.footnote)
            .disabled(store.purchasing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

/// Shows `content` with Pro, or the unlock screen in its place (sheets and tabs).
struct ProGate<Content: View>: View {
    let feature: ProFeature
    @ViewBuilder let content: Content
    @Environment(ProStore.self) private var store

    /// True when the gate fills a tab rather than a sheet.
    var inline = false

    init(_ feature: ProFeature, inline: Bool = false, @ViewBuilder content: () -> Content) {
        self.feature = feature
        self.inline = inline
        self.content = content()
    }

    var body: some View {
        if store.isUnlocked { content } else { ProPaywallView(feature: feature, inline: inline) }
    }
}

/// Settings → LotsOfMedia Pro.
struct ProSettingsSection: View {
    @Environment(ProStore.self) private var store
    @State private var showPaywall = false
    @State private var redeeming = false

    var body: some View {
        Section {
            if store.isUnlocked {
                Label("Pro Unlocked", systemImage: "checkmark.seal.fill").foregroundStyle(Cinema.accent)
            } else {
                Button { showPaywall = true } label: {
                    LabeledContent {
                        Text(store.price ?? "").foregroundStyle(.secondary)
                    } label: {
                        Label("Unlock LotsOfMedia Pro", systemImage: "sparkles")
                    }
                }
                Button("Restore Purchase") { Task { await store.restore() } }
                Button("Redeem Code") { redeeming = true }
            }
        } header: {
            Text("LotsOfMedia Pro")
        }
        .sheet(isPresented: $showPaywall) { ProPaywallView() }
        .offerCodeRedemption(isPresented: $redeeming) { _ in Task { await store.refresh() } }
        .alert("LotsOfMedia Pro", isPresented: Binding(get: { store.message != nil && !showPaywall }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
        .task { await store.loadProduct() }
    }
}

/// A small "PRO" tag next to settings that need it.
struct ProBadge: View {
    @Environment(ProStore.self) private var store
    var body: some View {
        if !store.isUnlocked {
            Text("PRO")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Cinema.accent.opacity(0.2), in: Capsule())
                .foregroundStyle(Cinema.accent)
        }
    }
}
