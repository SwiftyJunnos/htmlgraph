import Foundation

/// Splices new `<body>` inner-HTML back into an original HTML document while preserving
/// everything outside the body — the doctype, the `<head>`, the `<body>` tag's own
/// attributes, and any trailing markup — byte-for-byte.
///
/// The WYSIWYG editor reads the edited body straight from the live DOM, which WebKit has
/// already re-serialized. Writing that DOM back wholesale would reformat the parts of the
/// file the user never touched (scripts, metadata, the head's original indentation).
/// Replacing only the body's inner range keeps the on-disk change as small as the edit.
///
/// Locating the body region by naive substring search is unsafe for arbitrary (often
/// AI-generated) HTML: a `<body>` literal can appear inside a comment, a `<script>`/`<style>`
/// raw-text block, or a `<title>`/`<textarea>`, and a document may omit the `<body>` tag
/// entirely (it is implied). A wrong match here silently destroys the file on save. So the
/// scanner below skips comments and raw/escapable-text elements and matches only real tags;
/// when it cannot confidently find a real `<body>…</body>` it returns nil, and the caller
/// must fall back to a non-destructive whole-document write rather than guessing.
public enum HTMLBodyReplacer {
    /// Returns `original` with the content between its real `<body …>` open tag and its real
    /// `</body>` close tag replaced by `newBodyInnerHTML`. Returns nil when no real body
    /// element can be located (an implied body, a body literal that only appears inside
    /// comments/scripts, or a missing close tag) — the caller must NOT write a bare fragment
    /// in that case.
    public static func replacingBodyInner(of original: String, with newBodyInnerHTML: String) -> String? {
        let chars = Array(original)
        guard let innerStart = bodyOpenInnerStart(in: chars),
              let closeStart = bodyCloseStart(in: chars, from: innerStart) else {
            return nil
        }
        return String(chars[0..<innerStart]) + newBodyInnerHTML + String(chars[closeStart..<chars.count])
    }

    /// Elements whose text content must be treated as opaque while scanning for the body:
    /// raw-text (`script`, `style`) and escapable-raw-text/RCDATA (`title`, `textarea`)
    /// elements can contain a literal `<body>`/`</body>` that is NOT a tag.
    private static let opaqueElements = ["script", "style", "title", "textarea"]

    /// Index just past the `>` of the first real `<body>` start tag, skipping comments,
    /// declarations/CDATA, processing instructions, opaque elements, and ANY other tag's body
    /// (so a `<body>` literal inside another element's attribute value is not mistaken for
    /// it). Nil if there is no real `<body>` tag.
    private static func bodyOpenInnerStart(in c: [Character]) -> Int? {
        var i = 0
        let n = c.count
        while i < n {
            guard c[i] == "<" else { i += 1; continue }
            if let skipped = afterMarkupPrefix(c, i) {
                i = skipped
            } else if isTag(c, i, "body") {
                return endOfOpenTag(c, from: i)
            } else if let skipped = afterGenericTag(c, i) {
                i = skipped
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Index of the `<` of the first real `</body>` end tag at/after `start`, skipping the
    /// same constructs as the open scan. The first real one is the body's own close — body
    /// content cannot legitimately contain another real `</body>` end tag (one inside a
    /// comment, script, or another tag's attribute is skipped).
    private static func bodyCloseStart(in c: [Character], from start: Int) -> Int? {
        var i = start
        let n = c.count
        while i < n {
            guard c[i] == "<" else { i += 1; continue }
            if let skipped = afterMarkupPrefix(c, i) {
                i = skipped
            } else if isCloseTag(c, i, "body") {
                return i
            } else if let skipped = afterGenericTag(c, i) {
                i = skipped
            } else {
                i += 1
            }
        }
        return nil
    }

    // MARK: - Tag scanning helpers

    /// If `<` at `i` opens a comment (`<!-- … -->`), a declaration / CDATA (`<! … >`), a
    /// processing instruction / bogus comment (`<? … >`), or an opaque element
    /// (script/style/title/textarea), returns the index just past it. Nil otherwise.
    /// Declarations and PIs are terminated by the first `>`, matching how HTML tokenizes a
    /// bogus comment — so a `</body>` inside `<![CDATA[ … ]]>` ends that construct rather than
    /// being seen as a real tag.
    private static func afterMarkupPrefix(_ c: [Character], _ i: Int) -> Int? {
        if startsWith(c, i, "<!--") { return afterSequence(c, from: i + 4, "-->") }
        guard i + 1 < c.count else { return nil }
        if c[i + 1] == "!" || c[i + 1] == "?" { return afterChar(c, from: i + 1, ">") }
        return afterOpaqueElement(c, at: i)
    }

    /// If `<` at `i` begins an ordinary start tag (`<x…`) or end tag (`</x…`), returns the
    /// index just past its `>` (quote-aware, so a `>` inside an attribute can't end it early).
    /// Nil when `<` is plain text (e.g. `a < b`), which the caller then steps over by one.
    private static func afterGenericTag(_ c: [Character], _ i: Int) -> Int? {
        guard i + 1 < c.count else { return nil }
        let next = c[i + 1]
        if next.isLetter { return endOfOpenTag(c, from: i) }
        if next == "/", i + 2 < c.count, c[i + 2].isLetter { return endOfOpenTag(c, from: i) }
        return nil
    }

    /// If an opaque element opens at `i` (`<script…>`, `<style…>`, `<title…>`, `<textarea…>`),
    /// returns the index just past its closing tag (or end-of-input if unterminated); else nil.
    private static func afterOpaqueElement(_ c: [Character], at i: Int) -> Int? {
        for name in opaqueElements where isTag(c, i, name) {
            let afterOpen = endOfOpenTag(c, from: i)
            return afterCloseTag(c, from: afterOpen, name)
        }
        return nil
    }

    /// True when a real start tag `<name` (case-insensitive) opens at `i` — i.e. the chars
    /// after the name are a tag delimiter (`>`, `/`, or whitespace), so `<bodyguard` and
    /// `<scripting` don't match.
    private static func isTag(_ c: [Character], _ i: Int, _ name: String) -> Bool {
        let name = Array(name)
        guard i + 1 + name.count <= c.count else { return false }
        guard matchesCaseInsensitive(c, i + 1, name) else { return false }
        let after = i + 1 + name.count
        return after == c.count || isDelimiter(c[after])
    }

    /// True when a real end tag `</name` (case-insensitive) opens at `i`.
    private static func isCloseTag(_ c: [Character], _ i: Int, _ name: String) -> Bool {
        let name = Array(name)
        guard i + 2 + name.count <= c.count, c[i + 1] == "/" else { return false }
        guard matchesCaseInsensitive(c, i + 2, name) else { return false }
        let after = i + 2 + name.count
        return after == c.count || isDelimiter(c[after])
    }

    private static func isDelimiter(_ ch: Character) -> Bool {
        ch == ">" || ch == "/" || ch.isWhitespace
    }

    /// Index just past the `>` that closes the tag opening at `tagStart`, scanning through
    /// quoted attribute values so a `>` inside an attribute can't end the tag early. Falls
    /// back to end-of-input if the tag is never closed.
    private static func endOfOpenTag(_ c: [Character], from tagStart: Int) -> Int {
        var i = tagStart
        var quote: Character?
        while i < c.count {
            let ch = c[i]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ">" {
                return i + 1
            }
            i += 1
        }
        return c.count
    }

    /// Index just past the `>` of the next real `</name>` end tag at/after `from`, or
    /// end-of-input. Used to skip an opaque element's body.
    private static func afterCloseTag(_ c: [Character], from: Int, _ name: String) -> Int {
        var i = from
        while i < c.count {
            if c[i] == "<", isCloseTag(c, i, name) {
                return endOfOpenTag(c, from: i)
            }
            i += 1
        }
        return c.count
    }

    private static func startsWith(_ c: [Character], _ i: Int, _ literal: String) -> Bool {
        let lit = Array(literal)
        guard i + lit.count <= c.count else { return false }
        for k in 0..<lit.count where c[i + k] != lit[k] { return false }
        return true
    }

    /// Index just past the next occurrence of `seq` at/after `from`, or end-of-input.
    private static func afterSequence(_ c: [Character], from: Int, _ seq: String) -> Int {
        let s = Array(seq)
        guard !s.isEmpty else { return from }
        var i = from
        while i + s.count <= c.count {
            var matched = true
            for k in 0..<s.count where c[i + k] != s[k] { matched = false; break }
            if matched { return i + s.count }
            i += 1
        }
        return c.count
    }

    /// Index just past the next `ch` at/after `from`, or end-of-input.
    private static func afterChar(_ c: [Character], from: Int, _ ch: Character) -> Int {
        var i = from
        while i < c.count {
            if c[i] == ch { return i + 1 }
            i += 1
        }
        return c.count
    }

    private static func matchesCaseInsensitive(_ c: [Character], _ at: Int, _ lowercased: [Character]) -> Bool {
        for k in 0..<lowercased.count where Character(c[at + k].lowercased()) != lowercased[k] {
            return false
        }
        return true
    }
}
