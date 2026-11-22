import Foundation

#if !APP_STORE
enum LocalGitHubStar {
    struct Response: Sendable {
        let success: Bool
        let status: Int?
    }

    /// Complete once, even if a timed-out process exits after the timer fires.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Response?, Never>?
        init(_ continuation: CheckedContinuation<Response?, Never>) { self.continuation = continuation }
        func finish(_ result: Response?) {
            lock.lock()
            let previous = continuation
            continuation = nil
            lock.unlock()
            previous?.resume(returning: result)
        }
    }

    private static var installedCommand: URL? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    static func run(method: String) async -> Response? {
        await run(method: method, executable: installedCommand, timeout: 15)
    }

    static func run(method: String, executable: URL?, timeout: Double) async -> Response? {
        guard let executable else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["api", "--hostname", "github.com", "--method", method,
                             "--include", "--silent", "user/starred/omarshahine/HomeClaw"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // Honor the account established by gh auth login, not ephemeral
        // credentials that may have been exported by a build shell.
        var environment = ProcessInfo.processInfo.environment
        for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] {
            environment.removeValue(forKey: key)
        }
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_DEBUG"] = ""
        process.environment = environment

        return await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            process.terminationHandler = { process in
                let bytes = output.fileHandleForReading.availableData
                let status = String(decoding: bytes, as: UTF8.self)
                    .split(whereSeparator: \.isNewline)
                    .first(where: { $0.hasPrefix("HTTP/") })?
                    .split(separator: " ").dropFirst().first.flatMap { Int($0) }
                // Only a definitive 404 clears a known starred state.
                let success = process.terminationReason == .exit && process.terminationStatus == 0
                completion.finish(Response(success: success, status: success ? 204 : status == 404 ? 404 : nil))
            }
            do { try process.run() } catch {
                process.terminationHandler = nil
                completion.finish(nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                completion.finish(nil)
                if process.isRunning { process.terminate() }
            }
        }
    }
}
#endif
