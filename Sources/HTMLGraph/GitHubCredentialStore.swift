import Foundation
import HTMLGraphCore
import Security

protocol GitHubCredentialStoring {
    func load(clientID: String) -> GitHubOAuthToken?
    func save(_ token: GitHubOAuthToken, clientID: String) throws
    func delete(clientID: String)
}

final class GitHubCredentialStore: GitHubCredentialStoring {
    private let service = "com.junnos.htmlgraph.github"

    func load(clientID: String) -> GitHubOAuthToken? {
        var query = baseQuery(clientID: clientID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(GitHubOAuthToken.self, from: data)
    }

    func save(_ token: GitHubOAuthToken, clientID: String) throws {
        let data = try JSONEncoder().encode(token)
        delete(clientID: clientID)

        var query = baseQuery(clientID: clientID)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(clientID: String) {
        SecItemDelete(baseQuery(clientID: clientID) as CFDictionary)
    }

    private func baseQuery(clientID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "oauth:\(clientID.trimmingCharacters(in: .whitespacesAndNewlines))"
        ]
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "Keychain error \(status)."
    }
}
