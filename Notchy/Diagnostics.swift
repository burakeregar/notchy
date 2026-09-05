import AppKit
import Darwin
import Foundation
import os

// MARK: - Log

/// Lightweight app logger. Writes to the unified log (visible in Console.app)
/// and appends to a rotating text file at ~/Library/Logs/Notchy/notchy.log
/// so events leading up to a crash can be inspected after the fact.
enum Log {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"

        var osType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            }
        }
    }

    static let directory: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Notchy", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
    }()

    static let fileURL = directory.appendingPathComponent("notchy.log")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.adamlyttleapps.notchy"
    private static let queue = DispatchQueue(label: "com.notchy.log", qos: .utility)
    private static let maxFileSize: UInt64 = 2 * 1024 * 1024
    private static let rotatedFilesToKeep = 3
    private static var loggers: [String: Logger] = [:]
    private static var handle: FileHandle?

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func debug(_ message: @autoclosure () -> String, category: String = "app") {
        write(.debug, message(), category: category)
    }

    static func info(_ message: @autoclosure () -> String, category: String = "app") {
        write(.info, message(), category: category)
    }

    static func warning(_ message: @autoclosure () -> String, category: String = "app") {
        write(.warning, message(), category: category)
    }

    static func error(_ message: @autoclosure () -> String, category: String = "app") {
        write(.error, message(), category: category)
    }

    /// Blocks until all queued log lines have been written. Call before the process exits.
    static func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    private static func write(_ level: Level, _ message: String, category: String) {
        let date = Date()
        let isMain = Thread.isMainThread
        queue.async {
            osLogger(for: category).log(level: level.osType, "\(message, privacy: .public)")

            let thread = isMain ? "main" : "bg"
            let line = "\(timestampFormatter.string(from: date)) [\(level.rawValue)] [\(category)] [\(thread)] \(message)\n"
            appendToFile(line)
        }
    }

    private static func osLogger(for category: String) -> Logger {
        if let existing = loggers[category] { return existing }
        let logger = Logger(subsystem: subsystem, category: category)
        loggers[category] = logger
        return logger
    }

    private static func appendToFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if handle == nil {
            openFile()
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            if try handle.offset() > maxFileSize {
                rotate()
            }
        } catch {
            // Never let logging take the app down.
        }
    }

    private static func openFile() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let base = fileURL.path
        try? fm.removeItem(atPath: "\(base).\(rotatedFilesToKeep)")
        for index in stride(from: rotatedFilesToKeep - 1, through: 1, by: -1) {
            try? fm.moveItem(atPath: "\(base).\(index)", toPath: "\(base).\(index + 1)")
        }
        try? fm.moveItem(atPath: base, toPath: "\(base).1")
        openFile()
    }
}

// MARK: - CrashReporter

/// Captures fatal signals and uncaught exceptions to ~/Library/Logs/Notchy/crashes/,
/// detects unclean shutdowns on the next launch, and imports the matching macOS
/// crash report (.ips) so everything about a crash lives in one folder.
///
/// The signal handler only uses async-signal-safe C calls and pre-allocated
/// buffers. After writing its report it re-raises the signal with the default
/// disposition so macOS still produces its own diagnostic report.
enum CrashReporter {
    static let crashesDirectory = Log.directory.appendingPathComponent("crashes", isDirectory: true)
    static let stderrURL = Log.directory.appendingPathComponent("stderr.log")
    private static let sessionMarkerURL = Log.directory.appendingPathComponent("session.json")
    private static let diagnosticReportsDirectory = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)

    private static let fatalSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP, SIGSYS]

    /// Pre-rendered, NUL-terminated buffers the signal handler is allowed to touch.
    private static var crashFilePath: UnsafeMutablePointer<CChar>?
    private static var crashHeader: UnsafeMutablePointer<CChar>?
    private static var installed = false

    private struct SessionMarker: Codable {
        var pid: Int32
        var launchedAt: Date
        var version: String
    }

    // MARK: Install

    static func install() {
        guard !installed else { return }
        installed = true

        try? FileManager.default.createDirectory(at: crashesDirectory, withIntermediateDirectories: true)

        let launchDate = Date()
        let versionString = appVersionString()

        Log.info("===== Notchy \(versionString) launched (pid \(getpid()), macOS \(osVersionString())) =====", category: "lifecycle")

        checkPreviousSession()
        writeSessionMarker(launchedAt: launchDate, version: versionString)
        redirectStderrIfNotDebugging()
        prepareCrashBuffers(launchDate: launchDate, version: versionString)
        installSignalHandlers()
        installExceptionHandler()
    }

    /// Call from `applicationWillTerminate`. Removes the session marker so the
    /// next launch knows this shutdown was intentional.
    static func markCleanExit() {
        Log.info("Clean shutdown", category: "lifecycle")
        try? FileManager.default.removeItem(at: sessionMarkerURL)
        Log.flush()
    }

    static func openLogsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
    }

    // MARK: Previous-session detection

    private static func checkPreviousSession() {
        guard let data = try? Data(contentsOf: sessionMarkerURL),
              let marker = try? JSONDecoder().decode(SessionMarker.self, from: data) else {
            return
        }

        // A marker from a process that is still alive means a second instance,
        // not a crash. `kill(pid, 0)` succeeds when the process exists.
        if marker.pid != getpid(), kill(marker.pid, 0) == 0 {
            Log.warning("Another Notchy instance (pid \(marker.pid)) appears to be running", category: "lifecycle")
            return
        }

        let formatter = ISO8601DateFormatter()
        Log.warning("Previous session (pid \(marker.pid), launched \(formatter.string(from: marker.launchedAt)), v\(marker.version)) did not shut down cleanly", category: "crash")

        let imported = importDiagnosticReports(since: marker.launchedAt)
        if imported.isEmpty {
            Log.warning("No macOS crash report found for the previous session. It may have been force-quit, killed, or the Mac shut down.", category: "crash")
        }
        let ownReports = crashLogs(since: marker.launchedAt)
        if !ownReports.isEmpty {
            Log.info("Notchy's own crash log(s) from the previous session: \(ownReports.map(\.lastPathComponent).joined(separator: ", "))", category: "crash")
        }
    }

    /// Copies any Notchy-*.ips reports newer than `date` into the crashes folder
    /// and logs a short summary of each. Returns the copied file URLs.
    @discardableResult
    private static func importDiagnosticReports(since date: Date) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: diagnosticReportsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        var copied: [URL] = []
        for entry in entries where entry.lastPathComponent.hasPrefix("Notchy") && entry.pathExtension == "ips" {
            guard let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified >= date else { continue }
            let destination = crashesDirectory.appendingPathComponent(entry.lastPathComponent)
            if !fm.fileExists(atPath: destination.path) {
                do {
                    try fm.copyItem(at: entry, to: destination)
                    copied.append(destination)
                } catch {
                    Log.error("Failed to copy crash report \(entry.lastPathComponent): \(error)", category: "crash")
                    continue
                }
            }
            if let summary = summarize(ipsReport: entry) {
                Log.error("macOS crash report \(entry.lastPathComponent): \(summary)", category: "crash")
            }
        }
        return copied
    }

    private static func crashLogs(since date: Date) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: crashesDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        return entries.filter { url in
            guard url.pathExtension == "log",
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
            return modified >= date
        }
    }

    /// Extracts exception type, signal, and the first Notchy frames from a .ips report.
    private static func summarize(ipsReport url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // .ips files are a one-line JSON header followed by the JSON body.
        guard let newline = text.firstIndex(of: "\n") else { return nil }
        let body = text[text.index(after: newline)...]
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var parts: [String] = []
        if let exception = json["exception"] as? [String: Any] {
            let type = exception["type"] as? String ?? "?"
            let signal = exception["signal"] as? String ?? "?"
            parts.append("\(type) (\(signal))")
            if let subtype = exception["subtype"] as? String { parts.append(subtype) }
        }
        if let asi = json["asi"] as? [String: [String]] {
            for messages in asi.values { parts.append(contentsOf: messages) }
        }
        if let faulting = json["faultingThread"] as? Int,
           let threads = json["threads"] as? [[String: Any]],
           faulting < threads.count,
           let images = json["usedImages"] as? [[String: Any]] {
            let thread = threads[faulting]
            let queue = thread["queue"] as? String ?? "thread \(faulting)"
            var frames: [String] = []
            for frame in thread["frames"] as? [[String: Any]] ?? [] {
                guard let imageIndex = frame["imageIndex"] as? Int, imageIndex < images.count else { continue }
                let image = images[imageIndex]["name"] as? String ?? "?"
                let symbol = frame["symbol"] as? String ?? "?"
                var desc = "\(image)`\(symbol)"
                if let file = frame["sourceFile"] as? String, let line = frame["sourceLine"] as? Int {
                    desc += " (\(file):\(line))"
                }
                frames.append(desc)
                if frames.count >= 8 { break }
            }
            parts.append("faulting \(queue): " + frames.joined(separator: " <- "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " | ")
    }

    private static func writeSessionMarker(launchedAt: Date, version: String) {
        let marker = SessionMarker(pid: getpid(), launchedAt: launchedAt, version: version)
        if let data = try? JSONEncoder().encode(marker) {
            try? data.write(to: sessionMarkerURL, options: .atomic)
        }
    }

    // MARK: stderr capture

    /// Swift runtime traps ("Fatal error: Index out of range") print their message
    /// to stderr before aborting. Capture it to a file so the reason survives.
    /// Skipped when a debugger is attached so Xcode's console keeps working.
    private static func redirectStderrIfNotDebugging() {
        guard !isDebuggerAttached() else {
            Log.info("Debugger attached; leaving stderr on the console", category: "lifecycle")
            return
        }
        let path = stderrURL.path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64, size > 5 * 1024 * 1024 {
            try? FileManager.default.removeItem(atPath: path)
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDERR_FILENO)
        close(fd)
        let banner = "\n===== Notchy launched \(ISO8601DateFormatter().string(from: Date())) (pid \(getpid())) =====\n"
        fputs(banner, stderr)
    }

    private static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    // MARK: Signal handling

    private static func prepareCrashBuffers(launchDate: Date, version: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let fileName = "Notchy-\(formatter.string(from: launchDate))-pid\(getpid()).crash.log"
        crashFilePath = strdup(crashesDirectory.appendingPathComponent(fileName).path)

        let header = """
        Notchy crash report
        App version: \(version)
        macOS: \(osVersionString())
        Process launched: \(ISO8601DateFormatter().string(from: launchDate)) (pid \(getpid()))
        Preceding events: \(Log.fileURL.path)
        Swift runtime message (if any): \(stderrURL.path)
        macOS report: ~/Library/Logs/DiagnosticReports/Notchy-*.ips (copied here on next launch)

        """
        crashHeader = strdup(header)
    }

    private static func installSignalHandlers() {
        // Give the handler its own stack so stack overflows can still be reported.
        let stackSize = 256 * 1024
        var altStack = stack_t()
        altStack.ss_sp = UnsafeMutableRawPointer.allocate(byteCount: stackSize, alignment: 16)
        altStack.ss_size = stackSize
        altStack.ss_flags = 0
        sigaltstack(&altStack, nil)

        for sig in fatalSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = crashSignalHandler
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }
    }

    private static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let text = """

            ===== Uncaught Objective-C exception =====
            Name: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "none")
            Stack:
            \(exception.callStackSymbols.joined(separator: "\n"))

            """
            if let path = CrashReporter.crashFilePath {
                let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
                if fd >= 0 {
                    if let header = CrashReporter.crashHeader { _ = write(fd, header, strlen(header)) }
                    text.withCString { _ = write(fd, $0, strlen($0)) }
                    close(fd)
                }
            }
            Log.error("Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "")", category: "crash")
            Log.flush()
        }
    }

    /// Async-signal-safe: no allocation, no Swift runtime calls beyond simple arithmetic.
    private static let crashSignalHandler: @convention(c) (Int32, UnsafeMutablePointer<siginfo_t>?, UnsafeMutableRawPointer?) -> Void = { signal, info, _ in
        if let path = CrashReporter.crashFilePath {
            let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd >= 0 {
                if let header = CrashReporter.crashHeader { _ = write(fd, header, strlen(header)) }
                writeString(fd, "\n===== Fatal signal: ")
                writeString(fd, signalName(signal))
                writeString(fd, " (")
                writeNumber(fd, Int(signal))
                writeString(fd, ")")
                if let info, signal == SIGSEGV || signal == SIGBUS {
                    writeString(fd, " at address 0x")
                    writeHex(fd, UInt(bitPattern: info.pointee.si_addr))
                }
                writeString(fd, " =====\nBacktrace of crashing thread:\n")

                withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 128) { frames in
                    let count = backtrace(frames.baseAddress, Int32(frames.count))
                    backtrace_symbols_fd(frames.baseAddress, count, fd)
                }
                writeString(fd, "\n")
                close(fd)
            }
        }

        // Restore default handling and re-raise so macOS writes its own .ips report.
        Darwin.signal(signal, SIG_DFL)
        raise(signal)
    }

    private static func writeString(_ fd: Int32, _ text: StaticString) {
        text.withUTF8Buffer { buffer in
            _ = write(fd, buffer.baseAddress, buffer.count)
        }
    }

    private static func writeNumber(_ fd: Int32, _ value: Int) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 24) { digits in
            var index = digits.count
            var remaining = value < 0 ? -value : value
            repeat {
                index -= 1
                digits[index] = UInt8(48 + remaining % 10)
                remaining /= 10
            } while remaining > 0
            if value < 0 {
                index -= 1
                digits[index] = UInt8(ascii: "-")
            }
            _ = write(fd, digits.baseAddress! + index, digits.count - index)
        }
    }

    private static func writeHex(_ fd: Int32, _ value: UInt) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16) { digits in
            var index = digits.count
            var remaining = value
            repeat {
                index -= 1
                let nibble = UInt8(remaining & 0xF)
                digits[index] = nibble < 10 ? 48 + nibble : 87 + nibble // '0'-'9', 'a'-'f'
                remaining >>= 4
            } while remaining > 0
            _ = write(fd, digits.baseAddress! + index, digits.count - index)
        }
    }

    private static func signalName(_ signal: Int32) -> StaticString {
        switch signal {
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGABRT: return "SIGABRT"
        case SIGFPE: return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        case SIGSYS: return "SIGSYS"
        default: return "UNKNOWN"
        }
    }

    // MARK: Helpers

    private static func appVersionString() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        #if DEBUG
        return "\(version) (\(build)) debug"
        #else
        return "\(version) (\(build))"
        #endif
    }

    private static func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
