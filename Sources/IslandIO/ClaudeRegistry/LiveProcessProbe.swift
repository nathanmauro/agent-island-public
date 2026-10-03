import Darwin
import Foundation
import IslandCore

/// kill(pid, 0) for existence (EPERM still means the process exists; a zombie does not count) and
/// proc_pidinfo(PROC_PIDTBSDINFO) for the kernel start time.
public struct LiveProcessProbe: ProcessProbing {
    public init() {}

    public func exists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) != 0, errno != EPERM { return false }
        guard let info = Self.bsdInfo(pid) else { return true }
        return info.pbi_status != UInt32(SZOMB)
    }

    public func startTime(of pid: Int32) -> Date? {
        guard pid > 0, let info = Self.bsdInfo(pid) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
}
