import Foundation

/// Reads process facts for the liveness check. `LiveProcessProbe` (IslandIO) is the real one; tests inject fakes.
public protocol ProcessProbing: Sendable {
    func exists(_ pid: Int32) -> Bool
    func startTime(of pid: Int32) -> Date?
}

public enum RegistryLiveness {
    /// Allowed distance between the kernel start time and `procStart`. `ps` prints whole seconds.
    private static let startTolerance: TimeInterval = 1

    /// Parses `ps -o lstart=` text ("EEE MMM d HH:mm:ss yyyy", English names as in en_US_POSIX, whitespace runs
    /// collapsed, surrounding whitespace ignored) in the local time zone.
    public static func parseProcStart(_ value: String) -> Date? {
        parseProcStart(value, timeZone: TimeZone.current)
    }

    /// Same text, interpreted in `timeZone`. Claude Code writes `procStart` as `ps -o lstart=` run with TZ=UTC,
    /// while `ps` in a login shell prints local time, so `isLive` accepts either reading.
    public static func parseProcStart(_ value: String, timeZone: TimeZone) -> Date? {
        let fields = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5,
              weekdays.contains(fields[0]),
              let monthIndex = months.firstIndex(of: fields[1]),
              let day = Int(fields[2]), (1...31).contains(day),
              let year = Int(fields[4]), (1970...9999).contains(year)
        else { return nil }
        let clock = fields[3].split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 3,
              clock.allSatisfy({ $0.count == 2 }),
              let hour = Int(clock[0]), (0...23).contains(hour),
              let minute = Int(clock[1]), (0...59).contains(minute),
              let second = Int(clock[2]), (0...59).contains(second)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: monthIndex + 1, day: day,
                                        hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day,
              calendar.component(.month, from: date) == monthIndex + 1
        else { return nil }
        return date
    }

    /// Live when the pid exists and its kernel start time is within 1 s of `procStart` read as UTC or as local
    /// time. No procStart, an unparseable one, or an unreadable start time is not live (pid reuse cannot be ruled
    /// out).
    public static func isLive(_ entry: RegistryEntry, probe: any ProcessProbing) -> Bool {
        guard let procStart = entry.procStart,
              probe.exists(entry.pid),
              let started = probe.startTime(of: entry.pid)
        else { return false }
        for zone in [utc, TimeZone.current] {
            if let expected = parseProcStart(procStart, timeZone: zone),
               abs(started.timeIntervalSince(expected)) <= startTolerance {
                return true
            }
        }
        return false
    }

    private static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
    private static let weekdays: Set<String> = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}
