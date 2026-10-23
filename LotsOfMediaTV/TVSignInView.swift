import SwiftUI
import CoreImage.CIFilterBuiltins

/// Sign in with a short code: the TV shows it, the person enters it at plex.tv/link
/// on their phone or computer, and the TV picks up the account by checking the code.
struct TVSignInView: View {
    @Environment(TVSession.self) private var session
    @State private var pin: PlexAccount.Pin?
    @State private var error: String?
    @State private var signingIn = false
    @State private var showJellyfin = false

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
                Button { showJellyfin = true } label: { Label("Use a Jellyfin Server Instead", systemImage: "server.rack") }
                    .buttonStyle(TVActionStyle())
                    .padding(.top, 10)
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
        .fullScreenCover(isPresented: $showJellyfin) { TVJellyfinSignInView() }
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
        while !Task.isCancelled && session.token == nil {
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

/// Signs in to a Jellyfin server: the address, then Quick Connect (a code approved on a phone
/// or computer, no typing) or a username and password.
struct TVJellyfinSignInView: View {
    @Environment(TVSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var server: JellyfinAuth.ServerInfo?
    @State private var quickConnect: JellyfinAuth.QuickConnect?
    @State private var quickConnectAvailable = false
    @State private var working = false
    @State private var error: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("Jellyfin").font(.system(size: 76, weight: .heavy).width(.compressed))
            if let server {
                Text("\(server.name) · Jellyfin \(server.version)").font(.title3).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 80) {
                    if quickConnectAvailable {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("Quick Connect").font(.title3.bold())
                            if let quickConnect {
                                Text("In the Jellyfin app or web page, open your profile → Quick Connect and enter:")
                                    .foregroundStyle(.secondary).frame(maxWidth: 700, alignment: .leading)
                                Text(quickConnect.code).font(.system(size: 100, weight: .bold, design: .monospaced)).kerning(14)
                                    .foregroundStyle(TVTheme.accent)
                            } else {
                                Button("Show a Code") { Task { await startQuickConnect() } }.buttonStyle(TVActionStyle())
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Username and Password").font(.title3.bold())
                        TextField("Username", text: $username).textContentType(.username).frame(width: 640)
                        SecureField("Password", text: $password).textContentType(.password).frame(width: 640)
                        Button(working ? "Signing In…" : "Sign In") { Task { await signIn() } }
                            .buttonStyle(TVActionStyle()).disabled(username.isEmpty || working)
                    }
                }
            } else {
                Text("Enter your server's address, like 192.168.1.10:8096").font(.title3).foregroundStyle(.secondary)
                TextField("Server address", text: $address).keyboardType(.URL).frame(width: 900)
                Button(working ? "Looking…" : "Continue") { Task { await findServer() } }
                    .buttonStyle(TVActionStyle()).disabled(address.isEmpty || working)
            }
            if let error { Text(error).foregroundStyle(.red) }
            Spacer()
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TVTheme.background.ignoresSafeArea())
        .onDisappear { pollTask?.cancel() }
    }

    private func findServer() async {
        working = true
        error = nil
        defer { working = false }
        do {
            let found = try await JellyfinAuth.info(address: address)
            quickConnectAvailable = await JellyfinAuth.quickConnectEnabled(found)
            server = found
            if quickConnectAvailable { await startQuickConnect() }
        } catch {
            self.error = "Couldn't reach a Jellyfin server there. \(error.localizedDescription)"
        }
    }

    private func signIn() async {
        guard let server else { return }
        working = true
        error = nil
        defer { working = false }
        do { await finish(try await JellyfinAuth.signIn(server, username: username, password: password)) }
        catch { self.error = error.localizedDescription }
    }

    private func startQuickConnect() async {
        guard let server else { return }
        do {
            let qc = try await JellyfinAuth.startQuickConnect(server)
            quickConnect = qc
            pollTask?.cancel()
            pollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    if await JellyfinAuth.checkQuickConnect(server, qc) {
                        do { await finish(try await JellyfinAuth.signIn(server, quickConnect: qc)) } catch { self.error = error.localizedDescription }
                        return
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finish(_ signedIn: PlexServer) async {
        pollTask?.cancel()
        await session.addJellyfin(signedIn)
        dismiss()
    }
}

/// Settings → Add Plex Server: servers on your Plex account appear on their own (Refresh picks up
/// a new or newly shared one); others are added by address. Signs in to Plex first when only
/// Jellyfin is set up.
struct TVAddPlexServerView: View {
    @Environment(TVSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var serverToken = ""
    @State private var working = false
    @State private var message: String?
    @State private var signingIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("Add Plex Server").font(.system(size: 76, weight: .heavy).width(.compressed))
            if session.token == nil {
                Text("Sign in to Plex to see the servers on your account.").font(.title3).foregroundStyle(.secondary)
                Button("Sign In to Plex") { signingIn = true }.buttonStyle(TVActionStyle())
            } else {
                Text("Servers on your Plex account appear in Settings on their own.").font(.title3).foregroundStyle(.secondary)
                Button(working ? "Refreshing…" : "Refresh Server List") { Task { await refresh() } }
                    .buttonStyle(TVActionStyle()).disabled(working)
            }
            VStack(alignment: .leading, spacing: 18) {
                Text("Or add one by its address").font(.title3.bold()).padding(.top, 20)
                TextField("Address, like 192.168.1.10:32400", text: $address).keyboardType(.URL).frame(width: 900)
                TextField(session.token == nil ? "Plex token" : "Plex token (optional)", text: $serverToken).frame(width: 900)
                Button(working ? "Connecting…" : "Add Server") { Task { await add() } }
                    .buttonStyle(TVActionStyle()).disabled(address.isEmpty || working)
            }
            if let message { Text(message).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TVTheme.background.ignoresSafeArea())
        .fullScreenCover(isPresented: $signingIn) { TVSignInView() }
        .onChange(of: session.token) { _, token in if token != nil { signingIn = false; dismiss() } }
    }

    private func refresh() async {
        working = true
        defer { working = false }
        let before = Set(session.servers.map(\.id))
        do {
            try await session.refreshServers()
            let added = session.servers.filter { !before.contains($0.id) }.count
            message = added == 0 ? "No new servers on your account." : "Added \(added) server\(added == 1 ? "" : "s")."
        } catch {
            message = error.localizedDescription
        }
    }

    private func add() async {
        working = true
        message = nil
        defer { working = false }
        do {
            try await session.addPlexServer(address: address, serverToken: serverToken)
            dismiss()
        } catch {
            message = "Couldn't add that server. \(error.localizedDescription)"
        }
    }
}
