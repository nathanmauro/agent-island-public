import Foundation
import IslandCore
import IslandTestSupport

// Expected strings are the masked fixture text (pseudo-words), never raw session text.

private let detectionForbiddenQuestionCharacters: [Character] = ["│", "❯", "─", "←", "→", "☐", "✔"]

private func detectionPrompt(_ fixture: String) throws -> Prompt {
    guard let prompt = DetectionTextParser.parseBlocked(try Fixtures.string(fixture)) else {
        throw TestFailure.expectation("\(fixture): parseBlocked returned nil")
    }
    try expectTrue(!prompt.question.isEmpty, "\(fixture): question is non-empty")
    for character in detectionForbiddenQuestionCharacters {
        try expectTrue(!prompt.question.contains(character), "\(fixture): question contains \(character)")
    }
    try expectTrue(prompt.options.count <= DetectionTextParser.maxOptions, "\(fixture): at most four options")
    return prompt
}

func testDetectionConstants() throws {
    try expect(DetectionTextParser.maxOptions, equals: 4, "maxOptions")
    try expect(DetectionTextParser.optionPattern, equals: #"^\s*(❯\s*)?\d+\.\s"#, "optionPattern")
}

func testDetectionParsesFirstBlockedFixture() throws {
    let prompt = try detectionPrompt("herdr/detection-blocked-1.txt")
    try expect(prompt.question,
               equals: "Aliqua sit sunt Ipsum nisi elit id Irure Eiusmod, laborum Minim. Sed cillum sit cillum cillum do?",
               "question: the two │ lines between the tab chips and option 1, joined")
    try expect(prompt.options, equals: [
        "Velit Dolor Aliquip est (Consectetur)",
        "Magna sint; I'a dolore Magna elit Velit",
        "Lorem sint; laborum Ipsum Laborum aliqua",
        "Duis excepteur.",
    ], "the four numbered options above the bottom rule; descriptions and option 5 excluded")
}

func testDetectionParsesSecondBlockedFixture() throws {
    let prompt = try detectionPrompt("herdr/detection-blocked-2.txt")
    try expect(prompt.question, equals: "Magna irure ex sed sunt Veniam ad nulla sed non?", "question")
    try expect(prompt.options, equals: [
        "Fugiat non, fugiat enim-culpa (Consectetur)",
        "Officia Dolor anim non",
        "Duis qui duis-magna amet",
        "Duis excepteur.",
    ], "options")
}

func testDetectionParsesRecapWithContinuations() throws {
    let text = try Fixtures.string("herdr/detection-done-1.txt")
    try expect(DetectionTextParser.parseRecap(text),
               equals: "Quis est commodo Lorem tempor ad labore esse ut enim ad est sint'e deserunt consequat; amet'a anim, qui sint quis in qui labore in consectetur Elit tempor in Veniam (SIT-777, EST-777). Sunt: lorem qui anim dolor tempor dolor ex i sed. (ullamco dolore    +7 dolor fugiat cillum amet officia (aute) ex /aliqua)",
               "the ※ recap: line plus its indented continuation lines, trimmed and joined")
    try expect(DetectionTextParser.parseBlocked(text), equals: nil, "a finished turn is not a prompt")
}

func testDetectionRecapFallsBackToLastParagraph() throws {
    let text = try Fixtures.string("herdr/detection-recap-fallback.txt")
    try expect(DetectionTextParser.parseRecap(text),
               equals: "Fixture paragraph two is the final summary of the turn. All fixture checks passed and nothing else is pending.",
               "last ⏺ paragraph")
    try expect(DetectionTextParser.parseBlocked(text), equals: nil, "no prompt")
}

func testDetectionGarbageAndEmptyReturnNil() throws {
    let garbage = try Fixtures.string("herdr/detection-garbage.txt")
    try expect(DetectionTextParser.parseBlocked(garbage), equals: nil, "garbage: no prompt")
    try expect(DetectionTextParser.parseRecap(garbage), equals: nil, "garbage: no recap")
    try expect(DetectionTextParser.parseBlocked(""), equals: nil, "empty: no prompt")
    try expect(DetectionTextParser.parseRecap(""), equals: nil, "empty: no recap")
}

func testDetectionPermissionPromptWithoutBottomRule() throws {
    let text = """
    ⏺ Fixture tool call
    ────────────────────────────────────────
     Fixture command

       fixture-tool --dry-run

     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and do not ask again for fixture-tool
       3. No, and tell the agent what to do differently (esc)

     Esc to cancel
    """
    let prompt = try detectionParsedPrompt(text)
    try expect(prompt.question, equals: "Fixture command fixture-tool --dry-run Do you want to proceed?", "question")
    try expect(prompt.options, equals: [
        "Yes", "Yes, and do not ask again for fixture-tool", "No, and tell the agent what to do differently (esc)",
    ], "options")
}

func testDetectionCapsOptionsAtFour() throws {
    let text = """
    ────────────────────
    Pick a fixture color?

    ❯ 1. Red
      2. Green
      3. Blue
      4. Cyan
      5. Magenta
      6. Yellow
    ────────────────────
    """
    try expect(try detectionParsedPrompt(text).options, equals: ["Red", "Green", "Blue", "Cyan"], "first four options")
}

func testDetectionNeedsABoundaryAndAQuestion() throws {
    let noBoundary = """
    Pick a fixture color?
    ❯ 1. Red
      2. Green
    """
    try expect(DetectionTextParser.parseBlocked(noBoundary), equals: nil, "no rule or tab chip above the options")
    let noQuestion = """
    ────────────────────
    ❯ 1. Red
      2. Green
    ────────────────────
    """
    try expect(DetectionTextParser.parseBlocked(noQuestion), equals: nil, "no question text above the first option")
}

private func detectionParsedPrompt(_ text: String) throws -> Prompt {
    guard let prompt = DetectionTextParser.parseBlocked(text) else {
        throw TestFailure.expectation("parseBlocked returned nil for a synthetic prompt")
    }
    return prompt
}

func testDetectionReplayFixturesAreWellFormed() throws {
    let allowedOps: Set<String> = ["state", "status", "created", "closed", "reconnect"]
    for name in ["replay-sub2", "replay-poll"] {
        let lines = try Fixtures.string("herdr/\(name).jsonl").split(separator: "\n")
        try expectTrue(!lines.isEmpty, "\(name).jsonl is non-empty")
        let objects = try lines.map { line -> [String: Any] in
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] ?? [:]
        }
        let ops = objects.map { $0["op"] as? String ?? "" }
        try expect(ops.first, equals: "state", "\(name).jsonl starts with a state op")
        try expectTrue(ops.allSatisfy { allowedOps.contains($0) }, "\(name).jsonl: only allowed ops")
        // Known-pane rule: a created op never names a pane the replay already knows, so a replay driver can start
        // every created pane idle. Known = the last state op's panes, plus later created, minus later closed.
        var known = Set<String>()
        for (index, object) in objects.enumerated() {
            let paneID = object["pane_id"] as? String ?? ""
            switch object["op"] as? String {
            case "state":
                known = Set(((object["panes"] as? [[String: Any]]) ?? []).compactMap { $0["pane_id"] as? String })
            case "created":
                try expectTrue(!known.contains(paneID), "\(name).jsonl line \(index + 1): created names known pane \(paneID)")
                known.insert(paneID)
            case "closed":
                known.remove(paneID)
            default:
                break
            }
        }
    }
}

func testDetectionReplayGoldensAreSummaryTimelines() throws {
    let pattern = #"^(\(none\)|\d+ (error|waiting|working|done)( · \d+ (error|waiting|working|done))*)$"#
    for name in ["replay-sub2", "replay-poll"] {
        let lines = try Fixtures.string("herdr/\(name).expected.txt").split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).filter { !$0.isEmpty }
        try expectTrue(!lines.isEmpty, "\(name).expected.txt is non-empty")
        for (index, line) in lines.enumerated() {
            try expectTrue(line.range(of: pattern, options: .regularExpression) != nil, "\(name) line \(index + 1) is Summary.text shaped")
            if index > 0 {
                try expectTrue(line != lines[index - 1], "\(name) line \(index + 1) repeats the previous line")
            }
        }
    }
}

let detectionParserTests: [TestCase] = [
    ("detection: constants", testDetectionConstants),
    ("detection: parses the first blocked fixture", testDetectionParsesFirstBlockedFixture),
    ("detection: parses the second blocked fixture", testDetectionParsesSecondBlockedFixture),
    ("detection: parses the recap with continuation lines", testDetectionParsesRecapWithContinuations),
    ("detection: recap falls back to the last paragraph", testDetectionRecapFallsBackToLastParagraph),
    ("detection: garbage and empty text return nil", testDetectionGarbageAndEmptyReturnNil),
    ("detection: permission prompt without a bottom rule", testDetectionPermissionPromptWithoutBottomRule),
    ("detection: caps options at four", testDetectionCapsOptionsAtFour),
    ("detection: needs a boundary and a question", testDetectionNeedsABoundaryAndAQuestion),
    ("detection: replay fixtures are well formed", testDetectionReplayFixturesAreWellFormed),
    ("detection: replay goldens are Summary.text timelines", testDetectionReplayGoldensAreSummaryTimelines),
]
