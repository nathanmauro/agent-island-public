// ProcessSampler.swift: CPU and open-file sampling for the soak step (spec §12.3 step 4), plus the
// small subprocess helper the driver shares.
import Foundation

struct CommandResult: Equatable {
    let status: Int32
    let output: String
}

struct SoakSample: Equatable {
    let cpuPercent: Double
    let openFiles: Int
}

struct SoakVerdict: Equatable {
    let averageCPU: Double
    let minFiles: Int
    let maxFiles: Int
    let passed: Bool
    let summary: String
}

enum ProcessSampler {
    /// Runs a command to completion. stderr goes to /dev/null unless includeStandardError merges it into output.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                    includeStandardError: Bool = false) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        if includeStandardError {
            process.standardError = pipe
        } else {
            process.standardError = FileHandle.nullDevice
        }
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: "could not run \(executable): \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// `ps -o %cpu=`: macOS reports a decaying recent average, so the soak settles 15 s before sampling.
    static func cpuPercent(pid: pid_t) -> Double? {
        let result = run("/bin/ps", ["-o", "%cpu=", "-p", String(pid)], environment: ["LC_ALL": "C"])
        guard result.status == 0 else { return nil }
        return Double(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `ps -o time=`: cumulative CPU time, reported next to the %cpu verdict for context.
    static func cpuTimeSeconds(pid: pid_t) -> Double? {
        let result = run("/bin/ps", ["-o", "time=", "-p", String(pid)], environment: ["LC_ALL": "C"])
        guard result.status == 0 else { return nil }
        return parseCPUTime(result.output)
    }

    /// `lsof -p` line count minus the header.
    static func openFileCount(pid: pid_t) -> Int? {
        let result = run("/usr/sbin/lsof", ["-n", "-P", "-p", String(pid)], environment: ["LC_ALL": "C"])
        guard result.status == 0 else { return nil }
        let lines = result.output.split(separator: "\n")
        return lines.isEmpty ? nil : lines.count - 1
    }

    /// "m:ss.ss", "mmm:ss.ss" or "h:mm:ss.ss" → seconds.
    static func parseCPUTime(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        var multiplier = 1.0
        for part in parts.reversed() {
            guard let value = Double(part) else { return nil }
            total += value * multiplier
            multiplier *= 60
        }
        return total
    }

    /// Spec §12.3: idle average %cpu < 1.0 and max − min of the lsof count ≤ 2.
    static func evaluate(_ samples: [SoakSample], cpuLimit: Double = 1.0, fileSpreadLimit: Int = 2) -> SoakVerdict {
        let files = samples.map(\.openFiles)
        guard samples.count >= 2, let minFiles = files.min(), let maxFiles = files.max() else {
            return SoakVerdict(averageCPU: samples.first?.cpuPercent ?? 0, minFiles: files.first ?? 0,
                               maxFiles: files.first ?? 0, passed: false,
                               summary: "\(samples.count) sample(s); a soak needs at least 2")
        }
        let average = samples.map(\.cpuPercent).reduce(0, +) / Double(samples.count)
        let spread = maxFiles - minFiles
        let passed = average < cpuLimit && spread <= fileSpreadLimit
        let summary = "\(samples.count) samples, average %cpu " + String(format: "%.2f", average)
            + " (limit < \(cpuLimit)), lsof count \(minFiles)-\(maxFiles) (spread \(spread), limit \(fileSpreadLimit))"
        return SoakVerdict(averageCPU: average, minFiles: minFiles, maxFiles: maxFiles, passed: passed, summary: summary)
    }
}
