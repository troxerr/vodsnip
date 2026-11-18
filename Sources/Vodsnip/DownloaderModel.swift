import AppKit
import Foundation
import Observation
import VodsnipKit

enum Mode: String, CaseIterable, Identifiable {
    case entire, range, startToNow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .entire: "Entire video"
        case .range: "Time range"
        case .startToNow: "Start → now"
        }
    }
}

enum Phase: Equatable {
    case idle
    case fetching
    case ready
    case downloading
    case done(file: String?)
    case failed(String)
}

struct AppError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@Observable
final class DownloaderModel {
    var tools: Tools? = ToolLocator.locate()
    var urlText = ""
    var info: VideoInfo?
    /// True when the link was a channel that is streaming right now.
    var isLiveNow = false
    /// Seconds recorded so far, for a live recording. Read again right before each download.
    var liveEdge: Double?
    /// The video yt-dlp will download (for a live channel: its in-progress recording).
    var downloadURL: String?
    var mode: Mode = .entire
    var startText = "00:00:00"
    var endText = ""
    var quality: Quality = .source
    var accurateCuts = false
    var phase: Phase = .idle
    var progress: DownloadProgress?
    var log: [String] = []

    var outputDirectory: String = UserDefaults.standard.string(forKey: "outputDirectory")
        ?? NSHomeDirectory() + "/Movies/Twitch"
    {
        didSet { UserDefaults.standard.set(outputDirectory, forKey: "outputDirectory") }
    }
    var cookiesPath: String = UserDefaults.standard.string(forKey: "cookiesPath") ?? "" {
        didSet { UserDefaults.standard.set(cookiesPath, forKey: "cookiesPath") }
    }

    private var handle: ProcessHandle?
    private var cancelled = false

    var canFetch: Bool { tools != nil && phase != .fetching && phase != .downloading && !urlText.trimmingCharacters(in: .whitespaces).isEmpty }
    var canDownload: Bool { tools != nil && downloadURL != nil && (phase == .ready || isFinished) }
    var isBusy: Bool { phase == .fetching || phase == .downloading }
    private var isFinished: Bool {
        switch phase {
        case .done, .failed: info != nil
        default: false
        }
    }

    func recheckTools() { tools = ToolLocator.locate() }

    // MARK: Fetch

    func fetch() async {
        guard let tools, let parsed = TwitchURL.parse(urlText) else {
            phase = .failed("That doesn't look like a Twitch video or channel link.")
            return
        }
        phase = .fetching
        info = nil
        downloadURL = nil
        isLiveNow = false
        progress = nil
        do {
            switch parsed {
            case .vod, .other:
                info = try await videoInfo(parsed.canonical, tools: tools)
                downloadURL = parsed.canonical
            case .channel(let name):
                let live = try? await videoInfo(parsed.canonical, tools: tools)
                guard live?.isLive == true else {
                    throw AppError(message: "\(name) isn't live right now. Paste a video (VOD) link to download past streams.")
                }
                let url = try await newestArchive(channel: name, tools: tools)
                info = try await videoInfo(url, tools: tools)
                downloadURL = url
                isLiveNow = true
                liveEdge = info?.duration
                mode = .startToNow
            }
            if mode == .startToNow && !isLiveNow { mode = .entire }
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func cookieArgs() -> [String] { cookiesPath.isEmpty ? [] : ["--cookies", cookiesPath] }

    private func videoInfo(_ url: String, tools: Tools) async throws -> VideoInfo {
        let r = try await ProcessRunner.run(tools.ytdlp, ["-J", "--no-playlist", "--no-warnings"] + cookieArgs() + [url])
        guard r.status == 0 else { throw AppError(message: Self.errorLine(r.stderr)) }
        return try VideoInfo.decode(r.stdout)
    }

    private func newestArchive(channel: String, tools: Tools) async throws -> String {
        let listURL = "https://www.twitch.tv/\(channel)/videos?filter=archives&sort=time"
        let r = try await ProcessRunner.run(
            tools.ytdlp, ["-J", "--flat-playlist", "--playlist-end", "1", "--no-warnings"] + cookieArgs() + [listURL])
        guard r.status == 0 else { throw AppError(message: Self.errorLine(r.stderr)) }
        guard let url = try VideoList.decode(r.stdout).newestURL else {
            throw AppError(message: "\(channel) is live, but has no recording to download from the start (past broadcasts may be turned off).")
        }
        return url
    }

    static func errorLine(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        let line = lines.last(where: { $0.hasPrefix("ERROR") }) ?? lines.last ?? "yt-dlp failed."
        return line.replacingOccurrences(of: "ERROR: ", with: "")
    }

    // MARK: Download

    /// Checks the time fields and builds the request, or explains what is wrong.
    func makeRequest() throws -> DownloadRequest {
        guard let tools, let downloadURL else { throw AppError(message: "Fetch a link first.") }
        var range = DownloadRange.entire
        // A recording that is still in progress has no end. The default downloader would keep waiting for the
        // stream to finish; the native HLS downloader (see DownloadRequest.nativeHLS) stops at "now".
        if mode == .range {
            guard let start = TimeCode.parse(startText) else { throw AppError(message: "Start time must look like 01:23:45.") }
            var end: Double?
            if !endText.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let e = TimeCode.parse(endText) else { throw AppError(message: "End time must look like 01:23:45, or be empty for the end.") }
                guard e > start else { throw AppError(message: "End time must be after the start time.") }
                end = e
            }
            if isLiveNow, let edge = liveEdge { end = min(end ?? edge, edge) }
            if let d = info?.duration, start >= d {
                throw AppError(message: "Start time is past the end of the video (\(TimeCode.format(d))).")
            }
            range = .section(start: start, end: end)
        }
        if tools.ffmpeg == nil {
            throw AppError(message: "ffmpeg is needed to cut and merge video. Install it with: brew install ffmpeg")
        }
        return DownloadRequest(
            url: downloadURL, outputDirectory: outputDirectory, range: range, quality: quality,
            accurateCuts: accurateCuts, ffmpegPath: tools.ffmpeg?.path, cookiesPath: cookiesPath,
            nativeHLS: isLiveNow && mode != .range)
    }

    func download() async {
        guard let tools else { return }
        let request: DownloadRequest
        do {
            if isLiveNow, let downloadURL {
                phase = .fetching
                // "Now" is the moment you click Download, so read the length again.
                let fresh = try await videoInfo(downloadURL, tools: tools)
                info = fresh
                liveEdge = fresh.duration
            }
            request = try makeRequest()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        phase = .downloading
        progress = nil
        log = []
        cancelled = false
        var file: String?
        var lastError: String?
        let (events, handle) = ProcessRunner.stream(tools.ytdlp, request.arguments())
        self.handle = handle
        var status: Int32 = 0
        for await event in events {
            switch event {
            case .line(let line):
                if let p = ProgressLine.parse(line) {
                    progress = p
                } else if line.hasPrefix(DownloadRequest.filePrefix) {
                    file = String(line.dropFirst(DownloadRequest.filePrefix.count))
                } else {
                    if line.hasPrefix("ERROR") { lastError = line.replacingOccurrences(of: "ERROR: ", with: "") }
                    log.append(line)
                    if log.count > 200 { log.removeFirst(log.count - 200) }
                }
            case .exit(let s):
                status = s
            }
        }
        self.handle = nil
        if cancelled {
            phase = .ready
            log.append("Cancelled.")
        } else if status == 0 {
            progress?.fraction = 1
            phase = .done(file: file)
        } else {
            phase = .failed(lastError ?? "Download failed (exit \(status)). See the log.")
        }
    }

    func cancel() {
        cancelled = true
        handle?.terminate()
    }

    // MARK: Panels

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: outputDirectory)
        if panel.runModal() == .OK, let url = panel.url { outputDirectory = url.path }
    }

    func chooseCookies() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose a cookies.txt exported from your browser (needed for subscriber-only videos)."
        if panel.runModal() == .OK, let url = panel.url { cookiesPath = url.path }
    }

    func reveal(_ path: String?) {
        if let path, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: outputDirectory))
        }
    }
}
