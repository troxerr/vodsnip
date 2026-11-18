import Foundation

/// Finds yt-dlp and ffmpeg on this Mac.
public struct Tools: Sendable {
    public var ytdlp: URL
    public var ffmpeg: URL?
}

public enum ToolLocator {
    /// Tools shipped inside the app (Contents/Resources/bin, filled in by tools/release.sh). Looked at first, so a
    /// customer needs no Homebrew. A plain developer build has no such folder and falls through to the system.
    static let bundledDir: String? = {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("bin").path,
            FileManager.default.fileExists(atPath: dir)
        else { return nil }
        return dir
    }()

    static let searchDirs = (bundledDir.map { [$0] } ?? []) + [
        "/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/opt/ffmpeg-full/bin", "/opt/homebrew/opt/ffmpeg/bin",
        "/opt/local/bin", NSHomeDirectory() + "/.local/bin",
    ]

    public static func find(_ name: String) -> URL? {
        let envDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in searchDirs + envDirs {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// nil when yt-dlp is missing. ffmpeg may be nil: cutting and merging then fail with a clear message.
    public static func locate() -> Tools? {
        guard let y = find("yt-dlp") else { return nil }
        return Tools(ytdlp: y, ffmpeg: find("ffmpeg"))
    }

    /// PATH for child processes, so yt-dlp finds ffmpeg and python.
    static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchDirs + [env["PATH"] ?? ""]).joined(separator: ":")
        return env
    }
}

public enum ProcessEvent: Sendable {
    case line(String)
    case exit(Int32)
}

/// Lets the caller stop a running process.
public final class ProcessHandle: @unchecked Sendable {
    fileprivate let process = Process()
    public func terminate() { if process.isRunning { process.terminate() } }
}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    /// Adds bytes and returns every complete line. Progress bars use \r, so both \r and \n end a line.
    func append(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let i = data.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = data[data.startIndex..<i]
            data.removeSubrange(data.startIndex...i)
            if !lineData.isEmpty { lines.append(String(decoding: lineData, as: UTF8.self)) }
        }
        return lines
    }

    func rest() -> String? {
        lock.lock(); defer { lock.unlock() }
        defer { data.removeAll() }
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }
}

private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

public enum ProcessRunner {
    public struct Result: Sendable {
        public var stdout: Data
        public var stderr: String
        public var status: Int32
    }

    /// Runs a command to the end and returns what it printed.
    public static func run(_ executable: URL, _ arguments: [String]) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = executable
                p.arguments = arguments
                p.environment = ToolLocator.childEnvironment
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(throwing: error)
                    return
                }
                let errData = Box(Data())
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData.set(err.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: Result(
                    stdout: outData, stderr: String(decoding: errData.get(), as: UTF8.self), status: p.terminationStatus))
            }
        }
    }

    /// Starts a command and streams its output lines (stdout and stderr together), then the exit status.
    public static func stream(_ executable: URL, _ arguments: [String]) -> (events: AsyncStream<ProcessEvent>, handle: ProcessHandle) {
        let handle = ProcessHandle()
        let events = AsyncStream<ProcessEvent> { continuation in
            let p = handle.process
            p.executableURL = executable
            p.arguments = arguments
            p.environment = ToolLocator.childEnvironment
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let buffer = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty { return }
                for line in buffer.append(chunk) { continuation.yield(.line(line)) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                // Drain whatever is left in the pipe.
                let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                var lines = tail.isEmpty ? [] : buffer.append(tail)
                if let rest = buffer.rest() { lines.append(rest) }
                for line in lines { continuation.yield(.line(line)) }
                continuation.yield(.exit(proc.terminationStatus))
                continuation.finish()
            }
            do { try p.run() } catch {
                continuation.yield(.line("Could not start \(executable.lastPathComponent): \(error.localizedDescription)"))
                continuation.yield(.exit(127))
                continuation.finish()
            }
            continuation.onTermination = { _ in handle.terminate() }
        }
        return (events, handle)
    }
}
