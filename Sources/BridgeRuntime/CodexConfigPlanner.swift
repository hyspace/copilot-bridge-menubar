import Foundation
import Darwin
import BridgeCore

/// Private bounded IPC. Config text travels through pipes, never arguments/logs.
final class CodexConfigPlanner {
    private let executable: URL?
    private let arguments: [String]
    private let home: URL
    init(executable: URL?, home: URL, arguments: [String] = ["--codex-config-plan"]) {
        self.executable = executable; self.arguments = arguments; self.home = home
    }
    func plan(_ request: CodexPlanRequest) throws -> CodexPlanResult {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw BridgeError.message("The bundled Codex configuration helper is unavailable. No configuration was changed.")
        }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "NO_COLOR": "1"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let timeout = DispatchWorkItem { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
        let hardTimeout = DispatchWorkItem { [weak process] in
            if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        defer {
            timeout.cancel(); hardTimeout.cancel()
            try? input.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        try process.run()
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        DispatchQueue.global().asyncAfter(deadline: .now() + 12, execute: hardTimeout)
        let inputFD = input.fileHandleForWriting.fileDescriptor
        let outputFD = output.fileHandleForReading.fileDescriptor
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0,
              fcntl(inputFD, F_SETFL, O_NONBLOCK) == 0,
              fcntl(outputFD, F_SETFL, O_NONBLOCK) == 0 else {
            throw BridgeError.message("Could not establish bounded configuration-helper communication.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 13
        func ready(_ fd: Int32, _ events: Int16) throws {
            while ProcessInfo.processInfo.systemUptime < deadline {
                var item = pollfd(fd: fd, events: events, revents: 0)
                let result = poll(&item, 1, 100)
                if result > 0 { return }
                if result < 0 && errno != EINTR { break }
            }
            throw BridgeError.message("Codex configuration planning timed out. No new change was committed.")
        }
        let requestData = try JSONEncoder().encode(request)
        guard requestData.count <= 16 * 1024 * 1024 else {
            throw BridgeError.message("The configuration planning request is too large.")
        }
        try requestData.withUnsafeBytes { buffer in
            var position = 0
            while position < buffer.count {
                try ready(inputFD, Int16(POLLOUT))
                let count = Darwin.write(inputFD, buffer.baseAddress!.advanced(by: position), buffer.count - position)
                if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                guard count > 0 else { throw BridgeError.message("The configuration helper stopped before accepting the request.") }
                position += count
            }
        }
        try input.fileHandleForWriting.close()
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try ready(outputFD, Int16(POLLIN | POLLHUP))
            let count = Darwin.read(outputFD, &buffer, buffer.count)
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count >= 0 else { throw BridgeError.message("Could not read the configuration helper response.") }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= 16 * 1024 * 1024 else {
                throw BridgeError.message("The Codex configuration helper exceeded its response limit.")
            }
        }
        process.waitUntilExit()
        guard let result = try? JSONDecoder().decode(CodexPlanResult.self, from: bytes) else {
            throw BridgeError.message("The Codex configuration helper did not finish safely. No new change was committed.")
        }
        guard process.terminationStatus == 0 || !result.ok else {
            throw BridgeError.message("The Codex configuration helper exited unexpectedly.")
        }
        return result
    }
}
