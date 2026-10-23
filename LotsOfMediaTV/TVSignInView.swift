import SwiftUI
import CoreImage.CIFilterBuiltins

/// Sign in with a short code: the TV shows it, the person enters it at plex.tv/link
/// on their phone or computer, and the TV picks up the account by checking the code.
struct TVSignInView: View {
    @Environment(TVSession.self) private var session
    @State private var pin: PlexAccount.Pin?
    @State private var error: String?
    @State private var signingIn = false

    var body: some View {
        HStack(spacing: 120) {
            VStack(alignment: .leading, spacing: 28) {
                Text("LotsOfMedia").font(.system(size: 76, weight: .heavy).width(.compressed))
                Text("Your Plex movies, shows and music.").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    step(1, "On your phone or computer, go to **plex.tv/link**")
                    step(2, "Sign in to Plex and enter this code:")
                }
                .padding(.top, 20)
                Group {
                    if let pin {
                        Text(pin.code)
                            .font(.system(size: 110, weight: .bold, design: .monospaced))
                            .kerning(18)
                            .foregroundStyle(TVTheme.accent)
                    } else if let error {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(error).foregroundStyle(.secondary)
                            Button("Get a New Code") { Task { await run() } }.buttonStyle(TVActionStyle())
                        }
                    } else {
                        ProgressView()
                    }
                }
                .frame(minHeight: 140, alignment: .leading)
                if signingIn {
                    Label("Signing in…", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else if pin != nil {
                    Text("This screen continues on its own once you've entered the code.").font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 20) {
                if let qr = Self.qrCode("https://plex.tv/link") {
                    Image(uiImage: qr).interpolation(.none).resizable().frame(width: 360, height: 360)
                        .padding(24).background(.white, in: RoundedRectangle(cornerRadius: 24))
                }
                Text("Or scan to open plex.tv/link").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TVTheme.background.ignoresSafeArea())
        .task { await run() }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text("\(n)").font(.headline).frame(width: 44, height: 44).background(TVTheme.surface, in: Circle())
            Text(text).font(.title3)
        }
    }

    /// Creates a code and waits for it to be claimed, getting a fresh one when it expires.
    private func run() async {
        error = nil
        while !Task.isCancelled && !session.isSignedIn {
            do {
                let created = try await PlexAccount.createPin(strong: false)
                pin = created
                let deadline = Date().addingTimeInterval(TimeInterval(created.expiresIn ?? 900) - 5)
                codeLoop: while Date() < deadline, !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    let checked: PlexAccount.Pin
                    do { checked = try await PlexAccount.checkPin(created.id) }
                    catch PlexError.http(let code, _) where code == 404 || code == 410 { break codeLoop }   // expired: get a new code
                    catch { continue }
                    if let token = checked.authToken, !token.isEmpty {
                        signingIn = true
                        do { try await session.signIn(token: token) } catch {
                            signingIn = false
                            self.error = "Couldn't finish signing in: \(error.localizedDescription)"
                            pin = nil
                        }
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                pin = nil
                self.error = "Couldn't reach plex.tv. Check the Apple TV's internet connection."
                return
            }
        }
    }

    static func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
