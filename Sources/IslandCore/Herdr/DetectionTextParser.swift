import Foundation

/// A blocked agent's question and up to four option labels, parsed from a detection read.
public struct Prompt: Equatable, Sendable {
    public let question: String
    /// At most `DetectionTextParser.maxOptions` labels: the first line of each option, "❯" and "N. " stripped.
    public let options: [String]

    public init(question: String, options: [String]) {
        self.question = question
        self.options = options
    }
}

/// Parses Herdr `agent.read` detection text (the bottom ~65 lines of a Claude pane). Pure: no I/O.
///
/// Blocked prompt layout, top to bottom:
///   rule ─────  /  tab-chip line "←  ☐ …  ✔ …  →"   (the top boundary; either one)
///   question lines (possibly prefixed with "│")
///   "❯ 1. label" / "  2. label" option lines, each optionally followed by indented description lines
///   rule ─────                                       (bottom boundary, may be absent)
///   more lines (an extra "5. …" option below the rule, a footer) that are not part of the prompt
/// The parser works bottom-up: it takes the lowest region that starts right below a boundary line and
/// holds option lines with non-empty question text above the first option.
public enum DetectionTextParser {
    public static let maxOptions = 4
    public static let optionPattern = #"^\s*(❯\s*)?\d+\.\s"#

    private static let optionPrefixPattern = #"^\s*(❯\s*)?\d+\.\s+"#
    private static let ruleCharacters: Set<Character> = ["─", "━", "═"]
    private static let questionEdgeCharacters: Set<Character> = ["│", "┃", "▎"]
    private static let paragraphMarkers: [String] = ["⏺", "✻", "※", "⎿", "❯", "│", "▎"]

    public static func parseBlocked(_ text: String) -> Prompt? {
        let lines = text.components(separatedBy: "\n")
        let boundaries = lines.indices.filter { isRule(lines[$0]) || isTabChip(lines[$0]) }
        for (position, boundary) in boundaries.enumerated().reversed() {
            let start = boundary + 1
            let end = position + 1 < boundaries.count ? boundaries[position + 1] : lines.count
            guard start < end else { continue }
            let region = Array(lines[start..<end])
            guard let firstOption = region.firstIndex(where: isOption) else { continue }
            let question = region[..<firstOption]
                .map(questionText)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !question.isEmpty else { continue }
            let options = region[firstOption...]
                .filter(isOption)
                .prefix(maxOptions)
                .map(optionLabel)
            return Prompt(question: question, options: Array(options))
        }
        return nil
    }

    /// The text after "※ recap:" plus its indented continuation lines; otherwise the last "⏺" paragraph.
    public static func parseRecap(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        if let recapIndex = lines.lastIndex(where: { trimmed($0).hasPrefix("※ recap:") }) {
            var parts = [String(trimmed(lines[recapIndex]).dropFirst("※ recap:".count))]
            var index = recapIndex + 1
            while index < lines.count, let first = lines[index].first, first == " " || first == "\t",
                  !trimmed(lines[index]).isEmpty {
                parts.append(lines[index])
                index += 1
            }
            let recap = joinedTrimmed(parts)
            if !recap.isEmpty { return recap }
        }
        guard let markerIndex = lines.lastIndex(where: { trimmed($0).hasPrefix("⏺") }) else { return nil }
        var parts = [String(trimmed(lines[markerIndex]).dropFirst())]
        var index = markerIndex + 1
        while index < lines.count {
            let line = trimmed(lines[index])
            if line.isEmpty || isRule(lines[index]) || paragraphMarkers.contains(where: { line.hasPrefix($0) }) { break }
            parts.append(line)
            index += 1
        }
        let paragraph = joinedTrimmed(parts)
        return paragraph.isEmpty ? nil : paragraph
    }

    // MARK: - Line classification

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    private static func joinedTrimmed(_ parts: [String]) -> String {
        parts.map(trimmed).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func isRule(_ line: String) -> Bool {
        let content = trimmed(line)
        return content.count >= 3 && content.allSatisfy { ruleCharacters.contains($0) }
    }

    private static func isTabChip(_ line: String) -> Bool {
        let content = trimmed(line)
        return content.contains("☐") || (content.hasPrefix("←") && content.hasSuffix("→"))
    }

    private static func isOption(_ line: String) -> Bool {
        line.range(of: optionPattern, options: .regularExpression) != nil
    }

    private static func optionLabel(_ line: String) -> String {
        trimmed(line.replacingOccurrences(of: optionPrefixPattern, with: "", options: .regularExpression))
    }

    private static func questionText(_ line: String) -> String {
        var content = Substring(trimmed(line))
        while let first = content.first, questionEdgeCharacters.contains(first) { content = content.dropFirst() }
        while let last = content.last, questionEdgeCharacters.contains(last) { content = content.dropLast() }
        return content.trimmingCharacters(in: .whitespaces)
    }
}
