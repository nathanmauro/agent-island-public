import Darwin

/// The machine's short host name, as Herdr writes it into its default Ghostty window title.
public enum HostName {
    public static func short() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "localhost" }
        let full = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let short = full.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? full
        return short.isEmpty ? "localhost" : short
    }
}
