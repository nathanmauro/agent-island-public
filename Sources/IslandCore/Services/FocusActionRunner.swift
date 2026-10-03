import Foundation
import Darwin

public enum FocusAction: Equatable, Sendable {
    case run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    )
    case appleScript(String)

    /// Construction helper for tmux-style actions that carry no environment
    /// overrides.
    public static func run(executable: String, arguments: [String]) -> FocusAction {
        .run(executable: executable, arguments: arguments, environment: [:])
    }
}

public enum FocusError: Error, Equatable, Sendable {
    case commandFailed(String, Int32)
}

/// Quotes a value for embedding inside an AppleScript string literal.
package enum AppleScriptText {
    package static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

/// Executes planned terminal actions — subprocess or AppleScript. Every
/// action runs even after an earlier one fails, so a dead tmux target never
/// blocks the activation behind it; the first failure is still reported.
/// Synchronous with a 10 s bound per action: callers on the main actor must
/// go through an off-main runner.
package enum FocusActionRunner {
    package static func run(_ actions: [FocusAction]) throws {
        var firstError: Error?
        for action in actions {
            do {
                let resolvedExecutableURL: URL
                let arguments: [String]
                let environment: [String: String]
                switch action {
                case let .run(executable, actionArguments, overrides):
                    resolvedExecutableURL = try executableURL(named: executable)
                    arguments = actionArguments
                    environment = overrides
                case let .appleScript(script):
                    resolvedExecutableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    arguments = ["-e", script]
                    environment = [:]
                }
                let result = try BoundedProcessRunner.run(
                    executableURL: resolvedExecutableURL,
                    arguments: arguments,
                    environment: environment,
                    timeout: 10
                )
                if result.status != 0, firstError == nil {
                    firstError = FocusError.commandFailed(
                        resolvedExecutableURL.path,
                        result.status
                    )
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private static func executableURL(named executable: String) throws -> URL {
        if executable.hasPrefix("/") {
            return URL(fileURLWithPath: executable)
        }
        for directory in trustedDirectories(for: executable) {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(executable)
                .resolvingSymlinksInPath()
            var metadata = stat()
            guard Darwin.lstat(candidate.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_mode & 0o022 == 0,
                  metadata.st_uid == 0 || metadata.st_uid == getuid(),
                  FileManager.default.isExecutableFile(atPath: candidate.path) else {
                continue
            }
            return candidate
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Herdr and Orca document an `~/.local/bin` fallback. Keep user-writable
    /// lookup scoped to those integrations so it cannot silently broaden
    /// established command execution. Herdr also supports its documented mise
    /// and Nix shim locations.
    package static func trustedDirectories(for executable: String) -> [String] {
        let systemDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ]
        guard executable == "herdr" || executable == "orca" else { return systemDirectories }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let userLocalDirectory = "\(home)/.local/bin"
        guard executable == "herdr" else {
            return systemDirectories + [userLocalDirectory]
        }
        return systemDirectories + [
            userLocalDirectory,
            "\(home)/.local/share/mise/shims",
            "\(home)/.nix-profile/bin",
        ]
    }
}
