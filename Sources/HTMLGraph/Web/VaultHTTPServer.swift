import Foundation
import HTMLGraphCore
import Network

/// Pure request → response mapping for the loopback vault server. Kept free of
/// socket I/O so it can be unit-tested directly. It reads files from disk because
/// serving them with the right MIME type and byte ranges is the entire job.
struct VaultHTTPResponder {
    let vaultURL: URL
    let token: String

    struct Response: Equatable {
        var status: Int
        var reason: String
        var headers: [Header]
        var body: Data

        struct Header: Equatable {
            let name: String
            let value: String
            init(_ name: String, _ value: String) {
                self.name = name
                self.value = value
            }
        }

        func headerValue(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// File serving is policy-independent: `VaultSecurityPolicy.allows` for a file
    /// URL only checks vault-root containment, so a fixed Safe policy suffices.
    private static let containmentPolicy = VaultSecurityPolicy(mode: .safe, allowsNetworkAccess: false)

    func respond(method: String, target: String, rangeHeader: String?) -> Response {
        let upperMethod = method.uppercased()
        guard upperMethod == "GET" || upperMethod == "HEAD" else {
            return Self.status(405, "Method Not Allowed", extra: [.init("Allow", "GET, HEAD")])
        }

        guard let fileURL = Self.fileURL(forTarget: target, vaultURL: vaultURL, token: token) else {
            return Self.status(403, "Forbidden")
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return Self.status(404, "Not Found")
        }
        let resolvedURL = isDirectory.boolValue ? fileURL.appendingPathComponent("index.html") : fileURL

        var resolvedIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedURL.path, isDirectory: &resolvedIsDirectory),
              !resolvedIsDirectory.boolValue,
              let size = (try? fileManager.attributesOfItem(atPath: resolvedURL.path))?[.size] as? Int else {
            return Self.status(404, "Not Found")
        }

        let mime = VaultResourceSchemeHandler.mimeType(for: resolvedURL)
        let wantsBody = upperMethod == "GET"

        // Range request: serve only the requested slice via a seek, so scrubbing a
        // large <video>/<audio> never loads the whole file into memory.
        if let rangeHeader, rangeHeader.lowercased().hasPrefix("bytes=") {
            guard let range = Self.parseByteRange(rangeHeader, totalLength: size) else {
                return Response(
                    status: 416,
                    reason: "Range Not Satisfiable",
                    headers: [.init("Content-Range", "bytes */\(size)"), .init("Content-Length", "0")],
                    body: Data()
                )
            }
            let body: Data
            if wantsBody {
                // Don't fall back to an empty body while still advertising the range
                // length — a read failure must surface as 500, not a corrupt 206.
                guard let partial = Self.readFile(at: resolvedURL, range: range),
                      partial.count == range.count else {
                    return Self.status(500, "Internal Server Error")
                }
                body = partial
            } else {
                body = Data()
            }
            return Response(
                status: 206,
                reason: "Partial Content",
                headers: [
                    .init("Content-Type", mime),
                    .init("Accept-Ranges", "bytes"),
                    .init("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)"),
                    .init("Content-Length", String(range.count)),
                    .init("Cache-Control", "no-store"),
                ],
                body: body
            )
        }

        let body: Data
        if wantsBody {
            guard let full = try? Data(contentsOf: resolvedURL), full.count == size else {
                return Self.status(500, "Internal Server Error")
            }
            body = full
        } else {
            body = Data()
        }
        return Response(
            status: 200,
            reason: "OK",
            headers: [
                .init("Content-Type", mime),
                .init("Accept-Ranges", "bytes"),
                .init("Content-Length", String(size)),
                .init("Cache-Control", "no-store"),
            ],
            body: body
        )
    }

    /// Reads only `range` bytes from a file via a seek, avoiding loading the whole
    /// file for a partial-content response.
    private static func readFile(at url: URL, range: Range<Int>) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            return try handle.read(upToCount: range.count) ?? Data()
        } catch {
            return nil
        }
    }

    private static func status(_ status: Int, _ reason: String, extra: [Response.Header] = []) -> Response {
        Response(
            status: status,
            reason: reason,
            headers: [.init("Content-Type", "text/plain; charset=utf-8"), .init("Content-Length", "0")] + extra,
            body: Data()
        )
    }

    /// Resolves a request target ("/<token>/notes/x.html?q#frag") to a vault file,
    /// or nil if the token is wrong or the path escapes the vault.
    static func fileURL(forTarget target: String, vaultURL: URL, token: String) -> URL? {
        var path = target
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        if let h = path.firstIndex(of: "#") { path = String(path[..<h]) }

        let prefix = "/\(token)/"
        guard path == "/\(token)" || path.hasPrefix(prefix) else { return nil }

        let encodedRelative = path == "/\(token)" ? "" : String(path.dropFirst(prefix.count))
        guard let relative = encodedRelative.removingPercentEncoding,
              !relative.contains("\0"),
              !relative.hasPrefix("/") else {
            return nil
        }
        if relative.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
            return nil
        }

        let candidate = vaultURL.appendingPathComponent(relative, isDirectory: false).standardizedFileURL
        guard containmentPolicy.allows(candidate, vaultRoot: vaultURL) else { return nil }
        return candidate
    }

    /// Parses a single-range `bytes=` header into a half-open byte range, clamped
    /// to the content length. Returns nil for unsatisfiable or multi-range specs.
    static func parseByteRange(_ header: String, totalLength: Int) -> Range<Int>? {
        guard totalLength > 0, header.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(",") else { return nil }

        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)

        if startStr.isEmpty {
            guard let suffix = Int(endStr), suffix > 0 else { return nil }
            let length = min(suffix, totalLength)
            return (totalLength - length)..<totalLength
        }

        guard let start = Int(startStr), start >= 0, start < totalLength else { return nil }
        if endStr.isEmpty {
            return start..<totalLength
        }
        guard let end = Int(endStr), end >= start else { return nil }
        return start..<(min(end, totalLength - 1) + 1)
    }
}

/// A loopback-only HTTP/1.1 server that serves a vault's files so documents render
/// from an `http://127.0.0.1` origin. That real web origin is what lets third-party
/// embeds (e.g. a YouTube <iframe>) load — they reject custom-scheme/file origins.
/// Bound to the loopback interface with a per-session random path token so other
/// processes can't guess the URL.
final class VaultHTTPServer: @unchecked Sendable {
    // All mutable state is confined to `queue`; start()/stop() hop onto it. The class
    // is @unchecked Sendable on that basis so it can be held by an @MainActor owner.
    private let queue = DispatchQueue(label: "com.htmlgraph.VaultHTTPServer")
    private var listener: NWListener?
    private var responder: VaultHTTPResponder?
    private var didComplete = false
    /// Expected `Host` header ("127.0.0.1:<port>"). Requests with a different Host are
    /// rejected to block DNS-rebinding reach to the loopback socket.
    private var expectedHost: String?

    /// Cancels a connection that hasn't sent a complete request header in time, so a
    /// stalled or abandoned socket can't park a receive callback forever.
    private static let requestTimeout: TimeInterval = 10

    /// Starts (or restarts) the server for a vault. `completion` is invoked once on an
    /// internal queue with `http://127.0.0.1:<port>/<token>/`, or nil on failure.
    func start(vaultURL: URL, completion: @escaping @Sendable (URL?) -> Void) {
        queue.async { [weak self] in
            self?.startOnQueue(vaultURL: vaultURL, completion: completion)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.teardown()
        }
    }

    deinit {
        listener?.cancel()
    }

    private func startOnQueue(vaultURL: URL, completion: @escaping @Sendable (URL?) -> Void) {
        teardown()

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        responder = VaultHTTPResponder(vaultURL: vaultURL, token: token)
        didComplete = false

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: parameters) else {
            completion(nil)
            return
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !self.didComplete else { return }
            switch state {
            case .ready:
                if let port = listener.port?.rawValue,
                   let base = URL(string: "http://127.0.0.1:\(port)/\(token)/") {
                    self.didComplete = true
                    self.expectedHost = "127.0.0.1:\(port)"
                    completion(base)
                } else {
                    self.didComplete = true
                    completion(nil)
                }
            case .failed:
                self.didComplete = true
                completion(nil)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    private func teardown() {
        listener?.cancel()
        listener = nil
        responder = nil
        expectedHost = nil
        didComplete = false
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: timeout)
        receiveRequest(on: connection, buffer: Data(), timeout: timeout)
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { timeout.cancel(); connection.cancel(); return }

            var buffer = buffer
            if let data { buffer.append(data) }

            if let headerEnd = Self.rangeOfHeaderEnd(in: buffer) {
                timeout.cancel()
                self.respond(to: buffer.subdata(in: buffer.startIndex..<headerEnd), on: connection)
                return
            }
            if isComplete || error != nil || buffer.count > 64 * 1024 {
                timeout.cancel()
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, buffer: buffer, timeout: timeout)
        }
    }

    private func respond(to headerData: Data, on connection: NWConnection) {
        guard let responder,
              let requestText = String(data: headerData, encoding: .utf8),
              let requestLine = requestText.components(separatedBy: "\r\n").first else {
            connection.cancel()
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = String(parts[0])
        let target = String(parts[1])

        var rangeHeader: String?
        var hostHeader: String?
        for line in requestText.components(separatedBy: "\r\n").dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let name = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            if name.caseInsensitiveCompare("Range") == .orderedSame {
                rangeHeader = value
            } else if name.caseInsensitiveCompare("Host") == .orderedSame {
                hostHeader = value
            }
        }

        // Reject a mismatched Host (DNS-rebinding defense). WebKit always sends the
        // loopback host:port; an absent Host (HTTP/1.0) is tolerated.
        if let expectedHost, let hostHeader, hostHeader != expectedHost {
            send(
                VaultHTTPResponder.Response(
                    status: 403,
                    reason: "Forbidden",
                    headers: [.init("Content-Type", "text/plain; charset=utf-8"), .init("Content-Length", "0")],
                    body: Data()
                ),
                method: method,
                on: connection
            )
            return
        }

        send(responder.respond(method: method, target: target, rangeHeader: rangeHeader), method: method, on: connection)
    }

    private func send(_ response: VaultHTTPResponder.Response, method: String, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for header in response.headers {
            head += "\(header.name): \(header.value)\r\n"
        }
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        if method.uppercased() != "HEAD" {
            out.append(response.body)
        }
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func rangeOfHeaderEnd(in data: Data) -> Data.Index? {
        data.range(of: Data("\r\n\r\n".utf8))?.upperBound
    }
}

extension VaultHTTPServer {
    /// Loopback URL that serves a vault file, or nil if the file is outside the vault.
    static func resourceURL(forFileAt fileURL: URL, baseURL: URL, vaultURL: URL) -> URL? {
        guard let relative = vaultRelativePath(for: fileURL, in: vaultURL) else { return nil }
        let encoded = relative
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: encoded, relativeTo: baseURL)?.absoluteURL
    }

    /// Maps a loopback request URL back to the vault file it serves, or nil if it is
    /// not one of ours (wrong host/port/token) or escapes the vault.
    static func fileURL(forLoopback url: URL, baseURL: URL, vaultURL: URL) -> URL? {
        // Match our real origin exactly — same scheme (http), host, and port. Don't
        // accept https on the same port; the server speaks http only.
        guard let scheme = url.scheme?.lowercased(), scheme == (baseURL.scheme?.lowercased() ?? "http"),
              url.host == baseURL.host, url.port == baseURL.port,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let baseComps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let basePath = baseComps.percentEncodedPath
        guard comps.percentEncodedPath.hasPrefix(basePath) else { return nil }

        let encodedRelative = String(comps.percentEncodedPath.dropFirst(basePath.count))
        guard let relative = encodedRelative.removingPercentEncoding,
              !relative.contains("\0"),
              !relative.hasPrefix("/") else {
            return nil
        }
        if relative.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
            return nil
        }

        let candidate = vaultURL.appendingPathComponent(relative, isDirectory: false).standardizedFileURL
        guard containmentPolicy.allows(candidate, vaultRoot: vaultURL) else { return nil }
        return candidate
    }

    private static let containmentPolicy = VaultSecurityPolicy(mode: .safe, allowsNetworkAccess: false)

    private static func vaultRelativePath(for fileURL: URL, in vaultURL: URL) -> String? {
        let fileComponents = fileURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let vaultComponents = vaultURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileComponents.count > vaultComponents.count else { return nil }
        guard zip(vaultComponents, fileComponents).allSatisfy({ $0 == $1 }) else { return nil }
        return fileComponents.dropFirst(vaultComponents.count).joined(separator: "/")
    }
}
