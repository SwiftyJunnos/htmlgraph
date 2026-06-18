import Foundation
import HTMLGraphCore
import Security

protocol GitHubCredentialStoring {
    func load(clientID: String) throws -> GitHubOAuthToken?
    func save(_ token: GitHubOAuthToken, clientID: String) throws
    func delete(clientID: String)
}

final class GitHubCredentialStore: GitHubCredentialStoring {
    private let service = "com.junnos.htmlgraph.github"

    func load(clientID: String) throws -> GitHubOAuthToken? {
        var query = baseQuery(clientID: clientID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            return nil
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data else { throw KeychainError(status: errSecInternalError) }
        do {
            return try JSONDecoder().decode(GitHubOAuthToken.self, from: data)
        } catch {
            throw KeychainError(status: errSecDecode)
        }
    }

    func save(_ token: GitHubOAuthToken, clientID: String) throws {
        let data = try JSONEncoder().encode(token)
        let query = baseQuery(clientID: clientID)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        guard updateStatus == errSecItemNotFound else {
            guard updateStatus == errSecSuccess else { throw KeychainError(status: updateStatus) }
            return
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
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
