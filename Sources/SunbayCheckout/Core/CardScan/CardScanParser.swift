import Foundation

/// A card candidate extracted from one camera frame. Holds plaintext: never log or persist it.
struct ScannedCard: Sendable, Equatable {
    /// Digits-only PAN (Luhn valid, 13–19 digits).
    let pan: String
    /// Expiry month `"01"`–`"12"`, if one was found.
    let expiryMonth: String?
    /// Two-digit expiry year (`"28"`), if one was found.
    let expiryYear: String?
}

/// Extracts a PAN and expiry from the text lines that on-device OCR recognized on a card.
///
/// Pure and UI-agnostic. Input lines are treated as sensitive: nothing here logs or stores them.
enum CardScanParser {
    /// Parses recognized lines into a card candidate, or `nil` when no Luhn-valid PAN is present.
    ///
    /// - Parameters:
    ///   - lines: Recognized text lines for one frame.
    ///   - now: Reference date used to reject already-expired dates (injectable for tests).
    static func parse(lines: [String], now: Date = Date()) -> ScannedCard? {
        guard let pan = extractPAN(from: lines) else { return nil }
        let expiry = extractExpiry(from: lines, now: now)
        return ScannedCard(pan: pan, expiryMonth: expiry?.month, expiryYear: expiry?.year)
    }

    // MARK: - PAN

    /// Preferred PAN lengths when a digit run is longer than any single card number (the OCR run may
    /// swallow neighbouring digits): most common first.
    private static let preferredLengths = [16, 15, 19, 14, 18, 17, 13]

    static func extractPAN(from lines: [String]) -> String? {
        // Joining with spaces lets 4-digit groups that OCR split across lines re-assemble. Lines that
        // are mostly digits get look-alike letters (O/I/S/B…) mapped to digits first.
        let joined = lines.map(normalizeDigitLookalikes).joined(separator: " ")
        guard let regex = try? NSRegularExpression(pattern: #"\d(?:[ \-]?\d){12,}"#) else { return nil }
        let ns = joined as NSString
        for match in regex.matches(in: joined, range: NSRange(location: 0, length: ns.length)) {
            let digits = ns.substring(with: match.range).filter(\.isNumber)
            if let pan = firstValidPAN(in: digits) { return pan }
        }
        return nil
    }

    /// OCR often reads embossed digits as look-alike letters. In a line that is clearly a number
    /// (8+ real digits), map them back; other lines (names, bank text) are left untouched.
    static func normalizeDigitLookalikes(_ line: String) -> String {
        guard line.filter(\.isNumber).count >= 8 else { return line }
        let map: [Character: Character] = [
            "O": "0", "o": "0", "D": "0", "Q": "0", "I": "1", "l": "1", "|": "1", "i": "1",
            "Z": "2", "z": "2", "S": "5", "s": "5", "G": "6", "b": "6", "B": "8",
        ]
        return String(line.map { map[$0] ?? $0 })
    }

    private static func firstValidPAN(in digits: String) -> String? {
        guard digits.first != "0" else { return nil }
        // A run that fits in a PAN must be valid as a whole: truncating a short run would turn a
        // misread number into a different, accidentally Luhn-valid one. Only an over-long run (OCR
        // swallowed neighbouring digits) is trimmed.
        if digits.count <= 19 {
            return isPlausible(digits) ? digits : nil
        }
        for length in preferredLengths where digits.count >= length {
            let candidate = String(digits.prefix(length))
            if isPlausible(candidate) { return candidate }
        }
        return nil
    }

    /// Luhn-valid and a length that fits the card brand's prefix (Amex 15, Diners 14–19, others 16–19).
    static func isPlausiblePAN(_ digits: String) -> Bool { isPlausible(digits) }

    /// Digit runs (13–19 digits, after look-alike normalisation) that may still contain misreads.
    static func digitRuns(from lines: [String]) -> [String] {
        let joined = lines.map(normalizeDigitLookalikes).joined(separator: " ")
        guard let regex = try? NSRegularExpression(pattern: #"\d(?:[ \-]?\d){12,}"#) else { return [] }
        let ns = joined as NSString
        return regex.matches(in: joined, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).filter(\.isNumber) }
            .filter { (13...19).contains($0.count) }
    }

    private static func isPlausible(_ digits: String) -> Bool {
        guard (13...19).contains(digits.count), luhnValid(digits) else { return false }
        let prefix2 = String(digits.prefix(2))
        switch prefix2 {
        case "34", "37": return digits.count == 15
        case "30", "36", "38", "39": return (14...19).contains(digits.count)
        default: return digits.count >= 16
        }
    }

    /// Standard Luhn checksum.
    static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        var double = false
        for character in digits.reversed() {
            guard var value = character.wholeNumberValue else { return false }
            if double {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
            double.toggle()
        }
        return sum % 10 == 0
    }

    // MARK: - Expiry

    /// Finds the latest non-expired `MM/YY` or `MM/YYYY` date (cards may also print a "valid from").
    static func extractExpiry(from lines: [String], now: Date) -> (month: String, year: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)(0[1-9]|1[0-2])\s*[/\-]\s*(\d{4}|\d{2})(?!\d)"#)
        else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let nowYear = calendar.component(.year, from: now)
        let nowMonth = calendar.component(.month, from: now)

        var best: (month: Int, year: Int)?
        for line in lines {
            let ns = line as NSString
            for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges == 3,
                    let month = Int(ns.substring(with: match.range(at: 1)))
                else { continue }
                let yearText = ns.substring(with: match.range(at: 2))
                guard var year = Int(yearText) else { continue }
                if yearText.count == 2 { year += 2000 }
                // Reject expired dates and implausibly far ones (OCR noise).
                guard year > nowYear || (year == nowYear && month >= nowMonth), year <= nowYear + 20 else {
                    continue
                }
                if best == nil || (year, month) > (best!.year, best!.month) {
                    best = (month, year)
                }
            }
        }
        guard let best else { return nil }
        return (String(format: "%02d", best.month), String(format: "%02d", best.year % 100))
    }
}

/// Accepts a scan only once the same PAN was read in several frames, then waits briefly for an expiry.
///
/// Guards against single-frame OCR misreads. Time is passed in so it is deterministic and testable.
struct CardScanStabilizer {
    private let requiredPANHits: Int
    private let expiryGrace: TimeInterval

    private var panCounts: [String: Int] = [:]
    private var lockedPAN: String?
    private var lockedAt: TimeInterval?
    private var expiry: (month: String, year: String)?

    /// - Parameters:
    ///   - requiredPANHits: Frames in which the same PAN must be read before it is trusted.
    ///   - expiryGrace: Seconds to keep looking for an expiry after the PAN is trusted.
    init(requiredPANHits: Int = 2, expiryGrace: TimeInterval = 1.5) {
        self.requiredPANHits = requiredPANHits
        self.expiryGrace = expiryGrace
    }

    /// Feeds one frame's candidate. Returns the final card when scanning is complete, else `nil`.
    ///
    /// - Parameters:
    ///   - candidate: The parsed frame, or `nil` if nothing was found.
    ///   - time: A monotonic timestamp in seconds.
    mutating func ingest(_ candidate: ScannedCard?, at time: TimeInterval) -> ScannedCard? {
        if let candidate {
            if lockedPAN == nil {
                panCounts[candidate.pan, default: 0] += 1
                if panCounts[candidate.pan, default: 0] >= requiredPANHits {
                    lockedPAN = candidate.pan
                    lockedAt = time
                }
            }
            if candidate.pan == lockedPAN, let month = candidate.expiryMonth, let year = candidate.expiryYear {
                expiry = (month, year)
            }
        }
        guard let pan = lockedPAN, let lockedAt else { return nil }
        if expiry != nil || time - lockedAt >= expiryGrace {
            return ScannedCard(pan: pan, expiryMonth: expiry?.month, expiryYear: expiry?.year)
        }
        return nil
    }
}

/// Per-position majority vote over recent frames' digit runs.
///
/// OCR on embossed digits misreads a digit or two per frame, differently each time, so a fully valid
/// number rarely appears in one frame. Voting on each position across frames corrects those one-off
/// misreads; the voted number must still pass the Luhn / brand-length check before it is trusted.
struct CardScanDigitVoter {
    private let window: Int
    private let minSamples: Int
    private var samples: [Int: [String]] = [:]  // digit count -> recent runs of that length

    /// - Parameters:
    ///   - window: How many recent runs of each length to keep.
    ///   - minSamples: Runs of one length required before a vote is taken.
    init(window: Int = 12, minSamples: Int = 3) {
        self.window = window
        self.minSamples = minSamples
    }

    /// Adds this frame's candidate digit runs and returns a Luhn-valid voted PAN, if one emerges.
    mutating func ingest(lines: [String]) -> String? {
        for run in CardScanParser.digitRuns(from: lines) {
            var list = samples[run.count, default: []]
            list.append(run)
            if list.count > window { list.removeFirst(list.count - window) }
            samples[run.count] = list
        }
        for (length, list) in samples where list.count >= minSamples {
            var voted = ""
            for position in 0..<length {
                var counts: [Character: Int] = [:]
                for run in list { counts[run[run.index(run.startIndex, offsetBy: position)], default: 0] += 1 }
                guard let winner = counts.max(by: { $0.value < $1.value })?.key else { break }
                voted.append(winner)
            }
            if CardScanParser.isPlausiblePAN(voted) { return voted }
        }
        return nil
    }
}
