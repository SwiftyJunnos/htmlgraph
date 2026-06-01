import Foundation

public struct VaultIndexCache {
    public let rootURL: URL

    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public func save(_ index: VaultIndex) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let data = try Self.encoder.encode(index)
        try data.write(to: fileURL(for: index.vaultId), options: [.atomic])
    }

    public func load(vaultId: String) throws -> VaultIndex? {
        let url = fileURL(for: vaultId)

        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(VaultIndex.self, from: data)
    }

    private func fileURL(for vaultId: String) -> URL {
        rootURL.appendingPathComponent(Self.cacheKey(for: vaultId)).appendingPathExtension("json")
    }

    private static func cacheKey(for vaultId: String) -> String {
        Data(vaultId.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601String(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
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

    private static func iso8601String(from date: Date) -> String {
        var wholeSeconds = floor(date.timeIntervalSinceReferenceDate)
        let fraction = date.timeIntervalSinceReferenceDate - wholeSeconds
        var fractionalUnits = (fraction * fractionalScale).rounded()

        if fractionalUnits >= fractionalScale {
            wholeSeconds += 1
            fractionalUnits = 0
        }

        let wholeSecondString = wholeSecondFormatter()
            .string(from: Date(timeIntervalSinceReferenceDate: wholeSeconds))
        let fractionalString = String(format: "%017.0f", fractionalUnits)

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

        guard !fractionString.isEmpty,
              fractionString.allSatisfy(\.isNumber),
              let wholeSecondDate = wholeSecondFormatter().date(from: wholeSecondString),
              let fraction = Double("0.\(fractionString)") else {
            return nil
        }

        return Date(timeInterval: fraction, since: wholeSecondDate)
    }

    private static func wholeSecondFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }

    private static let fractionalScale = 100_000_000_000_000_000.0
}
