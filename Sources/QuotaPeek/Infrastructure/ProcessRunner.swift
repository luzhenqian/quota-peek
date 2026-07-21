import Foundation
import Darwin

struct ProcessOutput: Sendable {
    let text: String
    let exitCode: Int32
    let timedOut: Bool
}

struct ProcessRunner: Sendable {
    func run(
        executable: String,
        arguments: [String],
        input: String? = nil,
        timeout: TimeInterval = 12,
        pseudoTerminal: Bool = false,
        closeInput: Bool = true,
        inputDelay: TimeInterval = 0,
        inputReadyText: String? = nil,
        inputReadyTimeout: TimeInterval = 5,
        skipInputIfNotReady: Bool = false,
        workingDirectory: URL? = nil,
        environment additions: [String: String] = [:]
    ) async throws -> ProcessOutput {
        try await Task.detached(priority: .utility) {
            try Self.runSynchronously(
                executable: executable,
                arguments: arguments,
                input: input,
                timeout: timeout,
                pseudoTerminal: pseudoTerminal,
                closeInput: closeInput,
                inputDelay: inputDelay,
                inputReadyText: inputReadyText,
                inputReadyTimeout: inputReadyTimeout,
                skipInputIfNotReady: skipInputIfNotReady,
                workingDirectory: workingDirectory,
                environment: additions
            )
        }.value
    }

    private static func runSynchronously(
        executable: String,
        arguments: [String],
        input: String?,
        timeout: TimeInterval,
        pseudoTerminal: Bool,
        closeInput: Bool,
        inputDelay: TimeInterval,
        inputReadyText: String?,
        inputReadyTimeout: TimeInterval,
        skipInputIfNotReady: Bool,
        workingDirectory: URL?,
        environment additions: [String: String]
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        additions.forEach { environment[$0.key] = $0.value }
        process.environment = environment

        let outputHandle: FileHandle
        let inputHandle: FileHandle
        var slaveHandle: FileHandle?

        if pseudoTerminal {
            var masterDescriptor: Int32 = 0
            var slaveDescriptor: Int32 = 0
            var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&masterDescriptor, &slaveDescriptor, nil, nil, &size) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            let master = FileHandle(fileDescriptor: masterDescriptor, closeOnDealloc: true)
            let slave = FileHandle(fileDescriptor: slaveDescriptor, closeOnDealloc: true)
            outputHandle = master
            inputHandle = master
            slaveHandle = slave
            process.standardOutput = slave
            process.standardError = slave
            process.standardInput = slave
        } else {
            let combinedPipe = Pipe()
            let inputPipe = Pipe()
            outputHandle = combinedPipe.fileHandleForReading
            inputHandle = inputPipe.fileHandleForWriting
            process.standardOutput = combinedPipe
            process.standardError = combinedPipe
            process.standardInput = inputPipe
        }

        let termination = ProcessTermination(process: process)
        try process.run()
        try? slaveHandle?.close()

        let capture = ProcessCapture()
        let reader = Thread {
            while true {
                let chunk = outputHandle.availableData
                guard !chunk.isEmpty else { break }
                capture.append(chunk)
            }
            capture.finish()
        }
        reader.name = "QuotaPeek CLI output"
        reader.start()

        var inputIsReady = true
        if let inputReadyText, let readyData = inputReadyText.data(using: .utf8) {
            inputIsReady = capture.waitUntilContains(readyData, timeout: inputReadyTimeout)
        }
        if inputDelay > 0 {
            Thread.sleep(forTimeInterval: inputDelay)
        }
        if (!skipInputIfNotReady || inputIsReady), let input, let data = input.data(using: .utf8) {
            inputHandle.write(data)
        }
        if closeInput && !pseudoTerminal {
            try? inputHandle.close()
        }

        let timeoutItem = DispatchWorkItem {
            termination.terminateForTimeout()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()
        _ = capture.waitUntilFinished(timeout: 2)
        let data = capture.data
        if pseudoTerminal {
            try? outputHandle.close()
        } else {
            try? inputHandle.close()
            try? outputHandle.close()
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        return ProcessOutput(
            text: text,
            exitCode: process.terminationStatus,
            timedOut: termination.didTimeOut
        )
    }
}

private final class ProcessCapture: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var finished = false

    var data: Data {
        condition.withLock { buffer }
    }

    func append(_ data: Data) {
        condition.withLock {
            buffer.append(data)
            condition.broadcast()
        }
    }

    func finish() {
        condition.withLock {
            finished = true
            condition.broadcast()
        }
    }

    func waitUntilContains(_ needle: Data, timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while buffer.range(of: needle) == nil && !finished {
            guard condition.wait(until: deadline) else { break }
        }
        return buffer.range(of: needle) != nil
    }

    func waitUntilFinished(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !finished {
            guard condition.wait(until: deadline) else { break }
        }
        return finished
    }
}

private final class ProcessTermination: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var timeoutValue = false

    init(process: Process) {
        self.process = process
    }

    var didTimeOut: Bool {
        lock.withLock { timeoutValue }
    }

    func terminateForTimeout() {
        lock.withLock { timeoutValue = true }
        guard process.isRunning else { return }
        process.terminate()
    }
}

enum CommandLocator {
    static func locate(_ name: String, explicitPath: String = "") -> String? {
        if !explicitPath.isEmpty, FileManager.default.isExecutableFile(atPath: explicitPath) {
            return explicitPath
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let commonEntries = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "\(home)/.local/bin",
            "\(home)/.kimi-code/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.cargo/bin"
        ]

        for directory in (pathEntries + commonEntries) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
