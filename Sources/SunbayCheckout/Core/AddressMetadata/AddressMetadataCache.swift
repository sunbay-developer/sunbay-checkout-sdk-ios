import Foundation

/// An actor that wraps any `AddressMetadataService` to cache responses and deduplicate concurrent
/// identical requests.
///
/// Corresponds to product-spec §7.3: values are keyed by `(resource, countryCode?, locale)`, so
/// each language is cached separately and stale-language data is never served. Within `ttl`, a
/// repeated request returns the cached value without hitting the wrapped service. Concurrent
/// identical in-flight requests share one underlying call (the in-flight `Task` is stored under the
/// same key and awaited by later callers).
///
/// - Note: Internal — constructed by the SDK around the host-injected service. UI-agnostic
///   (Foundation only).
actor AddressMetadataCache: AddressMetadataService {
    /// The cache key identifying a resource request.
    private enum Key: Hashable {
        case countries(locale: String?)
        case countryConfig(countryCode: String, locale: String?)
    }

    /// A cached value with the time it was stored (for TTL freshness checks).
    private struct Entry<Value: Sendable>: Sendable {
        let value: Value
        let storedAt: Date
    }

    private let wrapped: any AddressMetadataService
    private let ttl: TimeInterval

    private var countriesCache: [Key: Entry<AddressCountryList>] = [:]
    private var configCache: [Key: Entry<AddressCountryConfig>] = [:]

    private var countriesInFlight: [Key: Task<AddressCountryList, Error>] = [:]
    private var configInFlight: [Key: Task<AddressCountryConfig, Error>] = [:]

    /// Wraps a service with caching and in-flight deduplication.
    ///
    /// - Parameters:
    ///   - wrapping: The underlying service to call on a cache miss.
    ///   - ttl: How long a cached value stays fresh, in seconds. Defaults to one hour.
    init(wrapping: any AddressMetadataService, ttl: TimeInterval = 3600) {
        self.wrapped = wrapping
        self.ttl = ttl
    }

    func countries(locale: String?) async throws -> AddressCountryList {
        let key = Key.countries(locale: locale)

        if let entry = countriesCache[key], isFresh(entry.storedAt) {
            return entry.value
        }
        if let existing = countriesInFlight[key] {
            return try await existing.value
        }

        let service = wrapped
        let task = Task { try await service.countries(locale: locale) }
        countriesInFlight[key] = task
        defer { countriesInFlight[key] = nil }

        do {
            let value = try await task.value
            countriesCache[key] = Entry(value: value, storedAt: Date())
            return value
        } catch {
            throw error
        }
    }

    func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
        let key = Key.countryConfig(countryCode: countryCode, locale: locale)

        if let entry = configCache[key], isFresh(entry.storedAt) {
            return entry.value
        }
        if let existing = configInFlight[key] {
            return try await existing.value
        }

        let service = wrapped
        let task = Task { try await service.countryConfig(countryCode: countryCode, locale: locale) }
        configInFlight[key] = task
        defer { configInFlight[key] = nil }

        do {
            let value = try await task.value
            configCache[key] = Entry(value: value, storedAt: Date())
            return value
        } catch {
            throw error
        }
    }

    /// Whether a value stored at `storedAt` is still within the TTL window.
    private func isFresh(_ storedAt: Date) -> Bool {
        Date().timeIntervalSince(storedAt) < ttl
    }
}
