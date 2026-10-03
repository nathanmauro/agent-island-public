import Foundation

/// Every timing and size constant in one place (spec §5, §6, §7, §9).
/// Tasks never add constants here; a new shared constant goes back to the plan owner.
public enum IslandTiming {
    public static let blockedHold: TimeInterval = 1
    public static let episodeGap: TimeInterval = 10
    public static let chimeGap: TimeInterval = 3
    public static let quietPeriod: TimeInterval = 10
    public static let peekDuration: TimeInterval = 8
    public static let staleAfter: TimeInterval = 1_800
    public static let seenExpiry: TimeInterval = 43_200
    public static let herdrReconcile: TimeInterval = 12
    public static let herdrPing: TimeInterval = 30
    public static let herdrBackoff: [TimeInterval] = [0.5, 1, 2, 5]
    public static let herdrDisabledProbe: TimeInterval = 60
    public static let herdrExitGrace: TimeInterval = 1
    public static let herdrRequestTimeout: TimeInterval = 2
    public static let herdrMaxPaneStreams = 64
    public static let herdrMaxConcurrentRequests = 4
    public static let registrySweep: TimeInterval = 2
    public static let codexStatPoll: TimeInterval = 2
    public static let codexRecentWindow: TimeInterval = 86_400
    public static let codexFirstLineCap = 1_048_576
    public static let codexScanChunk = 262_144
    public static let codexMaxLineBytes = 1_048_576
    public static let displaySettle: TimeInterval = 0.35
    public static let chimeSoundName = "Glass"
    public static let chimeVolume: Float = 0.35
    public static let questionLogLimit = 200
    public static let logRotateBytes = 10_485_760
    public static let logKeepFiles = 3
    public static let boardHeightFraction: CGFloat = 0.6
    public static let compactRowHeight: CGFloat = 28
}
