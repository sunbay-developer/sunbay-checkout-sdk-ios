#if canImport(UIKit)
    import UIKit

    /// Loads card-brand logos from the URLs the session provides, with an in-memory cache only.
    ///
    /// Only the logo URL is requested: no card data, cookies or credentials are sent, and nothing is
    /// written to disk. Failures are silent (`completion(nil)`); the caller skips that brand.
    @MainActor
    final class CardBrandLogoLoader {
        typealias Fetch = @Sendable (URL) async throws -> Data

        private let fetch: Fetch
        private let cache = NSCache<NSURL, UIImage>()
        private var waiting: [URL: [(UIImage?) -> Void]] = [:]

        /// - Parameter fetch: Downloads the bytes for a logo URL (replaceable in tests).
        init(fetch: @escaping Fetch = CardBrandLogoLoader.defaultFetch) {
            self.fetch = fetch
        }

        /// Returns the logo for `url` (cached, or fetched once for concurrent requests); the completion
        /// always runs on the main actor, with `nil` on any failure.
        func image(for url: URL, completion: @escaping (UIImage?) -> Void) {
            if let cached = cache.object(forKey: url as NSURL) {
                completion(cached)
                return
            }
            if waiting[url] != nil {
                waiting[url]?.append(completion)
                return
            }
            waiting[url] = [completion]
            let fetch = self.fetch
            Task { [weak self] in
                let image: UIImage?
                if let data = try? await fetch(url) {
                    image = UIImage(data: data, scale: UIScreen.main.scale)
                } else {
                    image = nil
                }
                self?.finish(url: url, image: image)
            }
        }

        private func finish(url: URL, image: UIImage?) {
            if let image { cache.setObject(image, forKey: url as NSURL) }
            let completions = waiting.removeValue(forKey: url) ?? []
            for completion in completions { completion(image) }
        }

        /// Ephemeral session (no cookies, credentials or disk cache) with a short timeout.
        static let defaultFetch: Fetch = { url in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            let (data, response) = try await URLSession(configuration: configuration).data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }
#endif
