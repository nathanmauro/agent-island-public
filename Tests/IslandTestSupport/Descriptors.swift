import Darwin
import Foundation

/// The number of file descriptors this process holds right now, from
/// proc_pidinfo(PROC_PIDLISTFDS). fd tests take a baseline first and compare.
public func openFileDescriptorCount() -> Int {
    let pid = getpid()
    let estimate = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard estimate > 0 else { return 0 }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(estimate) / stride + 16)
    let used = buffer.withUnsafeMutableBytes { bytes in
        proc_pidinfo(pid, PROC_PIDLISTFDS, 0, bytes.baseAddress, Int32(bytes.count))
    }
    guard used > 0 else { return 0 }
    return Int(used) / stride
}
