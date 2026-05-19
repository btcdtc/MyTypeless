import Foundation
import Darwin

enum LlamaServerError: LocalizedError {
    case binaryMissing(URL)
    case modelMissing(String)
    case launchFailed(String)
    case warmupTimeout(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .binaryMissing(let url): return "llama-server binary not found at \(url.path)"
        case .modelMissing(let path): return "model not found at \(path)"
        case .launchFailed(let why): return "llama-server launch failed: \(why)"
        case .warmupTimeout(let s): return "llama-server didn't become healthy in \(Int(s))s"
        }
    }
}

/// Per spec §12: bundle the helper binary, launch it on a free localhost port,
/// `--ctx-size 4096 --n-gpu-layers 999 --no-webui`, try `--flash-attn` and
/// retry without if it fails; manage a single owned subprocess + PID file.
actor LlamaCppServerManager {
    enum Status: Equatable {
        case stopped
        case starting
        case running(port: Int, pid: Int32)
        case failed(String)
    }

    private(set) var status: Status = .stopped

    private let modelPath: String
    private let contextSize: Int
    private let useFlashAttn: Bool
    private let binaryURL: URL
    private let pidFile: URL
    private let requiredFiles: [String]
    private let extraArguments: [String]
    /// Per-request override is also possible by passing a different timeout
    /// at call time, but the default tracks AppSettings.correctionColdTimeoutMs.
    private let coldTimeoutSec: TimeInterval
    private var process: Process?

    init(modelPath: String,
         contextSize: Int,
         useFlashAttn: Bool,
         binaryURL: URL,
         pidFile: URL = AppPaths.llamaPidFile,
         requiredFiles: [String] = [],
         extraArguments: [String] = [],
         coldTimeoutSec: TimeInterval = 8) {
        self.modelPath = modelPath
        self.contextSize = contextSize
        self.useFlashAttn = useFlashAttn
        self.binaryURL = binaryURL
        self.pidFile = pidFile
        self.requiredFiles = requiredFiles
        self.extraArguments = extraArguments
        self.coldTimeoutSec = coldTimeoutSec
    }

    /// Bring the server up if not already running. Returns the port.
    func ensureRunning() async throws -> Int {
        // Self-heal: if we *think* we're running but the process died (crash,
        // OOM, user-killed via Activity Monitor), drop the stale state so the
        // next request starts a fresh server.
        if case .running = status, let p = process, !p.isRunning {
            Log.llm.notice("llama-server died externally; will restart on next request")
            process = nil
            status = .stopped
            try? FileManager.default.removeItem(at: pidFile)
        }

        switch status {
        case .running(let port, _):
            return port
        case .starting:
            while case .starting = status {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            return try await ensureRunning()
        case .stopped, .failed:
            return try await start()
        }
    }

    func stop() async {
        if let p = process, p.isRunning {
            let pidToKill = p.processIdentifier
            p.terminate()
            // Escalate to SIGKILL after 2s in case the helper hangs.
            let killer = DispatchWorkItem {
                if kill(pidToKill, 0) == 0 {
                    Log.llm.notice("llama-server didn't exit on SIGTERM; SIGKILL")
                    _ = kill(pidToKill, SIGKILL)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: killer)
            p.waitUntilExit()                  // synchronous — blocks until exit
            killer.cancel()
        }
        process = nil
        status = .stopped
        try? FileManager.default.removeItem(at: pidFile)
        Log.llm.info("llama-server stopped")
    }

    // MARK: - Private

    private func start() async throws -> Int {
        status = .starting

        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            status = .failed("binary missing")
            throw LlamaServerError.binaryMissing(binaryURL)
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            status = .failed("model missing")
            throw LlamaServerError.modelMissing(modelPath)
        }
        for path in requiredFiles where !FileManager.default.fileExists(atPath: path) {
            status = .failed("required file missing")
            throw LlamaServerError.modelMissing(path)
        }

        terminateStaleServer()

        let port = try FreePortFinder.findFreeLocalhostPort()
        Log.llm.info("starting llama-server on port \(port)")

        // Try with flash-attn first if requested; fall back without on failure (§12).
        do {
            try await launch(port: port, flashAttn: useFlashAttn)
        } catch let primary {
            Log.llm.notice("primary launch failed (\(primary.localizedDescription, privacy: .public)); retrying without --flash-attn")
            do {
                try await launch(port: port, flashAttn: false)
            } catch {
                status = .failed(error.localizedDescription)
                throw error
            }
        }

        let pid = process?.processIdentifier ?? -1
        status = .running(port: port, pid: pid)
        try? String(pid).write(to: pidFile, atomically: true, encoding: .utf8)
        return port
    }

    private func launch(port: Int, flashAttn: Bool) async throws {
        var args = [
            "--model", modelPath,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", String(contextSize),
            "--n-gpu-layers", "999",
            "--no-webui",
            "--reasoning", "off",
        ]
        args += extraArguments
        if flashAttn { args += ["--flash-attn", "on"] }

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            throw LlamaServerError.launchFailed(error.localizedDescription)
        }
        self.process = proc

        do {
            try await waitForReady(port: port, timeout: coldTimeoutSec)
        } catch {
            proc.terminate()
            self.process = nil
            throw error
        }
    }

    private func waitForReady(port: Int, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 0.5
        while Date() < deadline {
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    Log.llm.info("llama-server ready on port \(port)")
                    return
                }
            } catch {
                // not ready yet
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw LlamaServerError.warmupTimeout(seconds: timeout)
    }

    /// Spec §12: read the PID file, kill -0 to test liveness, SIGTERM if alive
    /// — BUT only if the PID still belongs to our own llama-server binary.
    /// PIDs get recycled on macOS; killing blindly could nuke an unrelated app.
    private func terminateStaleServer() {
        guard let pidStr = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }

        defer { try? FileManager.default.removeItem(at: pidFile) }

        guard kill(pid, 0) == 0 else { return }              // not alive — nothing to do
        guard Self.pidMatches(pid, expectedBinary: binaryURL) else {
            Log.llm.notice("pid \(pid) in llama.pid is not our llama-server (PID reused); skipping kill")
            return
        }

        Log.llm.notice("found stale llama-server pid=\(pid); SIGTERM")
        _ = kill(pid, SIGTERM)
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        Log.llm.notice("pid=\(pid) still alive; SIGKILL")
        _ = kill(pid, SIGKILL)
    }

    /// True iff the given pid's executable path matches our bundled
    /// llama-server-arm64. Uses `/bin/ps -p PID -o comm=`, which returns the
    /// resolved executable path on macOS.
    private static func pidMatches(_ pid: pid_t, expectedBinary: URL) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", "comm="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }
        guard proc.terminationStatus == 0 else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let comm = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // `comm` is either the full path or just the basename, depending on
        // how the process was launched. Match either form.
        let expectedName = expectedBinary.lastPathComponent
        return comm == expectedBinary.path
            || (comm as NSString).lastPathComponent == expectedName
    }
}
