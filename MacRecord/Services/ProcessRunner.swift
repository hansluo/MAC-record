import Foundation
import Darwin

struct ProcessExecutionResult: Sendable {
    let status: Int32
    let standardOutput: Data
    let standardError: Data
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set() {
        lock.lock()
        storedValue = true
        lock.unlock()
    }
}

enum ProcessRunnerError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "进程执行超时"
    }
}

enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil,
        outputLimit: Int = 1_048_576,
        onStart: (@Sendable (Process) -> Void)? = nil
    ) async throws -> ProcessExecutionResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if standardInput != nil { process.standardInput = Pipe() }

        try process.run()
        onStart?(process)

        let stdoutTask = Task.detached {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        if let standardInput, let inputPipe = process.standardInput as? Pipe {
            inputPipe.fileHandleForWriting.write(standardInput)
            try? inputPipe.fileHandleForWriting.close()
        }

        let timedOut = LockedFlag()
        let timeoutTask = timeout.map { timeout in
            Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, process.isRunning else { return }
                timedOut.set()
                terminate(process)
            }
        }

        return try await withTaskCancellationHandler {
            let status = await Task.detached {
                process.waitUntilExit()
                return process.terminationStatus
            }.value
            timeoutTask?.cancel()
            let stdout = await stdoutTask.value
            let stderr = await stderrTask.value
            if timedOut.value { throw ProcessRunnerError.timedOut }
            if Task.isCancelled { throw CancellationError() }
            return ProcessExecutionResult(
                status: status,
                standardOutput: Data(stdout.suffix(outputLimit)),
                standardError: Data(stderr.suffix(outputLimit))
            )
        } onCancel: {
            Task.detached { terminate(process) }
        }
    }

    static func terminate(_ process: Process, gracePeriod: TimeInterval = 2) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(gracePeriod)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
