import StoreKit
import SwiftUI

/// The Apple TV unlock screen. Same purchase as on iPhone and iPad (Universal Purchase),
/// so it lists what Pro does here and notes what it adds on the phone.
struct ProPaywallView: View {
    var feature: ProFeature? = nil
    /// Shown in place of a tab's content (Live TV): no "Not Now" button.
    var inline = false
    @Environment(ProStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// What Pro does on Apple TV today.
    private let tvFeatures: [ProFeature] = [.builtInPlayer, .liveTV, .homeUsers]

    var body: some View {
        HStack(alignment: .top, spacing: 100) {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "sparkles").font(.system(size: 70)).foregroundStyle(TVTheme.accent)
                Text("LotsOfMedia Pro").font(TVTheme.title(64))
                Text(feature.map { "Unlock \($0.title) and everything below with one purchase, for good." }
                     ?? "One purchase unlocks everything below, for good.")
                    .font(.title3).foregroundStyle(.secondary)
                if store.isUnlocked {
                    Label("Pro is unlocked", systemImage: "checkmark.seal.fill").font(.title2.bold()).foregroundStyle(TVTheme.accent)
                    if !inline { Button("Done") { dismiss() } }
                } else {
                    Button { Task { await store.purchase() } } label: {
                        Text(store.price.map { "Unlock Pro · \($0)" } ?? "Unlock Pro").font(.headline).frame(minWidth: 500)
                    }
                    .disabled(store.purchasing)
                    Text(store.price == nil ? "Getting the price from the App Store…" : "One-time purchase. Family Sharing included.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 30) {
                        Button("Restore Purchase") { Task { await store.restore() } }
                        if !inline { Button("Not Now") { dismiss() } }
                    }
                }
            }
            .buttonStyle(TVActionStyle())
            .frame(maxWidth: 800, alignment: .leading)
            VStack(alignment: .leading, spacing: 28) {
                Text("On Apple TV").font(.headline).foregroundStyle(.secondary)
                ForEach(tvFeatures) { row($0) }
                Text("On iPhone and iPad").font(.headline).foregroundStyle(.secondary).padding(.top, 20)
                ForEach(ProFeature.allCases.filter { !tvFeatures.contains($0) }) { row($0) }
            }
            .frame(maxWidth: 800, alignment: .leading)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TVTheme.background.ignoresSafeArea())
        .alert("LotsOfMedia Pro", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
        .task {
            for _ in 0..<4 where store.product == nil {
                await store.loadProduct()
                if store.product == nil { try? await Task.sleep(for: .seconds(3)) }
            }
        }
    }

    private func row(_ f: ProFeature) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: f.systemImage).font(.title3).foregroundStyle(TVTheme.accent).frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(f.title).font(.headline)
                Text(f.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
