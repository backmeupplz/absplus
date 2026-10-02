import SwiftUI

@main
struct ABSPlusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { RootView() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ a: UIApplication, handleEventsForBackgroundURLSession id: String, completionHandler: @escaping () -> Void) {
        Downloader.shared.bgDone = completionHandler
        _ = Downloader.shared.session
    }
}

struct RootView: View {
    @State private var full = false
    @State private var tab = 0

    var body: some View {
        Group {
            if app.me == nil || app.expired {
                LoginView()
            } else {
                TabView(selection: $tab) {
                    Tab("Home", systemImage: "house", value: 0) { Stack { HomeView() } }
                    Tab("Library", systemImage: "books.vertical", value: 1) { Stack { LibraryView() } }
                    Tab("Series", systemImage: "square.stack", value: 2) { Stack { SeriesView() } }
                    Tab("Favorites", systemImage: "heart", value: 3) { Stack { FavoritesView() } }
                }
                .tabViewBottomAccessory(isEnabled: player.now != nil) {
                    MiniPlayer().onTapGesture { full = true }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if app.offline {
                        HStack {
                            Text("Offline · showing downloads only").font(.footnote.weight(.semibold))
                            Spacer()
                            Button("Retry") { Task { await app.ping() } }.font(.footnote.weight(.semibold))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .foregroundStyle(.white)
                        .background(.red.gradient)
                    }
                }
                .sheet(isPresented: $full) { FullPlayer() }
                .task {
                    Downloader.shared.restore()
                    await player.restore()
                    try? await Task.sleep(for: .seconds(2)) // interrupted transfers report back with their resume data first
                    await app.resumeQueue()
                }
            }
        }
        .overlay(alignment: .top) {
            if let t = app.toast {
                Text(t).font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect()
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { app.toast = nil }
            }
        }
        .animation(.default, value: app.toast)
        .task(id: app.toast) {
            guard app.toast != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            app.toast = nil
        }
        .task(id: app.offline) { // try to get back online every 10s
            while app.offline && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await app.ping()
            }
        }
        .confirmationDialog("Resume “\(player.choices?.0.title ?? "")” from", isPresented: Bindable(player).choices.some(), titleVisibility: .visible) {
            if let c = player.choices {
                ForEach(c.1.indices, id: \.self) { i in
                    Button("\(c.1[i].who) — \(fmt(c.1[i].time))") { player.start(c.0, c.1[i].time) }
                }
            }
        }
    }
}

struct LoginView: View {
    @State private var url = app.server
    @State private var user = ""
    @State private var pass = ""
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image("Logo").resizable().frame(width: 96, height: 96)
                    .clipShape(.rect(cornerRadius: 22)).padding(.top, 56)
                Text("ABS+").font(.largeTitle.bold())
                Text("A tiny, fast Audiobookshelf player").foregroundStyle(.secondary).padding(.bottom, 20)
                Group {
                    TextField("Server URL", text: $url).keyboardType(.URL).textContentType(.URL)
                    TextField("Username", text: $user).textContentType(.username)
                    SecureField("Password", text: $pass).textContentType(.password)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(.fill.tertiary, in: .rect(cornerRadius: 12))
                Button(action: signIn) {
                    Group { if busy { ProgressView() } else { Text("Sign in") } }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy || url.isEmpty || user.isEmpty)
                .padding(.top, 8)
                Text("You need an Audiobookshelf server to sign in to.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onSubmit(signIn)
    }

    private func signIn() {
        guard !busy, !url.isEmpty, !user.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do { _ = try await app.login(url, user, pass, main: true) } catch { app.say(error) }
        }
    }
}

struct MiniPlayer: View {
    var body: some View {
        if let n = player.now {
            HStack(spacing: 10) {
                Cover(id: n.item, radius: 6).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(n.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(n.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title3) }
                    .accessibilityLabel(player.playing ? "Pause" : "Play")
                Button { player.skip(30) } label: { Image(systemName: "goforward.30").font(.title3) }
                    .accessibilityLabel("Forward 30 seconds")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .contentShape(.rect)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mini")
        }
    }
}

struct FullPlayer: View {
    @State private var drag: Double?

    var body: some View {
        if let n = player.now {
            let t = drag ?? player.pos
            VStack(spacing: 20) {
                Cover(id: n.item, radius: 16)
                    .frame(maxWidth: 340)
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                    .padding(.top, 40)
                VStack(spacing: 4) {
                    Text(n.title).font(.title2.bold()).multilineTextAlignment(.center).lineLimit(2)
                    Text(n.author).font(.headline).foregroundStyle(.secondary).lineLimit(1)
                }
                VStack(spacing: 2) {
                    Slider(value: Binding(get: { t }, set: { drag = $0 }), in: 0...max(1, n.duration)) { editing in
                        if !editing, let d = drag {
                            player.seek(d)
                            drag = nil
                        }
                    }
                    HStack {
                        Text(fmt(t))
                        Spacer()
                        Text("-" + fmt(n.duration - t))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack {
                    Button(String(format: "%g×", player.speed)) { player.nextSpeed() }
                        .font(.headline.monospacedDigit()).frame(width: 64)
                        .accessibilityLabel("Playback speed \(String(format: "%g", player.speed))")
                    Spacer()
                    Button { player.skip(-30) } label: { Image(systemName: "gobackward.30").font(.system(size: 32)) }
                        .accessibilityLabel("Back 30 seconds")
                    Spacer()
                    Button { player.toggle() } label: {
                        Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 76))
                    }
                    .accessibilityLabel(player.playing ? "Pause" : "Play")
                    Spacer()
                    Button { player.skip(30) } label: { Image(systemName: "goforward.30").font(.system(size: 32)) }
                        .accessibilityLabel("Forward 30 seconds")
                    Spacer()
                    RoutePicker().frame(width: 64, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .presentationDragIndicator(.visible)
        }
    }
}
