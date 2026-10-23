import SwiftUI

/// Menu bar commands on a Mac (and the ⌘ shortcut list on iPad keyboards): moving between
/// sections, Listen and Watch, refreshing, and controlling music.
struct AppCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandMenu("Go") {
            Button("Home") { go(.home) }.keyboardShortcut("1")
            Button("Library") { go(.library) }.keyboardShortcut("2")
            Button("Live TV") { app.mediaMode = .watch; go(.live) }
                .keyboardShortcut("3")
                .disabled(!LiveTVStore.shared.isAvailable)
            Button("Downloads") { go(.downloads) }.keyboardShortcut("4")
            Button("Search") { go(.search) }.keyboardShortcut("f")
            Divider()
            Button("Watch") { app.mediaMode = .watch }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Listen") { app.mediaMode = .music }.keyboardShortcut("2", modifiers: [.command, .option])
            Divider()
            Button("Refresh") { app.libraryChanged() }.keyboardShortcut("r")
        }
        CommandMenu("Controls") {
            let audio = AudioPlayer.shared
            Button(audio.isPlaying ? "Pause" : "Play") { audio.toggle() }
                .keyboardShortcut("p")
                .disabled(audio.current == nil)
            Button("Next Song") { audio.next() }
                .keyboardShortcut(.rightArrow)
                .disabled(audio.current == nil)
            Button("Previous Song") { audio.previous() }
                .keyboardShortcut(.leftArrow)
                .disabled(audio.current == nil)
            Divider()
            Button(audio.shuffled ? "Shuffle Off" : "Shuffle On") { audio.toggleShuffle() }
                .disabled(audio.current == nil)
        }
    }

    private func go(_ tab: AppState.Tab) {
        if tab == .live && app.mediaMode == .music { return }
        app.selectedTab = tab
    }
}
