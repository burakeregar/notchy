import Foundation

struct Checkpoint: Identifiable {
    let id: String          // full ref name
    let date: Date
    let commitHash: String

    var displayName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM h:mma"
        return formatter.string(from: date)
    }
}

enum CheckpointError: LocalizedError {
    case gitFailed(String)
    case notAGitRepo
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .gitFailed(let msg): return "Git error: \(msg)"
        case .notAGitRepo: return "Project directory is not a git repository"
        case .timedOut(let cmd): return "Git command timed out: \(cmd)"
        }
    }
}

class CheckpointManager {
    static let shared = CheckpointManager()

    private let refPrefix = "refs/Notchy-snapshots"

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// Serial queue for read-only checkpoint queries issued from the UI.
    private let queryQueue = DispatchQueue(label: "com.notchy.checkpoints", qos: .userInitiated)

    /// Upper bound for any single git invocation. A git process can block
    /// indefinitely on a macOS privacy prompt, a credential prompt, or a slow
    /// volume; without a bound, a caller waiting on it would hang forever.
    private let gitTimeout: TimeInterval = 15

    /// Runs git synchronously with a timeout. Must not be called on the main
    /// thread: it blocks for the duration of the git process, and a blocked git
    /// process would freeze the entire app (seen in practice when git stalled on
    /// a Documents-folder permission prompt).
    @discardableResult
    private func git(_ args: [String], in directory: String, environment: [String: String]? = nil) throws -> String {
        assert(!Thread.isMainThread, "CheckpointManager.git must run off the main thread")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = ProcessInfo.processInfo.environment
        // Never let git open an interactive prompt; there is no terminal to answer it.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/false"
        if let environment {
            env.merge(environment) { _, new in new }
        }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Drain both pipes concurrently while the process runs, so large output
        // can't fill a pipe buffer and deadlock against `waitUntilExit`.
        var outData = Data()
        var errData = Data()
        let drain = DispatchGroup()
        drain.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            drain.leave()
        }
        drain.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            drain.leave()
        }

        try process.run()

        let commandDescription = "git " + args.joined(separator: " ")
        var timedOut = false
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut = true
            Log.warning("\(commandDescription) in \(directory) exceeded \(Int(self.gitTimeout))s, killing it", category: "checkpoint")
            kill(process.processIdentifier, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + gitTimeout, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        drain.wait()

        if timedOut {
            throw CheckpointError.timedOut(commandDescription)
        }

        let output = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let errOutput = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CheckpointError.gitFailed(errOutput)
        }

        return output
    }

    /// Creates a checkpoint by capturing the full working tree as a git commit stored under a custom ref.
    /// Uses a temporary index so the user's staging area is not affected.
    func createCheckpoint(projectName: String, projectDirectory: String) throws {
        // Verify this is a git repo
        _ = try git(["rev-parse", "--git-dir"], in: projectDirectory)

        let timestamp = dateFormatter.string(from: Date())
        let refName = "\(refPrefix)/\(projectName)/\(timestamp)"

        // Use a temporary index file to avoid disturbing the user's staged changes
        let tempIndex = NSTemporaryDirectory() + "Notchy-index-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempIndex) }

        let env = ["GIT_INDEX_FILE": tempIndex]

        // Stage everything into the temp index
        try git(["add", "-A"], in: projectDirectory, environment: env)

        // Write the tree object from the temp index
        let tree = try git(["write-tree"], in: projectDirectory, environment: env)
        guard !tree.isEmpty else { throw CheckpointError.gitFailed("write-tree produced no output") }

        // Create a detached commit (no parent) holding the tree
        let commit = try git(["commit-tree", tree, "-m", "Notchy checkpoint \(timestamp)"], in: projectDirectory)
        guard !commit.isEmpty else { throw CheckpointError.gitFailed("commit-tree produced no output") }

        // Store the commit under a custom ref
        try git(["update-ref", refName, commit], in: projectDirectory)
    }

    /// Lists all checkpoints for a project, newest first. Blocking; call off the main thread.
    func checkpoints(for projectName: String, in projectDirectory: String) -> [Checkpoint] {
        let refPattern = "\(refPrefix)/\(projectName)/"
        let output: String
        do {
            output = try git(
                ["for-each-ref", "--format=%(refname) %(objectname:short)", refPattern],
                in: projectDirectory
            )
        } catch {
            Log.warning("Listing checkpoints for \(projectName) failed: \(error.localizedDescription)", category: "checkpoint")
            return []
        }
        guard !output.isEmpty else { return [] }

        return output.components(separatedBy: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let refName = String(parts[0])
            let hash = String(parts[1])
            // Extract the timestamp portion from the ref name
            guard let lastSlash = refName.lastIndex(of: "/") else { return nil }
            let timestamp = String(refName[refName.index(after: lastSlash)...])
            guard let date = dateFormatter.date(from: timestamp) else { return nil }
            return Checkpoint(id: refName, date: date, commitHash: hash)
        }
        .sorted { $0.date > $1.date }
    }

    /// Non-blocking variant for UI code. Runs the git query on a background
    /// queue and delivers the result on the main thread.
    func checkpoints(for projectName: String, in projectDirectory: String, completion: @escaping ([Checkpoint]) -> Void) {
        queryQueue.async {
            let result = self.checkpoints(for: projectName, in: projectDirectory)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Restores a checkpoint by checking out all files from its tree into the working directory
    func restoreCheckpoint(_ checkpoint: Checkpoint, to projectDirectory: String) throws {
        try git(["checkout", checkpoint.commitHash, "--", "."], in: projectDirectory)
    }

    /// Clears all checkpoints for a project by deleting their refs
    func clearCheckpoints(for projectName: String, in projectDirectory: String) {
        let list = checkpoints(for: projectName, in: projectDirectory)
        for checkpoint in list {
            try? git(["update-ref", "-d", checkpoint.id], in: projectDirectory)
        }
    }
}
