import SwiftUI

// --- home: continue listening (server, all devices) + recently played (this device)

struct HomeView: View {
    @State private var items: [Card] = []
    @State private var loading = Loading()
    @Environment(Nav.self) private var nav

    var body: some View {
        let cont = avail(items)
        let hist = app.hist.filter { !app.offline || app.downloaded($0.card) }
        List {
            if !cont.isEmpty {
                Section("Continue listening") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(cont, id: \.key) { c in
                                Button { Task { await player.playCard(c) } } label: { Tile(card: c).frame(width: 116) }
                                    .buttonStyle(.plain)
                                    .overlay { if player.preparing == c.key { ProgressView("Preparing…").padding(8).background(.regularMaterial) } }
                                    .disabled(player.preparing == c.key)
                                    .contextMenu {
                                        Button("Play", systemImage: "play.fill") { Task { await player.playCard(c) } }
                                        Button("Details", systemImage: "info.circle") { nav.open(.item(c.id)) }
                                    }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            Section("Recently played") {
                if hist.isEmpty && loading.finished && !cont.isEmpty { Text("Nothing played on this device yet.").foregroundStyle(.secondary) }
                ForEach(hist, id: \.card.key) { h in
                    NavigationLink(value: Route.item(h.card.id)) {
                        Row(card: h.card, meta: Date(timeIntervalSince1970: h.at / 1000).formatted(.relative(presentation: .named))) {
                            PlayButton { await player.playCard(h.card) }
                        }
                    }
                    .accessibilityIdentifier("history-" + h.card.key)
                }
            }
        }
        .overlay { LoadingFeedback(state: loading, empty: cont.isEmpty && hist.isEmpty, title: "Nothing played yet", retry: reload) }
        .onDisappear { loading.cancel() }
        .navigationTitle("Home")
        .settingsButton()
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        await loading.run {
            let error = await app.load("/api/me/items-in-progress?limit=20") { (r: InProgress) in
                items = r.libraryItems.map { li in
                    let c = li.card
                    return li.recentEpisode.map { Card(id: c.id, title: $0.title ?? "", sub: c.title, ep: $0.id) } ?? c
                }
            }
            let meError = await app.load("/api/me") { (m: Me) in app.setMe(m) }
            return error ?? meError
        }
    }
}

// --- library

struct LibraryView: View {
    @State private var libs: [Library] = []
    @State private var all: [Card] = []
    @State private var q = ""
    @State private var loadedLibrary = ""
    @State private var loading = Loading()
    @State private var librariesLoading = Loading()
    @State private var visibleTitle: String?
    @AppStorage("lib") private var sel = ""

    var body: some View {
        VStack(spacing: 0) { libraryContent }
            .onDisappear { loading.cancel(); librariesLoading.cancel() }
        .task { await loadLibraries() }
        .task(id: sel) {
            if loadedLibrary != sel {
                loading.reset()
                loadedLibrary = sel
                all = []
                q = ""
            }
            await reload()
        }
    }

    @ViewBuilder private var libraryContent: some View {
        let cards = app.offline ? app.downloads().map { app.cachedCard($0.id) } : all
        let query = q.trimmingCharacters(in: .whitespaces)
        let shown = query.isEmpty ? cards : cards.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.sub.localizedCaseInsensitiveContains(query) }
        ScrollView {
            CardGrid(cards: shown, ratio: app.offline ? 1 : ratio(sel))
        }
        // Native targets retain the visible identity and its offset when results move.
        // Do not force .top: that would discard a partially scrolled row.
        .scrollPosition(id: $visibleTitle)
        .onChange(of: "\(sel):\(app.offline):\(query)") { visibleTitle = nil }
        .id("\(sel):\(app.offline):\(query)") // only a new list context resets the viewport
        .navigationTitle(app.offline ? "Downloaded" : libs.first { $0.id == sel }?.name ?? "Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            if !app.offline {
                Picker("Library", selection: $sel) {
                    ForEach(libs, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
        }
        .searchable(text: $q, prompt: "Titles & authors")
        .settingsButton()
        .overlay {
            LoadingFeedback(state: librariesLoading.error != nil || libs.isEmpty && !librariesLoading.finished ? librariesLoading : loading, empty: shown.isEmpty, title: app.offline ? "No downloads" : query.isEmpty ? "No titles" : "No matches", retry: retry)
        }

        .refreshable { await retry() }

    }

    private func retry() async {
        await loadLibraries()
        await reload()
    }

    private func loadLibraries() async {
        await librariesLoading.run {
            await app.load("/api/libraries") { (r: Libraries) in
                libs = r.libraries
                for l in libs { UserDefaults.standard.set(l.settings?.coverAspectRatio == 0 ? 1.6 : 1, forKey: "ratio:\(l.id)") }
                if !libs.contains(where: { $0.id == sel }) { sel = libs.first?.id ?? "" }
            }
        }
        if sel.isEmpty && librariesLoading.finished { loading.finished = true }
    }

    private func reload() async {
        let library = sel
        guard !library.isEmpty else { loading.finished = librariesLoading.finished; return }
        await loading.run {
            let error = await app.load("/api/libraries/\(library)/items?minified=1&sort=media.metadata.title") { (r: Results<Item>) in
                guard !Task.isCancelled, sel == library else { return }
                all = r.results.map(\.card)
            }
            let meError = await app.load("/api/me") { (m: Me) in app.setMe(m) }
            return error ?? meError
        }
    }
}

// --- series (from the server's book libraries)

struct SeriesView: View {
    @State private var libs: [Library] = []
    @State private var series: [String: [Series]] = [:]
    @State private var loading = Loading()

    var body: some View {
        List {
            ForEach(libs, id: \.id) { l in
                if let ss = series[l.id]?.filter({ !app.offline || !avail($0.books.map(\.card)).isEmpty }), !ss.isEmpty {
                    Section {
                        ForEach(ss, id: \.id) { s in
                            let cards = avail(s.books.map(\.card))
                            NavigationLink(value: Route.shelf(s.name, avail(cards), ratio(l.id))) {
                                Row(card: Card(id: cards.first?.id ?? "", title: s.name, sub: ""), meta: "\(cards.count) book\(cards.count == 1 ? "" : "s")")
                            }
                        }
                    } header: {
                        if libs.count > 1 { Text(l.name) }
                    }
                }
            }
        }
        .overlay { LoadingFeedback(state: loading, empty: series.values.flatMap { $0 }.allSatisfy { app.offline ? avail($0.books.map(\.card)).isEmpty : false }, title: app.offline ? "No downloaded series" : "No series", retry: reload) }
        .onDisappear { loading.cancel() }
        .navigationTitle("Series")
        .settingsButton()
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        await loading.run {
            var error = await app.load("/api/libraries") { (r: Libraries) in
                libs = r.libraries.filter { $0.mediaType == "book" }
                series = series.filter { key, _ in libs.contains { $0.id == key } }
            }
            for l in libs {
                guard !Task.isCancelled else { return nil }
                let failure = await app.load("/api/libraries/\(l.id)/series?limit=1000&sort=name") { (r: Results<Series>) in series[l.id] = r.results }
                error = error ?? failure
            }
            return error
        }
    }
}

// --- favorites (synced via the server, see Abs.fav)

struct FavoritesView: View {
    @State private var loading = Loading()

    var body: some View {
        ScrollView { CardGrid(cards: avail(app.fav)) }
            .overlay {
                LoadingFeedback(state: loading, empty: avail(app.fav).isEmpty, title: app.offline ? "No downloaded favorites" : "No favorites", detail: "Tap ♡ on a book or podcast to keep it here.", retry: reload)
            }
            .navigationTitle("Favorites")
            .settingsButton()
            .refreshable { await reload() }
            .task { await reload() }
            .onDisappear { loading.cancel() }
    }

    private func reload() async {
        await loading.run {
            var error = await app.load("/api/me") { (m: Me) in app.setMe(m) }
            for c in app.fav {
                guard !Task.isCancelled else { return nil }
                let failure = await app.fillFav(c.id)
                error = error ?? failure
            }
            return error
        }
    }
}

// --- settings

struct SettingsView: View {
    @State private var confirmLogout = false
    @State private var unlinking: String?
    @State private var linking = false

    var body: some View {
        let dls = app.downloads()
        let total = dls.reduce(0) { $0 + $1.size }
        Form {
            Section("Account") {
                LabeledContent {
                    Button("Log out", role: .destructive) { confirmLogout = true }
                } label: {
                    Text(app.me ?? "")
                    Text(app.server)
                }
            }
            Section {
                if app.accounts.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(app.accounts, id: \.self) { a in
                    let n = app.shares.values.filter { $0.contains(a) }.count
                    LabeledContent {
                        Button(role: .destructive) { unlinking = a } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).accessibilityLabel("Unlink \(a)")
                    } label: {
                        Text(a)
                        Text("Shared on \(n) title\(n == 1 ? "" : "s")")
                    }
                }
                Button("Link account", systemImage: "person.badge.plus") { linking = true }
            } header: {
                Text("Linked accounts")
            } footer: {
                Text("Accounts you can share progress with, per book or podcast (share button on its page). They sign in here once; only their login token is kept.")
            }
            Section("Storage") {
                NavigationLink(value: Route.downloads) {
                    LabeledContent("Downloads", value: "\(dls.count) item\(dls.count == 1 ? "" : "s") · \(bytes(total))" + (app.dlq.isEmpty ? "" : " · \(app.dlq.count) downloading"))
                }
            }
            Section("About") {
                Link("Website", destination: URL(string: "https://absplus.app")!)
                Link("Source code", destination: URL(string: "https://github.com/backmeupplz/absplus")!)
                Link("Privacy policy", destination: URL(string: "https://absplus.app/privacy/")!)
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Log out? Downloads are kept.", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Log out", role: .destructive) {
                player.clear()
                app.logout()
            }
        }
        .alert("Unlink \(unlinking ?? "")?", isPresented: $unlinking.some()) {
            Button("Unlink", role: .destructive) { if let a = unlinking { app.unlink(a) } }
        } message: {
            Text("Progress sharing with them stops on all titles. Their existing progress is not changed.")
        }
        .sheet(isPresented: $linking) { LinkAccount() }
    }
}

struct LinkAccount: View {
    var then: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var pass = ""
    @State private var busy = false
    @State private var err: String?
    @State private var request: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $user).textContentType(.username)
                    SecureField("Password", text: $pass).textContentType(.password)
                } footer: {
                    if let err { Text(err).foregroundStyle(.red) } else { Text("They sign in here once to allow it.") }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Link another account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button { link() } label: {
                    if busy { ProgressView("Linking…").accessibilityLabel("Linking account") } else { Text("Link") }
                }.disabled(user.isEmpty || busy) }
            }
        }
        .presentationDetents([.medium])
        .onDisappear { request?.cancel(); busy = false }
    }

    private func link() {
        guard !busy else { return }
        busy = true
        err = nil
        request = Task {
            defer { busy = false }
            do {
                let n = try await app.login(app.server, user, pass, main: false)
                if n == app.me { err = "That's you" } else {
                    app.toast = "Linked \(n)"
                    dismiss()
                    then()
                }
            } catch { if !Task.isCancelled { err = error.localizedDescription } }
        }
    }
}

// --- downloads on this device (removing never touches the server)

struct DownloadsView: View {
    @State private var removeAll = false
    @State private var stopping: Now?
    @State private var stopAll = false

    var body: some View {
        let items = app.downloads()
        let total = items.reduce(0) { $0 + $1.size }
        List {
            if !app.dlq.isEmpty {
                Section {
                    ForEach(app.dlq, id: \.key) { n in
                        let (have, all) = app.dlBytes(n)
                        NavigationLink(value: Route.item(n.item)) {
                            HStack(spacing: 14) {
                                Cover(id: n.item).frame(width: 56, height: 56)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(n.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text(dlStatus(n)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    ProgressView(value: all > 0 ? min(1, Double(have) / Double(all)) : 0)
                                }
                                Button { stopping = n } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Cancel download")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Downloading")
                        Spacer()
                        if app.dlq.count > 1 { Button("Cancel all") { stopAll = true }.textCase(nil) }
                    }
                }
            }
            if !items.isEmpty {
                Section {
                    ForEach(items, id: \.id) { d in
                        let c = app.cachedCard(d.id)
                        NavigationLink(value: Route.item(c.id)) { Row(card: c, meta: "\(c.sub) · \(bytes(d.size))") }
                            .swipeActions { Button("Remove", role: .destructive) { app.removeAll(d.id) } }
                    }
                } header: {
                    Text("\(items.count) item\(items.count == 1 ? "" : "s") · \(bytes(total))")
                } footer: {
                    Text("Swipe left to remove a download. Nothing is deleted on the server.")
                }
            }
        }
        .overlay {
            if items.isEmpty && app.dlq.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle", description: Text("Nothing downloaded on this device."))
            }
        }
        .confirmationDialog("Cancel downloading “\(stopping?.title ?? "")”?", isPresented: $stopping.some(), titleVisibility: .visible) {
            Button("Cancel download", role: .destructive) { if let n = stopping { app.remove(n) } }
        }
        .confirmationDialog("Cancel all \(app.dlq.count) downloads?", isPresented: $stopAll, titleVisibility: .visible) {
            Button("Cancel all", role: .destructive) { app.dlq.forEach { app.remove($0) } }
        }
        .navigationTitle("Downloads")
        .toolbar {
            if !items.isEmpty { Button("Remove all", role: .destructive) { removeAll = true } }
        }
        .confirmationDialog("Remove all \(items.count) downloads (\(bytes(total))) from this device? Nothing is deleted on the server.", isPresented: $removeAll, titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { items.forEach { app.removeAll($0.id) } }
        }
    }
}

// --- item page

struct ItemView: View {
    let id: String
    @State private var it: Item?
    @State private var desc = ""
    @State private var more = false
    @State private var sharing = false
    @State private var loading = Loading()

    var body: some View {
        List {
            if let it { content(it) }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { LoadingFeedback(state: loading, empty: it == nil, title: "Item unavailable", retry: reload) }
        .refreshable { await reload() }
        .task(id: id) { await reload() }
        .onDisappear { loading.cancel() }
        .sheet(isPresented: $sharing) { if let it { ShareSheet(id: id, name: it.card.title) } }
    }

    private func reload() async {
        await loading.run {
            await app.load("/api/items/\(id)?expanded=1") { (i: Item) in
                it = i
                desc = plain(i.media.metadata.description ?? "")
            }
        }
    }

    @ViewBuilder private func content(_ it: Item) -> some View {
        let c = it.card
        let book = it.mediaType == "book"
        let eps = episodes(it)
        VStack(spacing: 8) {
            BigCover(id: c.id).padding(.bottom, 8)
            Text(c.title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(c.sub).font(.headline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
            if book {
                let n = Now(item: c.id, ep: nil, title: c.title, author: c.sub, tracks: (it.media.tracks ?? []).map { $0.track() })
                let p = app.pct(c.id) ?? 0
                let meta = [fmt(n.duration), n.tracks.count > 1 ? "\(n.tracks.count) files" : nil,
                            p >= 1 ? "Finished" : p > 0 ? "\(Int(p * 100))% done" : nil].compactMap { $0 }
                Text(meta.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button { Task { await player.play(n) } } label: {
                        Group {
                            if player.preparing == n.key { ProgressView("Preparing…") }
                            else { Label(p > 0 && p < 1 ? "Resume" : "Play", systemImage: "play.fill") }
                        }.frame(minWidth: 96)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(n.tracks.isEmpty || player.preparing == n.key)
                    DlButton(n: n).buttonStyle(.bordered).buttonBorderShape(.circle)
                    actions(c)
                }
                .controlSize(.large)
                .padding(.top, 8)
            } else {
                Text("\(eps.count) episodes").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 12) { actions(c) }.controlSize(.large).padding(.top, 8)
            }
            if !desc.isEmpty {
                Text(desc).font(.callout).lineLimit(more ? nil : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
                    .onTapGesture { withAnimation { more.toggle() } }
            }
        }
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
        .padding(.vertical, 8)

        if !book {
            Section("Episodes") {
                ForEach(eps, id: \.0.key) { n, date in EpisodeRow(n: n, date: date) }
            }
        }
    }

    @ViewBuilder private func actions(_ c: Card) -> some View {
        let on = app.isFav(c.id)
        Button { _ = app.toggleFav(c) } label: { Image(systemName: on ? "heart.fill" : "heart") }
            .buttonStyle(.bordered).buttonBorderShape(.circle)
            .accessibilityLabel(on ? "Remove from favorites" : "Add to favorites")
        Button { sharing = true } label: { Image(systemName: "person.2") }
            .buttonStyle(.bordered).buttonBorderShape(.circle)
            .accessibilityLabel("Share progress")
    }

    private func episodes(_ it: Item) -> [(Now, String?)] {
        let c = it.card
        return (it.media.episodes ?? [])
            .compactMap { e in e.audioFile.map { (e, $0.track(0)) } }
            .filter { !app.offline || app.done(c.id, $0.1) }
            .sorted { ($0.0.publishedAt ?? 0) > ($1.0.publishedAt ?? 0) }
            .map { e, t in
                (Now(item: c.id, ep: e.id, title: e.title ?? "", author: c.title, tracks: [t]),
                 e.publishedAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .omitted) : nil })
            }
    }
}

struct EpisodeRow: View {
    let n: Now
    let date: String?

    var body: some View {
        let p = app.pct(n.key)
        let meta = [date, fmt(n.duration), p.map { $0 >= 1 ? "Finished" : "\(Int($0 * 100))%" }].compactMap { $0 }
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(n.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            DlButton(n: n).buttonStyle(.borderless)
            PlayButton { await player.play(n) }
        }
        .contentShape(.rect)
        .onTapGesture { Task { await player.play(n) } }
        .overlay(alignment: .trailing) { if player.preparing == n.key { ProgressView("Preparing…").padding(8).background(.regularMaterial) } }
    }
}

// --- progress sharing

struct ShareSheet: View {
    let id: String
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var sel: Set<String>
    @State private var linking = false
    @State private var confirm = false

    init(id: String, name: String) {
        self.id = id
        self.name = name
        _sel = State(initialValue: Set(app.shares[id] ?? []))
    }

    private var added: [String] { sel.subtracting(app.shares[id] ?? []).sorted() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(app.accounts, id: \.self) { a in
                        Toggle(a, isOn: Binding(get: { sel.contains(a) }, set: { if $0 { sel.insert(a) } else { sel.remove(a) } }))
                    }
                    Button("Link account", systemImage: "person.badge.plus") { linking = true }
                } header: {
                    Text("“\(name)”")
                } footer: {
                    Text(app.accounts.isEmpty
                         ? "Link another account on this server to keep your progress on this title in sync with it."
                         : "Listening here updates their progress too, and you're offered their position when they're ahead.")
                }
            }
            .navigationTitle("Share progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if added.isEmpty { save() } else { confirm = true } }.disabled(app.accounts.isEmpty)
                }
            }
            .alert("Share progress of “\(name)” with \(added.joined(separator: ", "))?", isPresented: $confirm) {
                Button("Cancel", role: .cancel) {}
                Button("Share") {
                    save()
                    app.toast = "Progress shared"
                }
            } message: {
                Text("Listening here will update their progress too, and you'll be offered their position when they're ahead.")
            }
            .sheet(isPresented: $linking) { LinkAccount() }
        }
    }

    private func save() {
        app.shares[id] = sel.sorted()
        dismiss()
    }
}
