import AVKit
import SwiftUI

/// Covers from the server (resized to 400px webp), cached in memory and on disk.
@MainActor enum Covers {
    private static let cache = NSCache<NSString, UIImage>()
    private static var missing = Set<String>() // no cover on the server (this run only)
    private static var loading: [String: Task<UIImage?, Never>] = [:]
    private static let dir = URL.cachesDirectory.appending(path: "covers")

    static func mem(_ id: String) -> UIImage? { cache.object(forKey: id as NSString) }

    static func get(_ id: String) async -> UIImage? {
        if id.isEmpty || missing.contains(id) { return nil }
        if let i = mem(id) { return i }
        if let t = loading[id] { return await t.value }
        let t = Task { () -> UIImage? in
            defer { loading[id] = nil }
            let f = dir.appending(path: id)
            var data = try? Data(contentsOf: f)
            if data == nil, let u = URL(string: "\(app.server)/api/items/\(id)/cover?width=400&format=webp") {
                var r = URLRequest(url: u)
                if let t = try? await app.token() { r.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
                if let (d, resp) = try? await URLSession.shared.data(for: r) {
                    let code = (resp as? HTTPURLResponse)?.statusCode
                    if code == 404 { missing.insert(id) }
                    if code == 200 {
                        data = d
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try? d.write(to: f)
                    }
                }
            }
            guard let data, let img = await UIImage(data: data)?.byPreparingForDisplay() else { return nil }
            cache.setObject(img, forKey: id as NSString)
            return img
        }
        loading[id] = t
        return await t.value
    }
}

/// Rounded cover; height = width * ratio.
struct Cover: View {
    let id: String
    var ratio: CGFloat = 1
    var radius: CGFloat = 8
    @State private var img: UIImage?

    var body: some View {
        Rectangle().fill(.fill.tertiary)
            .aspectRatio(1 / ratio, contentMode: .fit)
            .overlay {
                if let img { Image(uiImage: img).resizable().scaledToFill() }
                else { Image(systemName: "book.closed").font(.title3).foregroundStyle(.tertiary) }
            }
            .clipShape(.rect(cornerRadius: radius))
            .task(id: id) {
                img = Covers.mem(id)
                if img == nil {
                    let image = await Covers.get(id)
                    guard !Task.isCancelled else { return }
                    img = image
                }
            }
    }
}

/// Cover at its natural aspect ratio, for the item page.
struct BigCover: View {
    let id: String
    @State private var img: UIImage?

    var body: some View {
        Group {
            if let img { Image(uiImage: img).resizable().scaledToFit().clipShape(.rect(cornerRadius: 16)) }
            else { RoundedRectangle(cornerRadius: 16).fill(.fill.tertiary).aspectRatio(1, contentMode: .fit) }
        }
        .frame(maxHeight: 300)
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
        .task(id: id) {
            img = Covers.mem(id)
            let image = await Covers.get(id)
            guard !Task.isCancelled else { return }
            img = image
        }
    }
}

struct Tile: View {
    let card: Card
    var ratio: CGFloat = 1

    var body: some View {
        let p = app.pct(card.key) ?? 0
        VStack(alignment: .leading, spacing: 4) {
            Cover(id: card.id, ratio: ratio)
                .overlay(alignment: .topTrailing) {
                    if app.downloaded(card) {
                        Image(systemName: "arrow.down.circle.fill")
                            .symbolRenderingMode(.palette).foregroundStyle(.white, .tint)
                            .font(.system(size: 18)).padding(4)
                            .accessibilityLabel("Downloaded")
                    }
                }
            ProgressView(value: min(p, 1)).opacity(p > 0 ? 1 : 0)
            Text(card.title.isEmpty ? "Loading title…" : card.title).font(.footnote.weight(.semibold)).lineLimit(2)
            Text(card.sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(.rect)
    }
}

struct CardGrid: View {
    let cards: [Card]
    var ratio: CGFloat = 1

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)], spacing: 16) {
            ForEach(cards, id: \.key) { c in
                NavigationLink(value: Route.item(c.id)) { Tile(card: c, ratio: ratio) }.buttonStyle(.plain)
            }
        }
        .scrollTargetLayout()
        .padding(16)
    }
}

struct Row<A: View>: View {
    let card: Card
    let meta: String
    @ViewBuilder var action: A

    var body: some View {
        HStack(spacing: 14) {
            Cover(id: card.id).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            action
        }
    }
}

extension Row where A == EmptyView {
    init(card: Card, meta: String) { self.init(card: card, meta: meta) { EmptyView() } }
}

struct PlayButton: View {
    let busy: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            if busy { ProgressView() } else { Image(systemName: "play.fill") }
        }
        .disabled(busy)
        .buttonStyle(.bordered).buttonBorderShape(.circle)
        .accessibilityLabel("Play")
    }
}

/// done -> remove, downloading -> cancel (a ring shows how far it got), otherwise -> download what's missing
struct DlButton: View {
    let n: Now
    @State private var ask = false

    var body: some View {
        let _ = app.dlv
        let done = n.tracks.allSatisfy { app.done(n.item, $0) }
        let failed = app.downloadError(n) != nil
        let busy = !done && app.queued(n) && !failed
        Button {
            if done || busy { ask = true } else {
                app.toast = "Downloading…"
                Task { await app.download(n) }
            }
        } label: {
            if busy { DlRing(n: n) }
            else { Image(systemName: done ? "checkmark.circle.fill" : "arrow.down.circle") }
        }
        .accessibilityLabel(done ? "Remove download" : busy ? "Cancel download" : failed ? "Retry download" : "Download")
        .confirmationDialog(busy ? "Cancel downloading “\(n.title)”?" : "Remove the download of “\(n.title)”?", isPresented: $ask, titleVisibility: .visible) {
            Button(busy ? "Cancel download" : "Remove download", role: .destructive) { app.remove(n) }
        }
    }
}

/// download progress around a stop square; a spinner until bytes arrive
struct DlRing: View {
    let n: Now

    var body: some View {
        let (have, total) = app.dlBytes(n)
        ZStack {
            if have > 0 && total > 0 {
                Circle().stroke(.tint.opacity(0.25), lineWidth: 2.5)
                Circle().trim(from: 0, to: Double(have) / Double(total))
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: have)
            } else {
                ProgressView()
            }
            Image(systemName: "stop.fill").font(.system(size: 7, weight: .black))
        }
        .frame(width: 20, height: 20)
    }
}

/// "45% · 47 MB of 105 MB", or "Waiting" until the first bytes arrive
@MainActor func dlStatus(_ n: Now) -> String {
    if let error = app.downloadError(n) { return error }
    if app.downloadWaiting(n) { return "Waiting to retry…" }
    let (have, total) = app.dlBytes(n)
    return have > 0 && total > 0 ? "\(Int(Double(have) / Double(total) * 100))% · \(bytes(have)) of \(bytes(total))" : "Waiting"
}

/// The title downloading now, above the player; tapping it opens Downloads.
struct DlBar: View {
    @Environment(Nav.self) private var nav

    var body: some View {
        if let n = app.dlq.first {
            let (have, total) = app.dlBytes(n)
            let more = app.dlq.count - 1
            Button { nav.open(.downloads) } label: {
                HStack(spacing: 10) {
                    Cover(id: n.item, radius: 6).frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(n.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(dlStatus(n) + (more > 0 ? " · \(more) more" : "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        ProgressView(value: total > 0 ? min(1, Double(have) / Double(total)) : 0)
                    }
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .contentShape(.rect)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .accessibilityIdentifier("dlbar")
        }
    }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}

enum Route: Hashable {
    case item(String), shelf(String, [Card], CGFloat), settings, downloads
}

/// a tab's navigation path, so any screen in it can push another
@Observable final class Nav {
    var path = NavigationPath()
    func open(_ r: Route) { path.append(r) }
}

/// A tab's navigation stack.
struct Stack<Root: View>: View {
    @ViewBuilder var root: Root
    @State private var nav = Nav()

    var body: some View {
        NavigationStack(path: $nav.path) {
            root.navigationDestination(for: Route.self) { r in
                switch r {
                case .item(let id): ItemView(id: id)
                case .shelf(let name, let cards, let ratio): ShelfView(name: name, cards: cards, ratio: ratio)
                case .settings: SettingsView()
                case .downloads: DownloadsView()
                }
            }
        }
        .safeAreaInset(edge: .bottom) { DlBar() }
        .environment(nav)
    }
}

/// Keep the full series roster for the lifetime of this route. Download and
/// connectivity changes refresh membership, not the navigation/scroll context.
struct ShelfView: View {
    let name: String
    let cards: [Card]
    let ratio: CGFloat
    @State private var visibleTitle: String?

    var body: some View {
        ScrollView { CardGrid(cards: avail(cards), ratio: ratio) }
            // Use native stable targets without pinning to .top: keep the intra-row offset.
            .scrollPosition(id: $visibleTitle)
            .navigationTitle(name)
    }
}

extension View {
    func settingsButton() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
            }
        }
    }
}

extension Binding {
    /// true while an optional is set; setting false clears it
    func some<T>() -> Binding<Bool> where Value == T? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }
}

/// offline: only what's playable without the server
@MainActor func avail(_ cards: [Card]) -> [Card] { app.offline ? cards.filter { app.downloaded($0) } : cards }

/// library cover shape; ABS coverAspectRatio: 1 = square, 0 = book (1.6)
@MainActor func ratio(_ lib: String) -> CGFloat {
    let r = UserDefaults.standard.double(forKey: "ratio:\(lib)")
    return r > 0 ? r : 1
}

func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

func plain(_ html: String) -> String {
    guard !html.isEmpty, let data = html.data(using: .utf8),
          let a = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
    else { return html }
    return a.string.trimmingCharacters(in: .whitespacesAndNewlines)
}
