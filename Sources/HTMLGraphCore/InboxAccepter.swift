import Foundation

public enum InboxAcceptanceError: Error, Equatable, Sendable {
    case sourceOutsideInbox
    case destinationOutsideVault
    case destinationInsideInbox
    case destinationAlreadyExists
}

public struct InboxAccepter {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    public func accept(_ item: InboxItem, to destinationURL: URL, vaultURL: URL) throws -> URL {
        let sourceURL = URL(fileURLWithPath: item.absolutePath)
        let standardizedVaultURL = vaultURL.standardizedFileURL
        let standardizedSourceURL = sourceURL.standardizedFileURL
        let standardizedDestinationURL = destinationURL.standardizedFileURL

        guard isInsideInbox(standardizedSourceURL, vaultURL: standardizedVaultURL) else {
            throw InboxAcceptanceError.sourceOutsideInbox
        }

        guard isInsideVault(standardizedDestinationURL, vaultURL: standardizedVaultURL) else {
            throw InboxAcceptanceError.destinationOutsideVault
        }

        guard !isInsideInbox(standardizedDestinationURL, vaultURL: standardizedVaultURL) else {
            throw InboxAcceptanceError.destinationInsideInbox
        }

        guard !fileManager.fileExists(atPath: standardizedDestinationURL.path) else {
            throw InboxAcceptanceError.destinationAlreadyExists
        }

        try fileManager.createDirectory(
            at: standardizedDestinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: standardizedSourceURL, to: standardizedDestinationURL)
        return standardizedDestinationURL
    }

    private func isInsideInbox(_ url: URL, vaultURL: URL) -> Bool {
        let inboxURL = vaultURL.appendingPathComponent(InboxScanner.inboxDirectoryName, isDirectory: true)
        return isLocated(url, inside: inboxURL)
    }

    private func isInsideVault(_ url: URL, vaultURL: URL) -> Bool {
        isLocated(url, inside: vaultURL)
    }

    private func isLocated(_ url: URL, inside directoryURL: URL) -> Bool {
        let itemComponents = url.standardizedFileURL.pathComponents
        let directoryComponents = directoryURL.standardizedFileURL.pathComponents

        guard itemComponents.count >= directoryComponents.count else {
            return false
        }

        return zip(directoryComponents, itemComponents).allSatisfy { $0 == $1 }
    }
}
