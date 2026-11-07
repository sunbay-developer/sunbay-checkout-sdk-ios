import Foundation

/// The card-brand rules document (see `docs/card-rules-contract.md`).
///
/// UI-agnostic and `Sendable`. Rules are **hints** for formatting, auto-advance and display; they never
/// restrict what a user may type beyond the universal limits (19 digits, 4-digit security code).
struct CardRuleSet: Equatable, Sendable {
    /// A prefix matcher: a single prefix (`lower == upper`) or an inclusive range of prefixes.
    struct Pattern: Equatable, Sendable {
        /// Lower bound, as digits (also the prefix itself for a single prefix).
        let lower: String
        /// Upper bound, as digits.
        let upper: String
    }

    /// The security-code convention of a brand.
    struct CVV: Equatable, Sendable {
        /// The brand's own name for the code (CVV, CVC, CID, CVN2…).
        let name: String
        /// Allowed code lengths.
        let sizes: [Int]
    }

    /// One card brand's rules.
    struct Brand: Equatable, Sendable {
        let scheme: String
        let displayName: String
        let patterns: [Pattern]
        let lengths: [Int]
        let groups: [Int]
        let groupsByLength: [Int: [Int]]
        let cvv: CVV
        let autoAdvanceLength: Int?
    }

    /// The rules used when no brand matches.
    struct Generic: Equatable, Sendable {
        let groups: [Int]
        let minLength: Int
        let maxLength: Int
        let cvv: CVV
    }

    /// The only schema this build understands.
    static let supportedSchemaVersion = 1
    /// Documents larger than this are discarded.
    static let maxDocumentBytes = 256 * 1024

    let schemaVersion: Int
    let version: String
    let generic: Generic
    let brands: [Brand]

    // MARK: - Resolution

    /// The effective rules for a scheme (case-insensitive), or the generic rules when unknown / nil.
    func rules(forScheme scheme: String?) -> CardRules {
        guard let key = scheme?.lowercased(), let brand = brands.first(where: { $0.scheme == key }) else {
            return CardRules(
                scheme: nil, displayName: nil, groups: generic.groups, groupsByLength: [:],
                autoAdvanceLength: nil, cvvName: generic.cvv.name, cvvSizes: generic.cvv.sizes)
        }
        return CardRules(
            scheme: brand.scheme, displayName: brand.displayName, groups: brand.groups,
            groupsByLength: brand.groupsByLength, autoAdvanceLength: brand.autoAdvanceLength,
            cvvName: brand.cvv.name, cvvSizes: brand.cvv.sizes)
    }

    /// Guesses the scheme from the digits typed so far using the brands' prefix patterns.
    ///
    /// 1. The brand with a *full* match of the longest pattern wins (ties: earlier in the document).
    /// 2. Otherwise a single brand with a *partial* match wins.
    /// 3. Otherwise `nil` (use generic rules).
    func detectScheme(digits: String) -> String? {
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) else { return nil }
        var bestFull: (length: Int, index: Int)?
        var partial = Set<Int>()
        for (index, brand) in brands.enumerated() {
            for pattern in brand.patterns {
                switch pattern.match(digits) {
                case .full(let length):
                    if bestFull == nil || length > bestFull!.length { bestFull = (length, index) }
                case .partial: partial.insert(index)
                case .none: break
                }
            }
        }
        if let bestFull { return brands[bestFull.index].scheme }
        if partial.count == 1, let only = partial.first { return brands[only].scheme }
        return nil
    }
}

extension CardRuleSet.Pattern {
    enum Match: Equatable {
        case none
        case partial
        case full(length: Int)
    }

    /// Matches the typed digits against this pattern (contract §2.1).
    func match(_ typed: String) -> Match {
        let length = lower.count
        let n = min(length, typed.count)
        guard n > 0, let t = Int(typed.prefix(n)), let lo = Int(lower.prefix(n)), let hi = Int(upper.prefix(n)),
            lo <= t, t <= hi
        else { return .none }
        return typed.count >= length ? .full(length: length) : .partial
    }
}

// MARK: - Effective rules for one card

/// The rules in effect for the card currently being typed (a brand's rules or the generic ones).
struct CardRules: Equatable, Sendable {
    /// The scheme these rules belong to, or `nil` for generic.
    let scheme: String?
    let displayName: String?
    let groups: [Int]
    let groupsByLength: [Int: [Int]]
    let autoAdvanceLength: Int?
    let cvvName: String
    let cvvSizes: [Int]

    /// Generic rules (no brand known): groups of four, security code of 3 or 4 digits.
    static let generic = CardRules(
        scheme: nil, displayName: nil, groups: [4, 4, 4, 4], groupsByLength: [:], autoAdvanceLength: nil,
        cvvName: "CVC", cvvSizes: [3, 4])

    /// Group sizes for a number of `count` digits: the `groupsByLength` entry with the largest key not
    /// above `count`, else `groups`. Digits beyond the sum of the sizes are grouped by four.
    func groupSizes(forDigitCount count: Int) -> [Int] {
        if let key = groupsByLength.keys.filter({ $0 <= count }).max(), let sizes = groupsByLength[key] {
            return sizes
        }
        return groups
    }

    /// A placeholder example for the security-code field (`123` / `1234`).
    var cvvPlaceholder: String { (cvvSizes.max() ?? 3) >= 4 ? "1234" : "123" }
}

// MARK: - Decoding and validation

extension CardRuleSet {
    /// Parses and validates a rules document. Returns `nil` for anything that is not a well-formed,
    /// in-bounds document of a supported schema, so callers keep their previous rules.
    static func parse(_ data: Data) -> CardRuleSet? {
        guard data.count <= maxDocumentBytes,
            let raw = try? JSONDecoder().decode(RawDocument.self, from: data),
            raw.schemaVersion == supportedSchemaVersion,
            raw.brands.count <= 64,
            Self.valid(generic: raw.generic)
        else { return nil }

        var brands: [Brand] = []
        for brand in raw.brands {
            guard let converted = brand.converted() else { return nil }
            brands.append(converted)
        }
        return CardRuleSet(
            schemaVersion: raw.schemaVersion, version: raw.version,
            generic: Generic(
                groups: raw.generic.groups, minLength: raw.generic.minLength, maxLength: raw.generic.maxLength,
                cvv: CVV(name: raw.generic.cvv.name, sizes: raw.generic.cvv.sizes)),
            brands: brands)
    }

    private static func valid(generic: RawGeneric) -> Bool {
        validGroups(generic.groups) && (12...19).contains(generic.minLength)
            && (12...19).contains(generic.maxLength) && generic.minLength <= generic.maxLength
            && validSizes(generic.cvv.sizes)
    }

    fileprivate static func validGroups(_ groups: [Int]) -> Bool {
        !groups.isEmpty && groups.allSatisfy { (1...19).contains($0) } && groups.reduce(0, +) <= 19
    }

    fileprivate static func validSizes(_ sizes: [Int]) -> Bool {
        !sizes.isEmpty && sizes.allSatisfy { $0 == 3 || $0 == 4 }
    }

    // MARK: Wire types

    fileprivate struct RawDocument: Decodable {
        let schemaVersion: Int
        let version: String
        let generic: RawGeneric
        let brands: [RawBrand]
    }

    fileprivate struct RawGeneric: Decodable {
        let groups: [Int]
        let minLength: Int
        let maxLength: Int
        let cvv: RawCVV
    }

    fileprivate struct RawCVV: Decodable {
        let name: String
        let sizes: [Int]
    }

    fileprivate struct RawBrand: Decodable {
        let scheme: String
        let displayName: String
        let patterns: [RawPattern]
        let lengths: [Int]
        let groups: [Int]
        let groupsByLength: [String: [Int]]?
        let cvv: RawCVV
        let autoAdvanceLength: Int?

        func converted() -> Brand? {
            guard !scheme.isEmpty, !patterns.isEmpty, lengths.allSatisfy({ (12...19).contains($0) }),
                CardRuleSet.validGroups(groups), CardRuleSet.validSizes(cvv.sizes),
                autoAdvanceLength.map({ (12...19).contains($0) }) ?? true
            else { return nil }
            var byLength: [Int: [Int]] = [:]
            for (key, sizes) in groupsByLength ?? [:] {
                guard let length = Int(key), CardRuleSet.validGroups(sizes) else { return nil }
                byLength[length] = sizes
            }
            return Brand(
                scheme: scheme.lowercased(), displayName: displayName, patterns: patterns.map(\.value),
                lengths: lengths, groups: groups, groupsByLength: byLength,
                cvv: CVV(name: cvv.name, sizes: cvv.sizes), autoAdvanceLength: autoAdvanceLength)
        }
    }

    /// A pattern is a number (a prefix) or a two-number array (an inclusive range).
    fileprivate struct RawPattern: Decodable {
        let value: Pattern

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let prefix = try? container.decode(Int.self), prefix > 0 {
                value = Pattern(lower: String(prefix), upper: String(prefix))
            } else {
                let range = try container.decode([Int].self)
                guard range.count == 2, range[0] > 0, range[1] >= range[0],
                    String(range[0]).count == String(range[1]).count
                else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad pattern")
                }
                value = Pattern(lower: String(range[0]), upper: String(range[1]))
            }
        }
    }
}
