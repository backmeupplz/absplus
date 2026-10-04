#if DEBUG
import SwiftUI

/// Real views with synthetic local state; no playback or personal account is used.
struct AccessibilityFixture: View {
    // SwiftUI can reconstruct this view after observed singleton state changes.
    // Seed once per test process, not again after a favorite/player interaction.
    private static var prepared = false

    init() {
        guard !Self.prepared else { return }
        Self.prepared = true
        URLProtocol.registerClass(ListFixtureProtocol.self)
        UserDefaults.standard.set("http://abs-list-fixture.invalid", forKey: "server")
        app.accts = ["fixture": Tok(a: "fixture", r: ""), "Reader": Tok(a: "fixture", r: "")]
        app.me = "fixture"
        app.fav = []
        app.favq = [:]
        player.now = Now(item: "accessibility", ep: nil, title: "Fixture audio", author: "Fixture author", tracks: [])
        player.playing = false
        player.speed = 1
    }

    var body: some View {
        Stack {
            List {
                NavigationLink("Settings", value: Route.settings)
                NavigationLink("Details", value: Route.item("accessibility"))
                NavigationLink("Player") {
                    VStack {
                        Button("Change fixture playback state") { player.playing.toggle() }
                        MiniPlayer()
                        FullPlayer()
                    }
                }
            }
        }
        // Intercept real About link actions so tests never leave the fixture.
        .environment(\.openURL, OpenURLAction { url in
            app.toast = url.absoluteString
            return .handled
        })
        .overlay(alignment: .bottom) { if let url = app.toast { Text(url) } }
    }
}
#endif
