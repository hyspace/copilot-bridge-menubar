import Foundation
import Darwin

/// Nonblocking, serial FD draining. Cancellation closes only after the read handler has finished.
final class PipeReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.hyspace.copilot-bridge.pipe")
    private let source: DispatchSourceRead
    private let fd: Int32
    private let receive: (Data) -> Void
    init(handle: FileHandle, receive: @escaping (Data) -> Void, closed: @escaping () -> Void) {
        fd = handle.fileDescriptor
        self.receive = receive
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { try? handle.close(); closed() }
        source.resume()
    }
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 16384)
        for _ in 0..<16 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { receive(Data(buffer.prefix(count))) }
            else if count == 0 { source.cancel(); return }
            else if errno == EINTR { continue }
            else if errno == EAGAIN { return }
            else { source.cancel(); return }
        }
    }
    func stop() {
        queue.async { [self] in
            if !source.isCancelled { drain(); source.cancel() }
        }
    }
    deinit { source.cancel() }
}
