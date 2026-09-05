import AppKit
import SwiftTerm

class ClickThroughTerminalView: LocalProcessTerminalView {
    var sessionId: UUID?
    private var keyMonitor: Any?
    private var statusDebounceWork: DispatchWorkItem?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        installArrowKeyMonitor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        installArrowKeyMonitor()
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Intercept arrow key events locally and send standard VT100/xterm sequences
    /// to avoid kitty keyboard protocol (CSI u) encoding issues.
    private func installArrowKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.firstResponder === self else { return event }

            let arrowCode: String?
            switch event.keyCode {
            case 126: arrowCode = "A" // Up
            case 125: arrowCode = "B" // Down
            case 124: arrowCode = "C" // Right
            case 123: arrowCode = "D" // Left
            default: arrowCode = nil
            }

            guard let code = arrowCode else { return event }

            let mods = event.modifierFlags.intersection([.shift, .option, .control])
            if mods.isEmpty {
                self.send(txt: "\u{1b}[\(code)")
            } else {
                var modifier = 1
                if mods.contains(.shift) { modifier += 1 }
                if mods.contains(.option) { modifier += 2 }
                if mods.contains(.control) { modifier += 4 }
                self.send(txt: "\u{1b}[1;\(modifier)\(code)")
            }
            return nil // consume the event
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return false
        }
        let paths = items.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        send(txt: paths)
        return true
    }

    /// Returns all visible lines from the terminal buffer.
    ///
    /// Must run on the main thread: SwiftTerm mutates the buffer on the main
    /// thread (feed/resize), and the `CircularList` of lines is not thread-safe.
    /// Reading it concurrently caused every crash seen so far (use-after-free in
    /// `CircularBufferLineList.subscript.read`).
    private func extractAllLines() -> [String]? {
        dispatchPrecondition(condition: .onQueue(.main))
        let terminal = getTerminal()
        guard terminal.rows >= 20 else { return nil }
        var lineTexts: [String] = []
        lineTexts.reserveCapacity(terminal.rows)
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else {
                lineTexts.append(String(repeating: " ", count: terminal.cols))
                continue
            }
            // One call per row instead of one `getCharacter` per cell.
            let text = line.translateToString(trimRight: false, startCol: 0, endCol: terminal.cols) { cell in
                let ch = cell.getCharacter()
                return ch == "\u{0}" ? " " : ch
            }
            lineTexts.append(text)
        }
        return lineTexts
    }

    /// Returns the last 20 non-blank lines from the given lines, joined by newlines.
    private func relevantText(from lines: [String]) -> String {
        let nonBlankLines = lines.filter { !$0.allSatisfy({ $0 == " " }) }
        return nonBlankLines.suffix(20).joined(separator: "\n")
    }

    /// Returns the last 20 non-blank lines of terminal output above the prompt separator.
    func extractVisibleText() -> String? {
        guard let lineTexts = extractAllLines() else { return nil }
        return Self.textAboveSeparator(lineTexts)
    }

    /// Returns the last 20 non-blank lines of the full terminal output (including prompt area).
    func extractFullVisibleText() -> String? {
        guard let lineTexts = extractAllLines() else { return nil }
        return relevantText(from: lineTexts)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)

        guard let id = sessionId else { return }

        // Debounce status checks so a burst of output triggers one evaluation.
        // The evaluation stays on the main thread: the buffer read is now a
        // handful of per-row calls, and the classification is a few string
        // scans over at most ~50 short lines, so it is cheap enough here.
        statusDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.evaluateStatus(for: id)
        }
        statusDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func evaluateStatus(for id: UUID) {
        guard let lines = extractAllLines() else { return }
        let visibleText = Self.textAboveSeparator(lines)
        let fullText = relevantText(from: lines)

        let newStatus: TerminalStatus

        if Self.hasTokenCounterLine(visibleText) || fullText.contains("esc to interrupt") {
            newStatus = .working
        }
        else if fullText.contains("Esc to cancel") || Self.hasUserPrompt(fullText) {
            newStatus = .waitingForInput
        } else if visibleText.contains("Interrupted") {
            newStatus = .interrupted
        } else {
            newStatus = .idle
        }

        if !SessionStore.shared.sessions.contains(where: {$0.id == id && $0.terminalStatus == newStatus}) {
            SessionStore.shared.updateTerminalStatus(id, status: newStatus)
        }
    }

    /// Last 20 non-blank lines above the last horizontal rule (Claude's prompt separator).
    private static func textAboveSeparator(_ lines: [String]) -> String {
        var lineTexts = lines
        let separator = "────────"
        if let lastSeparatorIndex = lineTexts.lastIndex(where: { $0.contains(separator) }) {
            lineTexts = Array(lineTexts.prefix(lastSeparatorIndex))
        }
        let nonBlankLines = lineTexts.filter { !$0.allSatisfy({ $0 == " " }) }
        return nonBlankLines.suffix(20).joined(separator: "\n")
    }

    /// Checks whether the text contains a Claude spinner character (visible during working state)
    private static let spinnerCharacters: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽"]

    /// Checks for a line like "Idle for 30s" — must contain " for " and end with "s",
    /// but must NOT contain parentheses (which indicate thinking duration, not true idle).
    private static func hasIdleForLine(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(" for ") else { return false }
            guard trimmed.hasSuffix("s") else { return false }
            guard !trimmed.contains("(") && !trimmed.contains(")") else { return false }
            return true
        }
    }

    /// Checks for the user prompt indicator: ❯ followed by a digit (1-9)
    private static func hasUserPrompt(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { line in
            let trimmed = line.drop(while: { $0 == " " })
            return trimmed.hasPrefix("❯") &&
                trimmed.dropFirst().first == " " &&
                trimmed.dropFirst(2).first?.isNumber == true
        }
    }

    private static func hasTokenCounterLine(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { line in
            guard let first = line.first, spinnerCharacters.contains(first) else { return false }
            guard line.dropFirst().first == " " else { return false }
            return line.contains("…")
        }
    }
}

class TerminalManager: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalManager()

    private var terminals: [UUID: LocalProcessTerminalView] = [:]

    func terminal(for sessionId: UUID, workingDirectory: String, launchClaude: Bool = true) -> LocalProcessTerminalView {
        if let existing = terminals[sessionId] {
            return existing
        }

        let terminal = ClickThroughTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
        terminal.sessionId = sessionId
        terminal.processDelegate = self

        // Match macOS Terminal default font size
        terminal.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(white: 0.1, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let environment = buildEnvironment()

        Log.info("Starting terminal for session \(sessionId) in \(workingDirectory) (shell: \(shell))", category: "terminal")
        terminal.startProcess(
            executable: shell,
            args: ["--login"],
            environment: environment,
            execName: "-" + (shell as NSString).lastPathComponent
        )

        // Fall back to home if the persisted directory is empty or has since disappeared.
        var directory = workingDirectory
        if directory.isEmpty || !FileManager.default.fileExists(atPath: directory) {
            Log.warning("Working directory '\(directory)' for session \(sessionId) is unavailable, using home", category: "terminal")
            directory = NSHomeDirectory()
        }

        // cd to working directory, launch claude only if CLAUDE.md exists and integration is enabled
        let escapedDir = shellEscape(directory)
        let hasClaude = launchClaude && SettingsManager.shared.claudeIntegrationEnabled && FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent("CLAUDE.md"))
        // Report once right after the cd so the stored directory is confirmed even
        // if the shell's chpwd hook doesn't fire (e.g. already in that directory).
        var command = cwdReportingHook(for: shell) + "cd \(escapedDir) && __notchy_cwd 2>/dev/null; clear"
        if hasClaude {
            command += " && claude"
        }
        terminal.send(txt: command + "\r")

        terminals[sessionId] = terminal
        return terminal
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    /// Called when the shell reports its working directory via OSC 7 (see `cwdReportingHook`).
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let payload = directory,
              let terminal = source as? ClickThroughTerminalView,
              let sessionId = terminal.sessionId,
              let path = Self.path(fromOSC7Payload: payload) else { return }
        DispatchQueue.main.async {
            Log.debug("Session \(sessionId) cwd -> \(path)", category: "terminal")
            SessionStore.shared.updateWorkingDirectory(sessionId, directory: path)
        }
    }

    /// OSC 7 carries a `file://host/path` URL. Accept both percent-encoded and raw paths.
    static func path(fromOSC7Payload payload: String) -> String? {
        var text = payload
        if text.hasPrefix("file://") {
            text.removeFirst("file://".count)
            // Drop the host component; the path starts at the first slash.
            if let slash = text.firstIndex(of: "/") {
                text = String(text[slash...])
            } else {
                return nil
            }
        }
        let path = text.removingPercentEncoding ?? text
        guard path.hasPrefix("/") else { return nil }
        return path
    }

    /// Shell snippet that makes the shell announce every directory change with
    /// OSC 7, the same mechanism Terminal.app and iTerm2 use. Plain login shells
    /// spawned by Notchy don't do this on their own, so persisted tabs would
    /// otherwise never learn where the user `cd`-ed to.
    private func cwdReportingHook(for shell: String) -> String {
        let report = #"printf '\033]7;file://%s%s\007' "${HOST:-localhost}" "$PWD""#
        switch (shell as NSString).lastPathComponent {
        case "zsh":
            return "__notchy_cwd() { \(report); }; autoload -Uz add-zsh-hook && add-zsh-hook chpwd __notchy_cwd; "
        case "bash":
            return "__notchy_cwd() { \(report); }; PROMPT_COMMAND=\"__notchy_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}\"; "
        default:
            return ""
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let id = (source as? ClickThroughTerminalView)?.sessionId.map(\.uuidString) ?? "unknown"
        Log.info("Shell process exited for session \(id) with code \(exitCode.map(String.init) ?? "nil")", category: "terminal")
    }

    /// Returns the visible text from a terminal's buffer
    func visibleText(for sessionId: UUID) -> String? {
        guard let terminal = terminals[sessionId] as? ClickThroughTerminalView else { return nil }
        return terminal.extractVisibleText()
    }

    func destroyTerminal(for sessionId: UUID) {
        if terminals[sessionId] != nil {
            Log.info("Destroying terminal for session \(sessionId)", category: "terminal")
        }
        terminals.removeValue(forKey: sessionId)
    }

    private func buildEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env.map { "\($0.key)=\($0.value)" }
    }

    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
