import AVFoundation
import UniformTypeIdentifiers

/// AVFoundation delegates custom-scheme ranges here. Bounded range reads use the same
/// no-redirect transport as the API, never AVURLAsset's automatically forwarded headers.
@MainActor final class MediaLoader: NSObject, AVAssetResourceLoaderDelegate {
    let asset: AVURLAsset
    private let url: URL, token: String, epoch: String
    private let source: Abs
    private let playback: UUID?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(url: URL, token: String, epoch: String, source: Abs = app, playback: UUID? = nil) {
        self.source = source; self.playback = playback
        self.url = url; self.token = token; self.epoch = epoch
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.scheme = "abs-media"
        asset = AVURLAsset(url: parts.url!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: .main)
    }

    func cancel() { tasks.values.forEach { $0.cancel() }; tasks = [:] }

    nonisolated func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        MainActor.assumeIsolated { start(request) }
        return true
    }

    nonisolated func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        MainActor.assumeIsolated { tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel() }
    }

    private func check() throws {
        try Task.checkCancellation()
        if let playback { guard playback == source.playbackGeneration else { throw CancellationError() } }
        else { try source.checkSession(epoch) }
    }

    private func start(_ loading: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(loading)
        tasks[id] = Task {
            defer { tasks[id] = nil }
            do {
                try check()
                let requested = loading.dataRequest
                var offset = requested.map { max($0.requestedOffset, $0.currentOffset) } ?? 0
                let end = requested.map { $0.requestedOffset + Int64($0.requestedLength) } ?? 2
                repeat {
                    try check()
                    let upper = requested?.requestsAllDataToEndOfResource == true ? offset + 262143 : min(offset + 262143, max(offset, end - 1))
                    var request = URLRequest(url: url)
                    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                    request.setValue("bytes=\(offset)-\(upper)", forHTTPHeaderField: "Range")
                    let (data, response) = try await source.network.data(for: request)
                    try check()
                    guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
                        throw Msg(errorDescription: "Server must support byte-range streaming")
                    }
                    guard let range = http.value(forHTTPHeaderField: "Content-Range"),
                          let total = Int64(range.split(separator: "/").last ?? ""),
                          range.hasPrefix("bytes \(offset)-"), !data.isEmpty, data.count <= Int(upper - offset + 1) else {
                        throw Msg(errorDescription: "Invalid audio range")
                    }
                    if let info = loading.contentInformationRequest {
                        info.contentType = http.mimeType.flatMap { UTType(mimeType: $0)?.identifier }
                        info.contentLength = total
                        info.isByteRangeAccessSupported = true
                    }
                    requested?.respond(with: data)
                    offset += Int64(data.count)
                    if offset >= total { break }
                } while requested != nil && (requested!.requestsAllDataToEndOfResource || offset < end)
                loading.finishLoading()
            } catch { loading.finishLoading(with: error) }
        }
    }
}
