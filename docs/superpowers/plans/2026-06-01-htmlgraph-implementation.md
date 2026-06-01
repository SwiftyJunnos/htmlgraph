# HTMLGraph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first macOS-first HTMLGraph MVP: open a local HTML vault, index links/backlinks, render documents, and show local/global graph context.

**Architecture:** Use a Swift Package with two targets: `HTMLGraphCore` for indexing, parsing, cache models, and policy decisions, and `HTMLGraph` for the SwiftUI macOS app shell with a WKWebView renderer. The first vertical slice should prove vault open -> index -> render selected document -> backlinks -> local graph before adding global graph polish and trusted-mode UI.

**Tech Stack:** Swift 6, SwiftUI, WebKit/WKWebView, SwiftSoup for HTML parsing, XCTest, macOS 14+.

---

## File Structure

- `Package.swift`: Swift package manifest with app, core, tests, and SwiftSoup dependency.
- `Sources/HTMLGraphCore/DocumentNode.swift`: document node model.
- `Sources/HTMLGraphCore/LinkEdge.swift`: edge model and link status.
- `Sources/HTMLGraphCore/VaultIndex.swift`: aggregate graph index model.
- `Sources/HTMLGraphCore/HTMLMetadataExtractor.swift`: title and link extraction using SwiftSoup.
- `Sources/HTMLGraphCore/LinkNormalizer.swift`: href classification and vault-relative path resolution.
- `Sources/HTMLGraphCore/VaultIndexer.swift`: scans vaults and builds `VaultIndex`.
- `Sources/HTMLGraphCore/VaultIndexCache.swift`: JSON cache read/write under app data.
- `Sources/HTMLGraphCore/VaultSecurityPolicy.swift`: Safe/Trusted policy model.
- `Sources/HTMLGraph/HTMLGraphApp.swift`: app entrypoint.
- `Sources/HTMLGraph/AppState.swift`: selected vault, selected document, current index, mode state.
- `Sources/HTMLGraph/Views/ContentView.swift`: three-pane root UI.
- `Sources/HTMLGraph/Views/VaultSidebar.swift`: file tree/search/recent docs.
- `Sources/HTMLGraph/Views/ReaderPane.swift`: reader header and WKWebView container.
- `Sources/HTMLGraph/Views/ContextPane.swift`: backlinks/local graph tabs.
- `Sources/HTMLGraph/Views/GlobalGraphView.swift`: full-window global graph view.
- `Sources/HTMLGraph/Web/HTMLDocumentWebView.swift`: WKWebView wrapper and navigation interception.
- `Sources/HTMLGraph/Web/GraphWebView.swift`: WKWebView graph renderer.
- `Sources/HTMLGraph/Web/VaultResourceSchemeHandler.swift`: controlled vault resource loading.
- `Tests/HTMLGraphCoreTests/*`: core/index/security tests.
- `Fixtures/sample-vault/*`: sample HTML vault used by tests and manual QA.
- `README.md`: dev setup and MVP usage.

## Task 1: Initialize Swift Package Skeleton

**Files:**
- Create: `Package.swift`
- Create: `Sources/HTMLGraphCore/DocumentNode.swift`
- Create: `Sources/HTMLGraph/HTMLGraphApp.swift`
- Create: `Tests/HTMLGraphCoreTests/SmokeTests.swift`
- Create: `README.md`

- [ ] **Step 1: Initialize git if needed**

Run:

```bash
git rev-parse --is-inside-work-tree || git init
```

Expected: prints `true` if already initialized, or initializes a repo.

- [ ] **Step 2: Create the package manifest**

Create `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HTMLGraph",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "HTMLGraphCore", targets: ["HTMLGraphCore"]),
        .executable(name: "HTMLGraph", targets: ["HTMLGraph"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.8.8")
    ],
    targets: [
        .target(
            name: "HTMLGraphCore",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup")
            ]
        ),
        .executableTarget(
            name: "HTMLGraph",
            dependencies: ["HTMLGraphCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "HTMLGraphCoreTests",
            dependencies: ["HTMLGraphCore"]
        )
    ]
)
```

- [ ] **Step 3: Add a minimal core model**

Create `Sources/HTMLGraphCore/DocumentNode.swift`:

```swift
import Foundation

public struct DocumentNode: Codable, Equatable, Identifiable, Hashable {
    public let id: String
    public let path: String
    public let absolutePath: String
    public let title: String
    public let contentHash: String
    public let lastModified: Date

    public init(
        id: String,
        path: String,
        absolutePath: String,
        title: String,
        contentHash: String,
        lastModified: Date
    ) {
        self.id = id
        self.path = path
        self.absolutePath = absolutePath
        self.title = title
        self.contentHash = contentHash
        self.lastModified = lastModified
    }
}
```

- [ ] **Step 4: Add a minimal app entrypoint**

Create `Sources/HTMLGraph/HTMLGraphApp.swift`:

```swift
import SwiftUI

@main
struct HTMLGraphApp: App {
    var body: some Scene {
        WindowGroup {
            Text("HTMLGraph")
                .frame(minWidth: 900, minHeight: 640)
        }
    }
}
```

- [ ] **Step 5: Add a smoke test**

Create `Tests/HTMLGraphCoreTests/SmokeTests.swift`:

```swift
import XCTest
@testable import HTMLGraphCore

final class SmokeTests: XCTestCase {
    func testDocumentNodeStoresVaultRelativePath() {
        let node = DocumentNode(
            id: "index.html",
            path: "index.html",
            absolutePath: "/tmp/vault/index.html",
            title: "Home",
            contentHash: "abc",
            lastModified: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(node.id, "index.html")
        XCTAssertEqual(node.title, "Home")
    }
}
```

- [ ] **Step 6: Add README**

Create `README.md`:

```markdown
# HTMLGraph

HTMLGraph is a macOS-first desktop viewer for local HTML knowledge vaults.

MVP scope:
- Open a local folder of `.html` / `.htm` files.
- Render HTML documents.
- Build links and backlinks from `<a href>`.
- Show local and global graph views.
- Keep the source vault read-only.

Development:

```bash
swift test
swift run HTMLGraph
```
```

- [ ] **Step 7: Verify skeleton**

Run:

```bash
swift test
```

Expected: `SmokeTests` passes.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources Tests README.md
git commit -m "chore: initialize HTMLGraph Swift package"
```

## Task 2: Add Sample HTML Vault Fixture

**Files:**
- Create: `Fixtures/sample-vault/index.html`
- Create: `Fixtures/sample-vault/notes/graph.html`
- Create: `Fixtures/sample-vault/notes/backlinks.html`
- Create: `Fixtures/sample-vault/notes/cycle-a.html`
- Create: `Fixtures/sample-vault/notes/cycle-b.html`
- Create: `Fixtures/sample-vault/notes/orphan.html`
- Create: `Fixtures/sample-vault/assets/style.css`
- Create: `Fixtures/sample-vault/assets/logo.svg`

- [ ] **Step 1: Create fixture documents**

Create `Fixtures/sample-vault/index.html`:

```html
<!doctype html>
<html>
  <head>
    <title>HTMLGraph Home</title>
    <link rel="stylesheet" href="./assets/style.css">
  </head>
  <body>
    <h1>HTMLGraph Home</h1>
    <p>This is the home note for the sample vault.</p>
    <p><a href="./notes/graph.html">Graph note</a></p>
    <p><a href="./notes/backlinks.html#linked-mentions">Backlinks note</a></p>
    <p><a href="./notes/missing.html">Broken local link</a></p>
    <img src="./assets/logo.svg" alt="HTMLGraph logo">
  </body>
</html>
```

Create `Fixtures/sample-vault/notes/graph.html`:

```html
<!doctype html>
<html>
  <head><title>Graph View</title></head>
  <body>
    <h1>Graph View</h1>
    <p>Graph edges come from links.</p>
    <a href="../index.html">Home</a>
    <a href="./cycle-a.html">Cycle A</a>
    <a href="#local-section">Local section</a>
    <h2 id="local-section">Local Section</h2>
  </body>
</html>
```

Create `Fixtures/sample-vault/notes/backlinks.html`:

```html
<!doctype html>
<html>
  <head><title>Backlinks</title></head>
  <body>
    <h1>Backlinks</h1>
    <p id="linked-mentions">Incoming links should show as backlinks.</p>
    <a href="../index.html">Home</a>
    <a href="https://obsidian.md/">External Obsidian link</a>
  </body>
</html>
```

Create `Fixtures/sample-vault/notes/cycle-a.html`:

```html
<!doctype html>
<html>
  <head><title>Cycle A</title></head>
  <body>
    <h1>Cycle A</h1>
    <a href="./cycle-b.html">Cycle B</a>
  </body>
</html>
```

Create `Fixtures/sample-vault/notes/cycle-b.html`:

```html
<!doctype html>
<html>
  <head><title>Cycle B</title></head>
  <body>
    <h1>Cycle B</h1>
    <a href="./cycle-a.html">Cycle A</a>
  </body>
</html>
```

Create `Fixtures/sample-vault/notes/orphan.html`:

```html
<!doctype html>
<html>
  <head><title>Orphan</title></head>
  <body>
    <h1>Orphan</h1>
    <p>This document has no links and no backlinks.</p>
  </body>
</html>
```

- [ ] **Step 2: Add static assets**

Create `Fixtures/sample-vault/assets/style.css`:

```css
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  max-width: 720px;
  margin: 40px auto;
  line-height: 1.5;
}

a {
  color: #0f6bff;
}
```

Create `Fixtures/sample-vault/assets/logo.svg`:

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60" viewBox="0 0 120 60" role="img">
  <rect width="120" height="60" rx="8" fill="#f4f7fb"/>
  <circle cx="30" cy="30" r="8" fill="#0f6bff"/>
  <circle cx="60" cy="18" r="8" fill="#1d9a6c"/>
  <circle cx="90" cy="36" r="8" fill="#d85f35"/>
  <path d="M38 28 L52 20 M68 21 L82 33" stroke="#334155" stroke-width="3"/>
</svg>
```

- [ ] **Step 3: Commit**

```bash
git add Fixtures/sample-vault
git commit -m "test: add sample HTML vault fixture"
```

## Task 3: Implement HTML Metadata and Link Extraction

**Files:**
- Create: `Sources/HTMLGraphCore/LinkEdge.swift`
- Create: `Sources/HTMLGraphCore/HTMLMetadataExtractor.swift`
- Create: `Tests/HTMLGraphCoreTests/HTMLMetadataExtractorTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/HTMLGraphCoreTests/HTMLMetadataExtractorTests.swift`:

```swift
import XCTest
@testable import HTMLGraphCore

final class HTMLMetadataExtractorTests: XCTestCase {
    func testTitleUsesTitleBeforeH1BeforeFilename() throws {
        let extractor = HTMLMetadataExtractor()

        XCTAssertEqual(
            try extractor.title(from: "<html><head><title>Title Tag</title></head><body><h1>Heading</h1></body></html>", fallbackFilename: "file.html"),
            "Title Tag"
        )
        XCTAssertEqual(
            try extractor.title(from: "<html><body><h1>Heading</h1></body></html>", fallbackFilename: "file.html"),
            "Heading"
        )
        XCTAssertEqual(
            try extractor.title(from: "<html><body><p>No title</p></body></html>", fallbackFilename: "file.html"),
            "file"
        )
    }

    func testExtractsLinksWithHrefAndText() throws {
        let extractor = HTMLMetadataExtractor()
        let links = try extractor.links(from: """
        <html><body>
          <a href="./notes/graph.html">Graph note</a>
          <a href="https://example.com">External</a>
        </body></html>
        """)

        XCTAssertEqual(links.map(\.href), ["./notes/graph.html", "https://example.com"])
        XCTAssertEqual(links.map(\.text), ["Graph note", "External"])
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter HTMLMetadataExtractorTests
```

Expected: compile failure because `HTMLMetadataExtractor` does not exist.

- [ ] **Step 3: Add link and extractor types**

Create `Sources/HTMLGraphCore/LinkEdge.swift`:

```swift
import Foundation

public enum LinkStatus: String, Codable, Equatable, Hashable {
    case resolved
    case unresolved
    case sameDocument
    case external
}

public struct RawHTMLLink: Equatable, Hashable {
    public let href: String
    public let text: String

    public init(href: String, text: String) {
        self.href = href
        self.text = text
    }
}

public struct LinkEdge: Codable, Equatable, Identifiable, Hashable {
    public var id: String { "\(sourceId)->\(href)" }
    public let sourceId: String
    public let targetId: String?
    public let href: String
    public let normalizedTargetPath: String?
    public let fragment: String?
    public let linkText: String
    public let status: LinkStatus

    public init(
        sourceId: String,
        targetId: String?,
        href: String,
        normalizedTargetPath: String?,
        fragment: String?,
        linkText: String,
        status: LinkStatus
    ) {
        self.sourceId = sourceId
        self.targetId = targetId
        self.href = href
        self.normalizedTargetPath = normalizedTargetPath
        self.fragment = fragment
        self.linkText = linkText
        self.status = status
    }
}
```

Create `Sources/HTMLGraphCore/HTMLMetadataExtractor.swift`:

```swift
import Foundation
import SwiftSoup

public struct HTMLMetadataExtractor {
    public init() {}

    public func title(from html: String, fallbackFilename: String) throws -> String {
        let document = try SwiftSoup.parse(html)
        let title = try document.title().trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }

        let h1 = try document.select("h1").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !h1.isEmpty {
            return h1
        }

        return URL(fileURLWithPath: fallbackFilename).deletingPathExtension().lastPathComponent
    }

    public func links(from html: String) throws -> [RawHTMLLink] {
        let document = try SwiftSoup.parse(html)
        return try document.select("a[href]").array().map { element in
            RawHTMLLink(
                href: try element.attr("href"),
                text: try element.text()
            )
        }
    }
}
```

- [ ] **Step 4: Verify tests pass**

Run:

```bash
swift test --filter HTMLMetadataExtractorTests
```

Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HTMLGraphCore Tests/HTMLGraphCoreTests
git commit -m "feat: extract HTML titles and links"
```

## Task 4: Implement Link Normalization and Vault Indexing

**Files:**
- Create: `Sources/HTMLGraphCore/LinkNormalizer.swift`
- Create: `Sources/HTMLGraphCore/VaultIndex.swift`
- Create: `Sources/HTMLGraphCore/VaultIndexer.swift`
- Create: `Tests/HTMLGraphCoreTests/VaultIndexerTests.swift`

- [ ] **Step 1: Write failing indexer tests**

Create `Tests/HTMLGraphCoreTests/VaultIndexerTests.swift`:

```swift
import XCTest
@testable import HTMLGraphCore

final class VaultIndexerTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Fixtures/sample-vault")
    }

    func testIndexesDocumentsAndBuildsBacklinks() throws {
        let index = try VaultIndexer().indexVault(at: fixtureURL)

        XCTAssertEqual(index.documents.count, 6)
        XCTAssertEqual(index.document(id: "index.html")?.title, "HTMLGraph Home")

        let graphBacklinks = index.backlinks["notes/graph.html"] ?? []
        XCTAssertTrue(graphBacklinks.contains { $0.sourceId == "index.html" })
    }

    func testClassifiesExternalSameDocumentAndUnresolvedLinks() throws {
        let index = try VaultIndexer().indexVault(at: fixtureURL)

        XCTAssertTrue(index.edges.contains { $0.href == "https://example.com" || $0.href == "https://obsidian.md/" && $0.status == .external })
        XCTAssertTrue(index.edges.contains { $0.href == "#local-section" && $0.status == .sameDocument })
        XCTAssertTrue(index.unresolvedLinks["index.html"]?.contains { $0.href == "./notes/missing.html" } == true)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter VaultIndexerTests
```

Expected: compile failure because `VaultIndexer` and `VaultIndex` do not exist.

- [ ] **Step 3: Add graph index model**

Create `Sources/HTMLGraphCore/VaultIndex.swift`:

```swift
import Foundation

public struct VaultIndex: Codable, Equatable {
    public let vaultId: String
    public let documents: [DocumentNode]
    public let edges: [LinkEdge]
    public let backlinks: [String: [LinkEdge]]
    public let unresolvedLinks: [String: [LinkEdge]]
    public let lastIndexedAt: Date

    public init(
        vaultId: String,
        documents: [DocumentNode],
        edges: [LinkEdge],
        backlinks: [String: [LinkEdge]],
        unresolvedLinks: [String: [LinkEdge]],
        lastIndexedAt: Date
    ) {
        self.vaultId = vaultId
        self.documents = documents
        self.edges = edges
        self.backlinks = backlinks
        self.unresolvedLinks = unresolvedLinks
        self.lastIndexedAt = lastIndexedAt
    }

    public func document(id: String) -> DocumentNode? {
        documents.first { $0.id == id }
    }
}
```

- [ ] **Step 4: Add link normalizer**

Create `Sources/HTMLGraphCore/LinkNormalizer.swift`:

```swift
import Foundation

public struct NormalizedLink: Equatable {
    public let targetPath: String?
    public let fragment: String?
    public let status: LinkStatus
}

public struct LinkNormalizer {
    public init() {}

    public func normalize(href: String, sourcePath: String, knownDocumentIds: Set<String>) -> NormalizedLink {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return NormalizedLink(targetPath: nil, fragment: nil, status: .unresolved)
        }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("mailto:") {
            return NormalizedLink(targetPath: nil, fragment: nil, status: .external)
        }

        if trimmed.hasPrefix("#") {
            return NormalizedLink(targetPath: sourcePath, fragment: String(trimmed.dropFirst()), status: .sameDocument)
        }

        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let pathPart = String(parts[0]).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let fragment = parts.count > 1 ? String(parts[1]) : nil

        let sourceDirectory = (sourcePath as NSString).deletingLastPathComponent
        let joined = sourceDirectory.isEmpty ? pathPart : "\(sourceDirectory)/\(pathPart)"
        let relative = (joined as NSString).standardizingPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard relative.hasSuffix(".html") || relative.hasSuffix(".htm") else {
            return NormalizedLink(targetPath: relative, fragment: fragment, status: .unresolved)
        }

        let status: LinkStatus = knownDocumentIds.contains(relative) ? .resolved : .unresolved
        return NormalizedLink(targetPath: relative, fragment: fragment, status: status)
    }
}
```

- [ ] **Step 5: Add vault indexer**

Create `Sources/HTMLGraphCore/VaultIndexer.swift`:

```swift
import CryptoKit
import Foundation

public struct VaultIndexer {
    private let extractor: HTMLMetadataExtractor
    private let normalizer: LinkNormalizer

    public init(
        extractor: HTMLMetadataExtractor = HTMLMetadataExtractor(),
        normalizer: LinkNormalizer = LinkNormalizer()
    ) {
        self.extractor = extractor
        self.normalizer = normalizer
    }

    public func indexVault(at vaultURL: URL) throws -> VaultIndex {
        let fileURLs = try htmlFiles(in: vaultURL)
        let knownIds = Set(fileURLs.map { relativePath(for: $0, in: vaultURL) })

        let documents = try fileURLs.map { fileURL in
            let html = try String(contentsOf: fileURL, encoding: .utf8)
            let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            let relative = relativePath(for: fileURL, in: vaultURL)
            return DocumentNode(
                id: relative,
                path: relative,
                absolutePath: fileURL.path,
                title: try extractor.title(from: html, fallbackFilename: fileURL.lastPathComponent),
                contentHash: sha256(html),
                lastModified: values.contentModificationDate ?? .distantPast
            )
        }.sorted { $0.path < $1.path }

        var edges: [LinkEdge] = []
        for fileURL in fileURLs {
            let sourceId = relativePath(for: fileURL, in: vaultURL)
            let html = try String(contentsOf: fileURL, encoding: .utf8)
            for rawLink in try extractor.links(from: html) {
                let normalized = normalizer.normalize(
                    href: rawLink.href,
                    sourcePath: sourceId,
                    knownDocumentIds: knownIds
                )
                edges.append(LinkEdge(
                    sourceId: sourceId,
                    targetId: normalized.status == .resolved || normalized.status == .sameDocument ? normalized.targetPath : nil,
                    href: rawLink.href,
                    normalizedTargetPath: normalized.targetPath,
                    fragment: normalized.fragment,
                    linkText: rawLink.text,
                    status: normalized.status
                ))
            }
        }

        let backlinks = Dictionary(grouping: edges.filter { $0.status == .resolved }) { edge in
            edge.targetId ?? ""
        }
        let unresolved = Dictionary(grouping: edges.filter { $0.status == .unresolved }) { edge in
            edge.sourceId
        }

        return VaultIndex(
            vaultId: vaultURL.standardizedFileURL.path,
            documents: documents,
            edges: edges,
            backlinks: backlinks,
            unresolvedLinks: unresolved,
            lastIndexedAt: Date()
        )
    }

    private func htmlFiles(in vaultURL: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        guard let enumerator else { return [] }

        return try enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { return nil }
            let ext = url.pathExtension.lowercased()
            return (ext == "html" || ext == "htm") ? url : nil
        }
    }

    private func relativePath(for fileURL: URL, in vaultURL: URL) -> String {
        let base = vaultURL.standardizedFileURL.path
        let full = fileURL.standardizedFileURL.path
        return String(full.dropFirst(base.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func sha256(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 6: Verify indexer tests pass**

Run:

```bash
swift test --filter VaultIndexerTests
```

Expected: tests pass.

- [ ] **Step 7: Run all core tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/HTMLGraphCore Tests/HTMLGraphCoreTests
git commit -m "feat: index HTML vault links and backlinks"
```

## Task 5: Add Cache and Security Policy Models

**Files:**
- Create: `Sources/HTMLGraphCore/VaultIndexCache.swift`
- Create: `Sources/HTMLGraphCore/VaultSecurityPolicy.swift`
- Create: `Tests/HTMLGraphCoreTests/VaultIndexCacheTests.swift`
- Create: `Tests/HTMLGraphCoreTests/VaultSecurityPolicyTests.swift`

- [ ] **Step 1: Write cache and policy tests**

Create `Tests/HTMLGraphCoreTests/VaultIndexCacheTests.swift`:

```swift
import XCTest
@testable import HTMLGraphCore

final class VaultIndexCacheTests: XCTestCase {
    func testRoundTripsIndexCache() throws {
        let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cache = VaultIndexCache(rootURL: cacheRoot)
        let index = VaultIndex(vaultId: "fixture", documents: [], edges: [], backlinks: [:], unresolvedLinks: [:], lastIndexedAt: Date(timeIntervalSince1970: 1))

        try cache.save(index)
        let loaded = try cache.load(vaultId: "fixture")

        XCTAssertEqual(loaded?.vaultId, "fixture")
        XCTAssertEqual(loaded?.lastIndexedAt, Date(timeIntervalSince1970: 1))
    }
}
```

Create `Tests/HTMLGraphCoreTests/VaultSecurityPolicyTests.swift`:

```swift
import XCTest
@testable import HTMLGraphCore

final class VaultSecurityPolicyTests: XCTestCase {
    func testSafeModeBlocksNetworkAndJavascriptByDefault() {
        let policy = VaultSecurityPolicy(mode: .safe, allowsNetworkAccess: false)

        XCTAssertFalse(policy.allowsJavaScript)
        XCTAssertFalse(policy.allows(URL(string: "https://example.com/app.js")!, vaultRoot: URL(fileURLWithPath: "/vault")))
        XCTAssertTrue(policy.allows(URL(fileURLWithPath: "/vault/assets/style.css"), vaultRoot: URL(fileURLWithPath: "/vault")))
        XCTAssertFalse(policy.allows(URL(fileURLWithPath: "/private/secret.txt"), vaultRoot: URL(fileURLWithPath: "/vault")))
    }

    func testTrustedModeAllowsJavaScriptButNetworkIsSeparate() {
        let policy = VaultSecurityPolicy(mode: .trusted, allowsNetworkAccess: false)

        XCTAssertTrue(policy.allowsJavaScript)
        XCTAssertFalse(policy.allows(URL(string: "https://example.com/app.js")!, vaultRoot: URL(fileURLWithPath: "/vault")))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter VaultIndexCacheTests
swift test --filter VaultSecurityPolicyTests
```

Expected: compile failures for missing types.

- [ ] **Step 3: Implement cache**

Create `Sources/HTMLGraphCore/VaultIndexCache.swift`:

```swift
import Foundation

public struct VaultIndexCache {
    private let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public func save(_ index: VaultIndex) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try JSONEncoder.htmlGraph.encode(index)
        try data.write(to: fileURL(for: index.vaultId), options: [.atomic])
    }

    public func load(vaultId: String) throws -> VaultIndex? {
        let url = fileURL(for: vaultId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.htmlGraph.decode(VaultIndex.self, from: data)
    }

    private func fileURL(for vaultId: String) -> URL {
        let safeName = vaultId.data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return rootURL.appendingPathComponent("\(safeName).json")
    }
}

private extension JSONEncoder {
    static var htmlGraph: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var htmlGraph: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
```

- [ ] **Step 4: Implement security policy**

Create `Sources/HTMLGraphCore/VaultSecurityPolicy.swift`:

```swift
import Foundation

public enum VaultTrustMode: String, Codable, Equatable {
    case safe
    case trusted
}

public struct VaultSecurityPolicy: Codable, Equatable {
    public let mode: VaultTrustMode
    public let allowsNetworkAccess: Bool

    public var allowsJavaScript: Bool {
        mode == .trusted
    }

    public init(mode: VaultTrustMode, allowsNetworkAccess: Bool) {
        self.mode = mode
        self.allowsNetworkAccess = allowsNetworkAccess
    }

    public func allows(_ resourceURL: URL, vaultRoot: URL) -> Bool {
        if ["http", "https"].contains(resourceURL.scheme?.lowercased()) {
            return allowsNetworkAccess
        }

        guard resourceURL.isFileURL else {
            return false
        }

        let rootPath = vaultRoot.standardizedFileURL.path
        let resourcePath = resourceURL.standardizedFileURL.path
        return resourcePath == rootPath || resourcePath.hasPrefix(rootPath + "/")
    }
}
```

- [ ] **Step 5: Verify**

Run:

```bash
swift test --filter VaultIndexCacheTests
swift test --filter VaultSecurityPolicyTests
swift test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/HTMLGraphCore Tests/HTMLGraphCoreTests
git commit -m "feat: add vault cache and security policy"
```

## Task 6: Build SwiftUI Three-Pane App Shell

**Files:**
- Modify: `Sources/HTMLGraph/HTMLGraphApp.swift`
- Create: `Sources/HTMLGraph/AppState.swift`
- Create: `Sources/HTMLGraph/Views/ContentView.swift`
- Create: `Sources/HTMLGraph/Views/VaultSidebar.swift`
- Create: `Sources/HTMLGraph/Views/ReaderPane.swift`
- Create: `Sources/HTMLGraph/Views/ContextPane.swift`

- [ ] **Step 1: Create app state**

Create `Sources/HTMLGraph/AppState.swift`:

```swift
import Foundation
import HTMLGraphCore
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var vaultURL: URL?
    @Published var index: VaultIndex?
    @Published var selectedDocumentId: String?
    @Published var searchText: String = ""
    @Published var trustMode: VaultTrustMode = .safe
    @Published var allowsNetworkAccess: Bool = false
    @Published var errorMessage: String?

    var selectedDocument: DocumentNode? {
        guard let selectedDocumentId else { return nil }
        return index?.document(id: selectedDocumentId)
    }

    var filteredDocuments: [DocumentNode] {
        let documents = index?.documents ?? []
        guard !searchText.isEmpty else { return documents }
        return documents.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    func openVault(_ url: URL) {
        do {
            vaultURL = url
            let builtIndex = try VaultIndexer().indexVault(at: url)
            index = builtIndex
            selectedDocumentId = builtIndex.documents.first?.id
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectDocument(_ id: String) {
        selectedDocumentId = id
    }
}
```

- [ ] **Step 2: Replace app entrypoint**

Update `Sources/HTMLGraph/HTMLGraphApp.swift`:

```swift
import SwiftUI

@main
struct HTMLGraphApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Vault...") {
                    NSApp.sendAction(#selector(AppCommands.openVault), to: nil, from: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

@objc
final class AppCommands: NSObject {
    @objc func openVault() {}
}
```

- [ ] **Step 3: Add root content view**

Create `Sources/HTMLGraph/Views/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            VaultSidebar()
                .frame(minWidth: 240)
        } content: {
            ReaderPane()
                .frame(minWidth: 520)
        } detail: {
            ContextPane()
                .frame(minWidth: 280)
        }
        .toolbar {
            Button("Open Vault") {
                chooseVault()
            }
        }
        .alert("HTMLGraph Error", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.openVault(url)
        }
    }
}
```

- [ ] **Step 4: Add sidebar**

Create `Sources/HTMLGraph/Views/VaultSidebar.swift`:

```swift
import SwiftUI

struct VaultSidebar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search files", text: $appState.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(10)

            List(appState.filteredDocuments, selection: $appState.selectedDocumentId) { document in
                VStack(alignment: .leading, spacing: 3) {
                    Text(document.title)
                        .font(.body)
                    Text(document.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(document.id)
            }
        }
    }
}
```

- [ ] **Step 5: Add reader and context first-pass views**

Create `Sources/HTMLGraph/Views/ReaderPane.swift`:

```swift
import SwiftUI

struct ReaderPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let document = appState.selectedDocument {
                HStack {
                    VStack(alignment: .leading) {
                        Text(document.title).font(.headline)
                        Text(document.path).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(appState.trustMode == .safe ? "Safe Mode" : "Trusted Mode")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button("Open External") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: document.absolutePath))
                    }
                }
                .padding()
                Divider()
                Text("Selected file: \(document.absolutePath)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Open a vault", systemImage: "folder", description: Text("Choose a local HTML folder to begin."))
            }
        }
    }
}
```

Create `Sources/HTMLGraph/Views/ContextPane.swift`:

```swift
import SwiftUI

struct ContextPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            backlinksView
                .tabItem { Text("Backlinks") }
            unresolvedLinksView
                .tabItem { Text("Unresolved") }
            Text("Local graph is added in Task 8")
                .tabItem { Text("Local Graph") }
        }
    }

    private var backlinksView: some View {
        List(appState.index?.backlinks[appState.selectedDocumentId ?? ""] ?? []) { edge in
            VStack(alignment: .leading) {
                Text(edge.sourceId)
                Text(edge.linkText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var unresolvedLinksView: some View {
        List(appState.index?.unresolvedLinks[appState.selectedDocumentId ?? ""] ?? []) { edge in
            VStack(alignment: .leading) {
                Text(edge.href)
                Text(edge.linkText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 6: Verify app compiles**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 7: Manual run**

Run:

```bash
swift run HTMLGraph
```

Expected: macOS app opens, `Open Vault` can load `Fixtures/sample-vault`, document list appears, selecting `Graph View` shows backlinks in the context pane.

- [ ] **Step 8: Commit**

```bash
git add Sources/HTMLGraph
git commit -m "feat: add three-pane macOS app shell"
```

## Task 7: Add WKWebView Renderer and Internal Link Navigation

**Files:**
- Create: `Sources/HTMLGraph/Web/HTMLDocumentWebView.swift`
- Modify: `Sources/HTMLGraph/Views/ReaderPane.swift`

- [ ] **Step 1: Add WebView wrapper**

Create `Sources/HTMLGraph/Web/HTMLDocumentWebView.swift`:

```swift
import SwiftUI
import WebKit

struct HTMLDocumentWebView: NSViewRepresentable {
    let documentURL: URL
    let vaultURL: URL
    let onInternalNavigation: (String) -> Void
    let onExternalNavigation: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadFileURL(documentURL, allowingReadAccessTo: vaultURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: HTMLDocumentWebView

        init(_ parent: HTMLDocumentWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if url.isFileURL, url.standardizedFileURL.path.hasPrefix(parent.vaultURL.standardizedFileURL.path) {
                let relative = String(url.standardizedFileURL.path.dropFirst(parent.vaultURL.standardizedFileURL.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                parent.onInternalNavigation(relative)
                decisionHandler(.cancel)
                return
            }

            parent.onExternalNavigation(url)
            decisionHandler(.cancel)
        }
    }
}
```

This uses `loadFileURL` as a temporary vertical-slice renderer. Task 9 replaces this with the controlled resource scheme required by the design.

- [ ] **Step 2: Use WebView in reader**

Replace the selected-file text in `ReaderPane` with:

```swift
if let vaultURL = appState.vaultURL {
    HTMLDocumentWebView(
        documentURL: URL(fileURLWithPath: document.absolutePath),
        vaultURL: vaultURL,
        onInternalNavigation: { relativePath in
            appState.selectDocument(relativePath)
        },
        onExternalNavigation: { url in
            NSWorkspace.shared.open(url)
        }
    )
} else {
    Text("No vault selected")
}
```

- [ ] **Step 3: Verify internal navigation**

Run:

```bash
swift build
swift run HTMLGraph
```

Expected: opening `Fixtures/sample-vault/index.html` and clicking `Graph note` selects `notes/graph.html` inside the app. Clicking the external Obsidian link opens the default browser.

- [ ] **Step 4: Commit**

```bash
git add Sources/HTMLGraph
git commit -m "feat: render HTML documents with WKWebView"
```

## Task 8: Add Renderer-Based Local and Global Graph Views

**Files:**
- Create: `Sources/HTMLGraph/Web/GraphWebView.swift`
- Create: `Sources/HTMLGraph/Views/GlobalGraphView.swift`
- Modify: `Sources/HTMLGraph/Views/ContextPane.swift`
- Modify: `Sources/HTMLGraph/HTMLGraphApp.swift`

- [ ] **Step 1: Add WKWebView graph renderer**

Create `Sources/HTMLGraph/Web/GraphWebView.swift`:

```swift
import HTMLGraphCore
import SwiftUI
import WebKit

struct GraphWebView: NSViewRepresentable {
    let centerId: String?
    let index: VaultIndex
    let global: Bool
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "graph")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(GraphHTMLBuilder(index: index, centerId: centerId, global: global).html(), baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let onSelect: (String) -> Void

        init(onSelect: @escaping (String) -> Void) {
            self.onSelect = onSelect
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "graph", let id = message.body as? String else { return }
            onSelect(id)
        }
    }
}

private struct GraphHTMLBuilder {
    let index: VaultIndex
    let centerId: String?
    let global: Bool

    func html() -> String {
        let renderedNodes = nodes.enumerated().map { offset, node in
            let angle = Double(offset) / Double(max(nodes.count, 1)) * Double.pi * 2
            let radius = global ? 220.0 : 150.0
            let x = 300 + cos(angle) * radius
            let y = 220 + sin(angle) * radius
            let fill = node.id == centerId ? "#0f6bff" : "#64748b"
            return """
            <g class="node" onclick="selectNode('\(escapeJS(node.id))')">
              <circle cx="\(x)" cy="\(y)" r="8" fill="\(fill)"></circle>
              <text x="\(x + 12)" y="\(y + 4)">\(escapeHTML(node.title))</text>
            </g>
            """
        }.joined(separator: "\n")

        let renderedEdges = edges.compactMap { edge -> String? in
            guard let targetId = edge.targetId,
                  let sourceIndex = nodes.firstIndex(where: { $0.id == edge.sourceId }),
                  let targetIndex = nodes.firstIndex(where: { $0.id == targetId }) else { return nil }
            let source = point(for: sourceIndex)
            let target = point(for: targetIndex)
            return "<line x1=\"\(source.x)\" y1=\"\(source.y)\" x2=\"\(target.x)\" y2=\"\(target.y)\" />"
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              html, body { margin: 0; height: 100%; font: 13px -apple-system, BlinkMacSystemFont, sans-serif; background: transparent; color: #172033; }
              svg { width: 100%; height: 100%; }
              line { stroke: #cbd5e1; stroke-width: 1.4; }
              text { fill: #172033; dominant-baseline: middle; pointer-events: none; }
              .node { cursor: pointer; }
            </style>
          </head>
          <body>
            <svg viewBox="0 0 600 440" role="img" aria-label="HTMLGraph graph view">
              \(renderedEdges)
              \(renderedNodes)
            </svg>
            <script>
              function selectNode(id) {
                window.webkit.messageHandlers.graph.postMessage(id);
              }
            </script>
          </body>
        </html>
        """
    }

    private var nodes: [DocumentNode] {
        if global || centerId == nil { return index.documents }
        let connectedIds = Set(index.edges.compactMap { edge -> String? in
            guard edge.status == .resolved else { return nil }
            if edge.sourceId == centerId { return edge.targetId }
            if edge.targetId == centerId { return edge.sourceId }
            return nil
        }).union([centerId!])
        return index.documents.filter { connectedIds.contains($0.id) }
    }

    private var edges: [LinkEdge] {
        index.edges.filter { $0.status == .resolved }
    }

    private func point(for offset: Int) -> (x: Double, y: Double) {
        let angle = Double(offset) / Double(max(nodes.count, 1)) * Double.pi * 2
        let radius = global ? 220.0 : 150.0
        return (300 + cos(angle) * radius, 220 + sin(angle) * radius)
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func escapeJS(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}
```

- [ ] **Step 2: Add graph to context pane**

Replace `Text("Local graph is added in Task 8")` in `ContextPane` with:

```swift
if let index = appState.index {
    GraphWebView(centerId: appState.selectedDocumentId, index: index, global: false) { id in
        appState.selectDocument(id)
    }
} else {
    Text("No graph")
}
```

- [ ] **Step 3: Add global graph window**

Create `Sources/HTMLGraph/Views/GlobalGraphView.swift`:

```swift
import SwiftUI

struct GlobalGraphView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let index = appState.index {
            GraphWebView(centerId: appState.selectedDocumentId, index: index, global: true) { id in
                appState.selectDocument(id)
            }
            .navigationTitle("Global Graph")
        } else {
            ContentUnavailableView("No vault open", systemImage: "circle.hexagongrid")
        }
    }
}
```

Update `HTMLGraphApp.swift` scene list:

```swift
Window("Global Graph", id: "global-graph") {
    GlobalGraphView()
        .environmentObject(appState)
        .frame(minWidth: 900, minHeight: 700)
}
```

- [ ] **Step 4: Add Cmd+G command**

In `HTMLGraphApp.swift`, add:

```swift
@Environment(\.openWindow) private var openWindow
```

Then add this command:

```swift
Button("Open Global Graph") {
    openWindow(id: "global-graph")
}
.keyboardShortcut("g", modifiers: .command)
```

- [ ] **Step 5: Verify graph behavior**

Run:

```bash
swift build
swift run HTMLGraph
```

Expected: context panel shows clickable local graph nodes. `Cmd+G` opens a separate global graph window.

- [ ] **Step 6: Commit**

```bash
git add Sources/HTMLGraph
git commit -m "feat: add local and global graph views"
```

## Task 9: Replace File URL Rendering with Controlled Resource Policy and Trust Controls

**Files:**
- Create: `Sources/HTMLGraph/Web/VaultResourceSchemeHandler.swift`
- Modify: `Sources/HTMLGraph/Web/HTMLDocumentWebView.swift`
- Modify: `Sources/HTMLGraph/AppState.swift`
- Modify: `Sources/HTMLGraph/Views/ReaderPane.swift`

- [ ] **Step 1: Add scheme handler**

Create `Sources/HTMLGraph/Web/VaultResourceSchemeHandler.swift`:

```swift
import Foundation
import HTMLGraphCore
import WebKit

final class VaultResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    private let vaultURL: URL
    private let policy: VaultSecurityPolicy

    init(vaultURL: URL, policy: VaultSecurityPolicy) {
        self.vaultURL = vaultURL
        self.policy = policy
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              requestURL.scheme == "htmlgraph" else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let relativePath = requestURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileURL = vaultURL.appendingPathComponent(relativePath)

        guard policy.allows(fileURL, vaultRoot: vaultURL) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType(for: fileURL),
                expectedContentLength: data.count,
                textEncodingName: "utf-8"
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }
}
```

- [ ] **Step 2: Expose selected vault policy from app state**

Add this computed property to `AppState`:

```swift
var securityPolicy: VaultSecurityPolicy {
    VaultSecurityPolicy(mode: trustMode, allowsNetworkAccess: allowsNetworkAccess)
}
```

- [ ] **Step 3: Load documents through `htmlgraph://vault/`**

Add a `policy` property to `HTMLDocumentWebView`:

```swift
let policy: VaultSecurityPolicy
```

In `HTMLDocumentWebView.makeNSView`, set:

```swift
configuration.setURLSchemeHandler(VaultResourceSchemeHandler(vaultURL: vaultURL, policy: policy), forURLScheme: "htmlgraph")
```

In `updateNSView`, replace `loadFileURL` with:

```swift
let relative = documentURL.standardizedFileURL.path
    .replacingOccurrences(of: vaultURL.standardizedFileURL.path + "/", with: "")
let url = URL(string: "htmlgraph://vault/\(relative)")!
if webView.url != url {
    webView.load(URLRequest(url: url))
}
```

- [ ] **Step 4: Add trust controls to the reader header**

In `ReaderPane`, pass the policy into `HTMLDocumentWebView`:

```swift
HTMLDocumentWebView(
    documentURL: URL(fileURLWithPath: document.absolutePath),
    vaultURL: vaultURL,
    policy: appState.securityPolicy,
    onInternalNavigation: { relativePath in
        appState.selectDocument(relativePath)
    },
    onExternalNavigation: { url in
        NSWorkspace.shared.open(url)
    }
)
```

Add this import to the top of `ReaderPane`:

```swift
import HTMLGraphCore
```

Replace the static Safe/Trusted label in `ReaderPane` with:

```swift
Picker("Trust", selection: $appState.trustMode) {
    Text("Safe").tag(VaultTrustMode.safe)
    Text("Trusted").tag(VaultTrustMode.trusted)
}
.pickerStyle(.segmented)
.frame(width: 160)

Toggle("Network", isOn: $appState.allowsNetworkAccess)
    .disabled(appState.trustMode != .trusted)
    .help("Network access is separate from Trusted Mode.")
```

- [ ] **Step 5: Verify safe and trusted rendering still work**

Run:

```bash
swift build
swift run HTMLGraph
```

Expected: sample vault HTML and local CSS/SVG still render. Safe is selected by default. Switching to Trusted changes the UI state without enabling Network. No arbitrary `file://` access is used for document loading.

- [ ] **Step 6: Commit**

```bash
git add Sources/HTMLGraph
git commit -m "feat: add controlled vault resource policy"
```

## Task 10: Final Acceptance Pass and Documentation

**Files:**
- Modify: `README.md`
- Create: `docs/mvp-qa.md`

- [ ] **Step 1: Update README with usage**

Replace `README.md` with:

```markdown
# HTMLGraph

HTMLGraph is a macOS-first desktop viewer for local HTML knowledge vaults.

## MVP

- Open a local folder of `.html` / `.htm` files.
- Read HTML documents in a three-pane workspace.
- Build graph edges from local `<a href>` links.
- Show backlinks for the active document.
- Show local and global graph views.
- Keep the source vault read-only.

## Development

```bash
swift test
swift run HTMLGraph
```

## Manual QA Fixture

Open `Fixtures/sample-vault` from the app.

Expected:
- `HTMLGraph Home` appears in the reader.
- Clicking `Graph note` navigates inside the app.
- `Graph View` shows a backlink from `index.html`.
- `Orphan` has no backlinks.
- `Broken local link` appears under unresolved links.
```

- [ ] **Step 2: Add manual QA checklist**

Create `docs/mvp-qa.md`:

```markdown
# HTMLGraph MVP QA

Use `Fixtures/sample-vault`.

- [ ] App opens on macOS with `swift run HTMLGraph`.
- [ ] `Open Vault` accepts `Fixtures/sample-vault`.
- [ ] Sidebar lists six HTML documents.
- [ ] Selecting `HTMLGraph Home` renders the HTML document.
- [ ] Local HTML link clicks navigate inside the app.
- [ ] External links open in the default browser.
- [ ] Backlinks tab updates when the active document changes.
- [ ] Unresolved tab shows `./notes/missing.html` for `HTMLGraph Home`.
- [ ] Local graph shows active document and linked neighbors.
- [ ] `Cmd+G` opens the global graph window.
- [ ] Safe mode is selected by default.
- [ ] Trusted mode can be selected per vault.
- [ ] Source vault remains unchanged after browsing.
- [ ] `swift test` passes.
```

- [ ] **Step 3: Run automated verification**

Run:

```bash
swift test
swift build
```

Expected: both pass.

- [ ] **Step 4: Run manual verification**

Run:

```bash
swift run HTMLGraph
```

Expected: all items in `docs/mvp-qa.md` pass.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/mvp-qa.md
git commit -m "docs: add HTMLGraph MVP usage and QA checklist"
```

## Self-Review Checklist

- Spec coverage:
  - macOS-first app: Tasks 1, 6, 8.
  - HTML vault indexing: Tasks 2, 3, 4.
  - Link/backlink model: Tasks 3, 4.
  - Three-pane UI: Task 6.
  - Local/global graph: Task 8.
  - Safe/Trusted policy model: Tasks 5, 9.
  - App cache: Task 5.
  - External editor: Task 6.
  - Sample fixture and testing: Tasks 2, 3, 4, 5, 10.
- MVP completeness check:
  - Unresolved links are shown in Task 6.
  - Trusted Mode is user-selectable in Task 9.
  - Network access remains separate from Trusted Mode in Task 9.
