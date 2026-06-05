import Foundation

/// Shared JSON coding configuration for `VaultIndex` artifacts.
///
/// Two encoders share the same structural settings (pretty-printed, sorted keys)
/// but differ in how dates are written:
/// - ``encoder`` writes dates with full 17-fractional-digit precision so the
///   internal restore cache (`VaultIndexCache`) round-trips a `Date` exactly.
/// - ``interoperableEncoder`` writes RFC 3339 millisecond timestamps for the
///   AI-facing `graph.json` sidecar (`VaultIndexExporter`), because the 17-digit
///   form is rejected by most standard ISO 8601 parsers (JavaScript, Python, Go,
///   Foundation).
///
/// ``decoder`` reads either form back (it accepts 1–17 fractional digits), so it
/// decodes both the cache file and the exported sidecar.
enum VaultIndexJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601String(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            guard let date = date(fromISO8601String: dateString) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected ISO8601 UTC date with fractional seconds."
                )
            }

            return date
        }
        return decoder
    }

    /// Encoder for the AI-facing `graph.json` export. Same structure as ``encoder``
    /// but dates are RFC 3339 with millisecond precision (e.g.
    /// `2026-06-04T02:52:26.827Z`) so external consumers can parse them with
    /// standard ISO 8601 libraries. Sub-millisecond precision is dropped, which is
    /// irrelevant for index/modification timestamps.
    static var interoperableEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(rfc3339MillisecondsFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var rfc3339MillisecondsFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    private static func iso8601String(from date: Date) -> String {
        var wholeUnixSeconds = floor(date.timeIntervalSince1970)
        var wholeSecondDate = Date(timeIntervalSince1970: wholeUnixSeconds)
        let fraction = date.timeIntervalSince(wholeSecondDate)
        var fractionalUnits = Int64((fraction * Double(fractionalScale)).rounded())

        if fractionalUnits >= fractionalScale {
            wholeUnixSeconds += 1
            wholeSecondDate = Date(timeIntervalSince1970: wholeUnixSeconds)
            fractionalUnits = 0
        }

        let wholeSecondString = wholeSecondString(from: wholeSecondDate)
        let fractionalString = String(format: "%017lld", fractionalUnits)

        return "\(wholeSecondString).\(fractionalString)Z"
    }

    private static func date(fromISO8601String string: String) -> Date? {
        guard string.hasSuffix("Z"),
              let separator = string.firstIndex(of: ".") else {
            return nil
        }

        let wholeSecondString = String(string[..<separator])
        let fractionStart = string.index(after: separator)
        let fractionEnd = string.index(before: string.endIndex)
        let fractionString = String(string[fractionStart..<fractionEnd])

        guard (1...fractionalDigits).contains(fractionString.count),
              fractionString.allSatisfy(\.isNumber),
              let wholeSecondDate = date(fromWholeSecondString: wholeSecondString) else {
            return nil
        }

        let refWholeSeconds = Int64(wholeSecondDate.timeIntervalSinceReferenceDate)
        let paddedFractionString = fractionString.padding(
            toLength: fractionalDigits,
            withPad: "0",
            startingAt: 0
        )

        guard let fractionalUnits = Int64(paddedFractionString),
              let referenceInterval = referenceInterval(
                wholeSeconds: refWholeSeconds,
                fractionalUnits: fractionalUnits
              ) else {
            return nil
        }

        return Date(timeIntervalSinceReferenceDate: referenceInterval)
    }

    private static func wholeSecondString(from date: Date) -> String {
        let components = utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )

        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }

    private static func date(fromWholeSecondString string: String) -> Date? {
        guard string.count == 19,
              string[string.index(string.startIndex, offsetBy: 4)] == "-",
              string[string.index(string.startIndex, offsetBy: 7)] == "-",
              string[string.index(string.startIndex, offsetBy: 10)] == "T",
              string[string.index(string.startIndex, offsetBy: 13)] == ":",
              string[string.index(string.startIndex, offsetBy: 16)] == ":",
              let year = Int(string[offset: 0, length: 4]),
              let month = Int(string[offset: 5, length: 2]),
              let day = Int(string[offset: 8, length: 2]),
              let hour = Int(string[offset: 11, length: 2]),
              let minute = Int(string[offset: 14, length: 2]),
              let second = Int(string[offset: 17, length: 2]) else {
            return nil
        }

        var components = DateComponents()
        components.calendar = utcCalendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        return utcCalendar.date(from: components)
    }

    private static func referenceInterval(wholeSeconds: Int64, fractionalUnits: Int64) -> Double? {
        guard (0..<fractionalScale).contains(fractionalUnits) else {
            return nil
        }

        if fractionalUnits == 0 {
            return Double(wholeSeconds)
        }

        let paddedFractionString = String(format: "%017lld", fractionalUnits)

        if wholeSeconds >= 0 {
            return Double("\(wholeSeconds).\(paddedFractionString)")
        }

        let complementUnits = fractionalScale - fractionalUnits
        let complementString = String(format: "%017lld", complementUnits)

        return Double("-\(abs(wholeSeconds + 1)).\(complementString)")
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static let fractionalDigits = 17
    private static let fractionalScale: Int64 = 100_000_000_000_000_000
}

private extension String {
    subscript(offset offset: Int, length length: Int) -> String {
        let start = index(startIndex, offsetBy: offset)
        let end = index(start, offsetBy: length)
        return String(self[start..<end])
    }
}
