import Foundation

/// Post-processes a Parakeet transcription against a vocab list:
///   1. Snippet replacement: any `from → to` entry is rewritten verbatim
///      (case-insensitive match, single or multi-word).
///   2. Casing fixup: any plain-word entry forces the canonical casing on
///      matches in the output ("heltra" → "Heltra").
///   3. Fuzzy phonetic match: for each output word that doesn't already
///      match a vocab entry, check if it's phonetically close to a vocab
///      word (edit distance ≤ 2 + same starting consonant). If yes, replace.
///      This catches "kulsin"/"coalsin" → "Culsin", "thermo wave" → "thermowave",
///      etc.
enum VocabCorrector {
    static func correct(text: String, entries: [VocabEntry]) -> String {
        guard !text.isEmpty, !entries.isEmpty else { return text }

        var result = text

        // Step 1 — explicit snippet replacements (multi-word OK).
        // Sort by source length descending so longer matches win first.
        let snippets = entries
            .filter { $0.isSnippet }
            .sorted { $0.source.count > $1.source.count }
        for entry in snippets {
            result = replaceTokenCaseInsensitive(in: result, from: entry.source, to: entry.canonical)
        }

        // Step 2 — casing fixup for plain entries.
        let plain = entries.filter { !$0.isSnippet }
        for entry in plain {
            result = replaceTokenCaseInsensitive(in: result, from: entry.source, to: entry.canonical)
        }

        // Step 3 — fuzzy match for any remaining tokens.
        result = fuzzyReplace(in: result, against: plain.map(\.canonical))

        return result
    }

    // MARK: - Token-level replacement

    /// Replace every word-boundary occurrence of `from` with `to`, case-insensitive.
    /// Word boundary = preceded and followed by a non-alphanumeric (or string edge).
    static func replaceTokenCaseInsensitive(in text: String, from: String, to: String) -> String {
        guard !from.isEmpty else { return text }
        let escaped = NSRegularExpression.escapedPattern(for: from)
        // Use \b for ASCII alpha boundaries; that's fine for our vocab.
        let pattern = "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: NSRegularExpression.escapedTemplate(for: to)
        )
    }

    // MARK: - Fuzzy phonetic match

    static func fuzzyReplace(in text: String, against vocab: [String]) -> String {
        guard !vocab.isEmpty else { return text }

        // Pre-compute phonetic keys for the vocab.
        let entries = vocab.map { ($0, phoneticKey($0), $0.lowercased()) }

        // Tokenise preserving whitespace and punctuation.
        var output = ""
        var current = ""
        func flush() {
            if current.isEmpty { return }
            if let replacement = bestMatch(for: current, in: entries) {
                output += preserveCasingShape(of: current, replacement: replacement)
            } else {
                output += current
            }
            current = ""
        }
        for ch in text {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else {
                flush()
                output.append(ch)
            }
        }
        flush()
        return output
    }

    private static func bestMatch(
        for token: String,
        in entries: [(String, String, String)]
    ) -> String? {
        if token.count < 4 { return nil } // too short to fuzzy-match safely
        let tokenLower = token.lowercased()
        let tokenKey = phoneticKey(token)
        var best: (String, Int)?
        for (canonical, key, canonicalLower) in entries {
            if tokenLower == canonicalLower { return nil } // already correct
            guard !key.isEmpty, !tokenKey.isEmpty else { continue }
            // require same first letter — avoids "node" matching "code"
            if tokenLower.first != canonicalLower.first { continue }
            let lenDiff = abs(tokenLower.count - canonicalLower.count)
            if lenDiff > 3 { continue }
            let dist = levenshtein(tokenLower, canonicalLower)
            // tolerance grows with word length
            let maxDist = max(1, canonicalLower.count / 4)
            if dist <= maxDist {
                if best == nil || dist < best!.1 {
                    best = (canonical, dist)
                }
                continue
            }
            // also accept identical phonetic key with small distance
            if key == tokenKey && dist <= maxDist + 1 {
                if best == nil || dist < best!.1 {
                    best = (canonical, dist)
                }
            }
        }
        return best?.0
    }

    /// Match the visual casing of the source token onto the replacement when
    /// possible. "Heltra" stays "Heltra" if user said it sentence-initial;
    /// "HELTRA" → "HELTRA". Otherwise return canonical form.
    static func preserveCasingShape(of source: String, replacement: String) -> String {
        if source == source.uppercased() && source.count > 1 {
            return replacement.uppercased()
        }
        if let first = source.first, first.isUppercase, replacement.first?.isLowercase == true {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    // MARK: - Phonetic key (lightweight Soundex-style)

    static func phoneticKey(_ word: String) -> String {
        let lower = word.lowercased()
        guard let first = lower.first else { return "" }

        var key = String(first)
        var lastCode: Character = " "
        for ch in lower.dropFirst() {
            let code: Character
            switch ch {
            case "b", "f", "p", "v": code = "1"
            case "c", "g", "j", "k", "q", "s", "x", "z": code = "2"
            case "d", "t": code = "3"
            case "l": code = "4"
            case "m", "n": code = "5"
            case "r": code = "6"
            default: continue
            }
            if code != lastCode {
                key.append(code)
                lastCode = code
            }
        }
        return String(key.prefix(6))
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var curr = Array(repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,        // deletion
                    curr[j - 1] + 1,    // insertion
                    prev[j - 1] + cost  // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }
}
