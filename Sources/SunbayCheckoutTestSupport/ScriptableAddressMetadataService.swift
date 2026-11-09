// SunbayCheckoutTestSupport: TEST/EXAMPLE SCAFFOLDING ONLY.
//
// This module provides scriptable service doubles and demo fixtures used by the test targets
// (the Example app uses only DevSessionClient). It is NOT a stable public API and MUST NOT be used in production
// integrations. Its surface may change without a semantic-version guarantee.

import Foundation

import SunbayCheckout

/// Scriptable, public-API-only double for `AddressMetadataService`.
///
/// Used by the test targets. Mirrors the scripting style of
/// `ScriptableCofService` / `ScriptablePaymentService`: scripts the returned country list and the
/// per-country config (by country code), optionally throws a scripted error, and records call
/// counts plus the most recent locale (useful for the full-mode locale-refresh story — asserting
/// that a locale change re-queries metadata). Mutable state is guarded with `NSLock` to satisfy
/// `Sendable`.
///
/// Foundation-only: it is a Core-contract double, so it imports no UIKit (consistent with the
/// address-metadata layer being UI-agnostic, AGENTS.md §2.6).
public final class ScriptableAddressMetadataService: AddressMetadataService, @unchecked Sendable {
    private let lock = NSLock()

    // MARK: - Scripted inputs

    private var _countries: AddressCountryList = AddressCountryList(countries: [], detectedCountry: nil)
    private var _configs: [String: AddressCountryConfig] = [:]
    private var _countriesError: Error?
    private var _configError: Error?

    // MARK: - Observed outputs

    private var _countriesCallCount = 0
    private var _countryConfigCallCount = 0
    private var _lastCountriesLocale: String?
    private var _lastConfigLocale: String?
    private var _lastConfigCountryCode: String?

    public var countriesCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _countriesCallCount
    }

    public var countryConfigCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _countryConfigCallCount
    }

    public var lastCountriesLocale: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastCountriesLocale
    }

    public var lastConfigLocale: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastConfigLocale
    }

    public var lastConfigCountryCode: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastConfigCountryCode
    }

    public init() {}

    // MARK: - Scripting API (called from the test / demo thread)

    /// Scripts the country list returned by `countries(locale:)`.
    public func stubCountries(_ list: AddressCountryList) {
        lock.lock(); defer { lock.unlock() }
        _countries = list
    }

    /// Scripts the config returned by `countryConfig(countryCode:locale:)` for a given country code.
    public func stubCountryConfig(_ config: AddressCountryConfig, forCountryCode countryCode: String) {
        lock.lock(); defer { lock.unlock() }
        _configs[countryCode.uppercased()] = config
    }

    /// Scripts an error thrown by `countries(locale:)`.
    public func stubCountriesError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _countriesError = error
    }

    /// Scripts an error thrown by `countryConfig(countryCode:locale:)`.
    public func stubCountryConfigError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _configError = error
    }

    // MARK: - AddressMetadataService

    public func countries(locale: String?) async throws -> AddressCountryList {
        let (error, list): (Error?, AddressCountryList) = {
            lock.lock(); defer { lock.unlock() }
            _countriesCallCount += 1
            _lastCountriesLocale = locale
            return (_countriesError, _countries)
        }()
        if let error { throw error }
        return list
    }

    public func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
        let (error, config): (Error?, AddressCountryConfig?) = {
            lock.lock(); defer { lock.unlock() }
            _countryConfigCallCount += 1
            _lastConfigLocale = locale
            _lastConfigCountryCode = countryCode
            return (_configError, _configs[countryCode.uppercased()])
        }()
        if let error { throw error }
        guard let config else {
            // Fail-soft: an unscripted country yields a minimal empty-layout config rather than a
            // throw, matching the SDK's own EmptyAddressMetadataService behavior.
            return AddressCountryConfig(code: countryCode, fields: [:], layout: [], subdivisions: [])
        }
        return config
    }
}

// MARK: - Demo / fixture convenience

extension ScriptableAddressMetadataService {
    /// Builds a small, realistic default service (US + CA countries, a US config and a CA config)
    /// so the demo's full-mode address form renders something concrete without a real backend.
    ///
    /// The US config lays out `[[.country], [.line1], [.city, .state, .postalCode]]` with a couple
    /// of subdivisions; the CA config mirrors it with provinces. Labels/placeholders are already
    /// localized by a real backend, so this fixture ships English copy (zh-CN labels can be scripted
    /// separately to simulate a localized backend).
    public static func demoDefault() -> ScriptableAddressMetadataService {
        let service = ScriptableAddressMetadataService()
        service.stubCountries(
            AddressCountryList(
                countries: [
                    AddressCountry(code: "US", name: "United States"),
                    AddressCountry(code: "CA", name: "Canada"),
                ],
                detectedCountry: "US"
            )
        )
        service.stubCountryConfig(usConfig(), forCountryCode: "US")
        service.stubCountryConfig(caConfig(), forCountryCode: "CA")
        return service
    }

    /// A realistic US address-form config: country / line1 / (city · state · postal) with two states.
    public static func usConfig() -> AddressCountryConfig {
        AddressCountryConfig(
            code: "US",
            fields: [
                .country: AddressFieldConfig(
                    type: .country, required: true, pattern: nil,
                    label: "Country", placeholder: "Country"),
                .line1: AddressFieldConfig(
                    type: .line1, required: true, pattern: nil,
                    label: "Address", placeholder: "Street address"),
                .city: AddressFieldConfig(
                    type: .city, required: true, pattern: nil,
                    label: "City", placeholder: "City"),
                .state: AddressFieldConfig(
                    type: .state, required: true, pattern: nil,
                    label: "State", placeholder: "State"),
                .postalCode: AddressFieldConfig(
                    type: .postalCode, required: true, pattern: "^[0-9]{5}(-[0-9]{4})?$",
                    label: "ZIP", placeholder: "ZIP code"),
            ],
            layout: [[.country], [.line1], [.city, .state, .postalCode]],
            subdivisions: [
                AddressSubdivision(code: "CA", name: "California"),
                AddressSubdivision(code: "NY", name: "New York"),
            ]
        )
    }

    /// A realistic CA address-form config: country / line1 / (city · province · postal) with provinces.
    public static func caConfig() -> AddressCountryConfig {
        AddressCountryConfig(
            code: "CA",
            fields: [
                .country: AddressFieldConfig(
                    type: .country, required: true, pattern: nil,
                    label: "Country", placeholder: "Country"),
                .line1: AddressFieldConfig(
                    type: .line1, required: true, pattern: nil,
                    label: "Address", placeholder: "Street address"),
                .city: AddressFieldConfig(
                    type: .city, required: true, pattern: nil,
                    label: "City", placeholder: "City"),
                .state: AddressFieldConfig(
                    type: .state, required: true, pattern: nil,
                    label: "Province", placeholder: "Province"),
                .postalCode: AddressFieldConfig(
                    type: .postalCode, required: true, pattern: nil,
                    label: "Postal code", placeholder: "Postal code"),
            ],
            layout: [[.country], [.line1], [.city, .state, .postalCode]],
            subdivisions: [
                AddressSubdivision(code: "ON", name: "Ontario"),
                AddressSubdivision(code: "BC", name: "British Columbia"),
            ]
        )
    }
}
