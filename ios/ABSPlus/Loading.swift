import SwiftUI

/// View-owned request state: retained content is never replaced by a loading screen.
@MainActor @Observable final class Loading {
    var busy = false
    var finished = false
    var error: String?
    private var generation = 0
    private var request: Task<String?, Never>?

    func run(_ work: @escaping @MainActor () async -> String?) async {
        guard !Task.isCancelled else { return }
        guard !busy || request?.isCancelled == true else { return }
        generation += 1
        let request = generation
        busy = true
        error = nil
        let task = Task { await work() }
        self.request = task
        let failure = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard generation == request else { return }
        busy = false
        self.request = nil
        guard !Task.isCancelled, !task.isCancelled else { return }
        error = failure
        finished = true
    }

    func cancel() { generation += 1; request?.cancel(); request = nil; busy = false }
    func reset() { cancel(); finished = false; error = nil }
}

struct LoadingFeedback: View {
    let state: Loading
    let empty: Bool
    let title: String
    var detail = ""
    let retry: () async -> Void

    var body: some View {
        VStack {
            if empty { Spacer() }
            if state.busy || !state.finished {
                ProgressView(empty ? "Loading…" : "Refreshing…")
                    .padding(12).background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(empty ? "Loading" : "Refreshing")
                    .accessibilityIdentifier(empty ? "loading.initial" : "loading.refresh")
                    .allowsHitTesting(false)
            } else if let error = state.error {
                VStack(spacing: 8) {
                    Text(app.offline ? "Offline" : "Couldn’t load").font(.headline)
                    Text(error).font(.footnote).multilineTextAlignment(.center)
                    Button("Retry") { Task { await retry() } }.buttonStyle(.bordered)
                        .accessibilityLabel("Retry loading")
                        .accessibilityIdentifier("loading.retry")
                }.padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .accessibilityElement(children: .contain)
            } else if empty {
                ContentUnavailableView(title, systemImage: app.offline ? "wifi.slash" : "tray", description: Text(detail))
            }
            Spacer()
        }.padding()
    }
}
