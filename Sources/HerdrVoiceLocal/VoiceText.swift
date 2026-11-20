import Foundation

// Text rules for the voice loop, ported from OpenLive's `voiceText.ts` (pinned in scripts/local-openlive-setup):
// dropping silence hallucinations, spotting a mid-thought pause, cleaning text before speech, and chunking the
// reply stream into speakable pieces.

public enum VoiceText {
    /// Don't hand Kokoro a tiny fragment: short snippets render with an unstable timbre.
    public static let minChars = 40
    /// The first chunk of a reply speaks at a lower bar, so speech starts while the rest still streams.
    public static let firstChars = 24

    /// Transcripts a speech model invents for silence or noise. Real short answers ("okay", "no") are not here.
    static let hallucinations: Set<String> = [
        "", "you", "thank you", "thank you.", "thanks for watching", "thank you for watching", "thanks for watching!",
        "please subscribe", "subtitles by the amaraorg community",
    ]

    /// Words that, at the very end of an utterance, usually mean "I'm not done yet".
    static let trailing: Set<String> = [
        "to", "the", "a", "an", "and", "but", "so", "or", "of", "for", "with", "my", "your", "is", "are", "it", "that",
        "this", "on", "at", "in", "because", "if", "when", "then", "like", "about", "into", "um", "uh",
    ]

    static func words(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }.map(Character.init)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isJunk(_ text: String) -> Bool {
        let cleaned = words(text)
        return cleaned.count < 2 || hallucinations.contains(cleaned)
    }

    /// Digits count as words, so "set it to 250" ends on "250", not on the filler "to".
    public static func endsMidThought(_ text: String) -> Bool {
        guard let last = words(text).split(whereSeparator: \.isWhitespace).last else { return false }
        return trailing.contains(String(last))
    }

    private static let codeExtensions =
        "tsx?|jsx?|mjs|cjs|json|css|scss|less|html?|md|mdx|py|rs|go|rb|java|kt|swift|c|cc|cpp|h|hpp|sh|bash|zsh|yml|yaml|toml|xml|sql|php|lock|txt|csv|ipynb"

    /// Strips markdown, links, paths and filenames, so the voice never reads out symbols.
    public static func stripMarkdown(_ text: String) -> String {
        var s = text
        s = s.replacing(#"\[([^\]]+)\]\([^)]+\)"#, with: "$1")
        s = s.replacing(#"`([^`]*)`"#, with: "$1")
        s = s.replacing(#"[*_~#>]+"#, with: "")
        s = s.replacing(#"(?m)^\s*[-•]\s+"#, with: "")
        s = s.replacing(#"(?m)^\s*\d+\.\s+"#, with: "")
        s = s.replacing(#"(?i)\[p\.\s*\d+\]"#, with: "")
        s = s.replacing(#"(?i)[\[\]][a-z0-9~!]{0,3}[\[\]]"#, with: " ")
        s = s.replacing(#"[\[\]]"#, with: "")
        s = s.replacing(#"(?i)\bhttps?://\S+"#, with: "a link")
        s = s.replacing(#"/?(?:[\w.-]+/)+[\w-]+\.\w{1,6}\b"#, with: "that file")
        s = s.replacing(#"(?i)\b[\w-]+\.(?:\#(codeExtensions))\b"#, with: "that file")
        s = s.replacing(#"(?i)\bin (?:the|this|your) (?:image|photo|picture|frame)\b"#, with: "here")
        s = s.replacing(#"(?i)\b(?:the|this|that|your) (?:image|photo|picture|frame)\b"#, with: "this")
        s = s.replacing(#"([a-z])([.!?])([A-Z])"#, with: "$1$2 $3")
        s = s.replacing(#"\s+"#, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The complete sentences of `text`, dropping a trailing fragment ("I'm ready to help. Would").
    public static func heardSentences(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.firstMatch(#"^[\s\S]*[.!?]["'”’)\]]*(?=\s|$)"#) else { return "" }
        return match.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Splits a streamed reply into speakable chunks. Sentences shorter than `VoiceText.minChars` are merged with the
/// next one, except the first chunk of a reply, which goes out at a clause boundary or after the opening words of a
/// long sentence so speech begins while the rest still streams. Fenced code blocks are never spoken.
public struct SentenceChunker {
    private var buffer = ""
    private var ready = ""
    private var started = false
    private var inFence = false
    private var backtickTail = ""

    public init() {}

    private mutating func stripFences(_ text: String) -> String {
        var s = backtickTail + text
        backtickTail = ""
        let tail = s.reversed().prefix { $0 == "`" }.count
        if tail > 0, tail < 3 {
            backtickTail = String(s.suffix(tail))
            s.removeLast(tail)
        }
        var out = ""
        while true {
            guard let range = s.range(of: "```") else {
                if !inFence { out += s }
                break
            }
            if !inFence { out += s[..<range.lowerBound] }
            inFence.toggle()
            s = String(s[range.upperBound...])
        }
        return out
    }

    public mutating func push(_ text: String) -> [String] {
        buffer += stripFences(text)
        var out: [String] = []
        if !started, ready.isEmpty, let first = takeFirst() {
            out.append(first)
            started = true
        }
        let pattern = try! NSRegularExpression(pattern: #"[^.!?]+[.!?]+(?:\s|$)"#)
        let ns = buffer as NSString
        var last = 0
        for match in pattern.matches(in: buffer, range: NSRange(location: 0, length: ns.length)) {
            ready += ns.substring(with: match.range)
            last = match.range.location + match.range.length
            let bar = started ? VoiceText.minChars : VoiceText.firstChars
            let trimmed = ready.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= bar {
                out.append(trimmed)
                ready = ""
                started = true
            }
        }
        if last > 0 { buffer = ns.substring(from: last) }
        return out
    }

    private mutating func takeFirst() -> String? {
        let s = buffer
        guard s.trimmingCharacters(in: .whitespacesAndNewlines).count >= VoiceText.firstChars else { return nil }
        let ns = s as NSString
        let clause = try! NSRegularExpression(pattern: #"^([\s\S]{12,}?[,;:—–])\s"#)
        if let match = clause.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            buffer = ns.substring(from: match.range.location + match.range.length)
            return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if String(s.prefix(90)).firstMatch(#"[.!?](\s|$)"#) != nil { return nil } // a full sentence ends soon
        let window = String(s.prefix(48))
        guard let space = window.lastIndex(of: " ") else { return nil }
        let offset = window.distance(from: window.startIndex, to: space)
        guard offset >= VoiceText.firstChars else { return nil }
        buffer = String(s.dropFirst(offset + 1))
        return String(window[..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ends the reply: returns what's left and resets, so the next reply gets its own fast first chunk.
    public mutating func flush() -> String {
        let tail = inFence ? "" : backtickTail
        let s = (ready + buffer + tail).trimmingCharacters(in: .whitespacesAndNewlines)
        self = SentenceChunker()
        return s
    }
}

extension String {
    func replacing(_ pattern: String, with template: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.stringByReplacingMatches(in: self, range: NSRange(location: 0, length: (self as NSString).length),
                                              withTemplate: template)
    }

    func firstMatch(_ pattern: String) -> String? {
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: self, range: NSRange(location: 0, length: (self as NSString).length)) else {
            return nil
        }
        return (self as NSString).substring(with: match.range)
    }
}
