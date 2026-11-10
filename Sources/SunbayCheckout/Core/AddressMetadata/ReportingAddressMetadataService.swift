import Foundation

/// Decorator that reports every failure of the wrapped service as a non-terminal diagnostic and
/// rethrows it unchanged.
struct ReportingAddressMetadataService: AddressMetadataService {
    private let inner: any AddressMetadataService
    private let reporter: DiagnosticsReporter

    init(wrapping inner: any AddressMetadataService, reporter: DiagnosticsReporter) {
        self.inner = inner
        self.reporter = reporter
    }

    func countries(locale: String?) async throws -> AddressCountryList {
        do {
            return try await inner.countries(locale: locale)
        } catch {
            report(error)
            throw error
        }
    }

    func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
        do {
            return try await inner.countryConfig(countryCode: countryCode, locale: locale)
        } catch {
            report(error)
            throw error
        }
    }

    private func report(_ error: Error) {
        let mapped = (error as? CheckoutError)
            ?? CheckoutError(
                code: "ADDRESS_METADATA_FAILED",
                message: "Address metadata could not be loaded.",
                category: .network,
                traceId: nil)
        reporter.error(mapped, sessionId: nil)
    }
}
