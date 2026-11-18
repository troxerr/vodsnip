import Foundation

public enum Quality: String, CaseIterable, Identifiable, Sendable {
    case source, p1080, p720, p480, p360, audio

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .source: "Source (best)"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        case .p360: "360p"
        case .audio: "Audio only"
        }
    }

    var selector: String {
        switch self {
        case .source: "best"
        case .p1080: "best[height<=1080]/best"
        case .p720: "best[height<=720]/best"
        case .p480: "best[height<=480]/best"
        case .p360: "best[height<=360]/best"
        case .audio: "Audio_Only/bestaudio/worst"
        }
    }
}

public enum DownloadRange: Equatable, Sendable {
    case entire
    /// Seconds from the start of the video. `end` nil means until the end.
    case section(start: Double, end: Double?)
}

/// Everything yt-dlp needs for one download.
public struct DownloadRequest: Sendable {
    public var url: String
    public var outputDirectory: String
    public var range: DownloadRange
    public var quality: Quality
    /// Re-encode at the cut points so they land on the exact second. Slower.
    public var accurateCuts: Bool
    public var ffmpegPath: String?
    public var cookiesPath: String?
    /// For a recording that is still in progress. yt-dlp's default would wait for the stream to end; the
    /// native HLS downloader takes the fragments listed right now and stops.
    public var nativeHLS: Bool

    public init(
        url: String, outputDirectory: String, range: DownloadRange = .entire, quality: Quality = .source,
        accurateCuts: Bool = false, ffmpegPath: String? = nil, cookiesPath: String? = nil, nativeHLS: Bool = false
    ) {
        self.nativeHLS = nativeHLS
        self.url = url
        self.outputDirectory = outputDirectory
        self.range = range
        self.quality = quality
        self.accurateCuts = accurateCuts
        self.ffmpegPath = ffmpegPath
        self.cookiesPath = cookiesPath
    }

    /// Marker yt-dlp prints once with the final file path.
    public static let filePrefix = "TGFILE "
    /// Marker on progress lines (see `ProgressLine`).
    public static let progressTemplate =
        "download:TGP %(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(progress.fragment_index)s|%(progress.fragment_count)s"

    var fileSuffix: String {
        guard case .section(let start, let end) = range else { return "" }
        let endText = end.map(TimeCode.fileSafe) ?? "end"
        return " [\(TimeCode.fileSafe(start)) to \(endText)]"
    }

    public func arguments() -> [String] {
        var a = [
            "--no-playlist", "--newline", "--no-colors", "--no-simulate",
            "--concurrent-fragments", "4", "--retries", "10", "--fragment-retries", "10",
            "-f", quality.selector,
            "--progress-template", Self.progressTemplate,
            "--print", "after_move:\(Self.filePrefix)%(filepath)s",
            "-o", "\(outputDirectory)/%(uploader)s - %(title).100B [%(id)s]\(fileSuffix).%(ext)s",
        ]
        if quality != .audio { a += ["--merge-output-format", "mp4"] }
        if case .section(let start, let end) = range {
            a += ["--download-sections", "*\(TimeCode.format(start))-\(end.map(TimeCode.format) ?? "inf")"]
            if accurateCuts { a.append("--force-keyframes-at-cuts") }
        }
        if nativeHLS { a += ["--downloader", "m3u8:native"] }
        if let ffmpegPath { a += ["--ffmpeg-location", ffmpegPath] }
        if let cookiesPath, !cookiesPath.isEmpty { a += ["--cookies", cookiesPath] }
        a.append(url)
        return a
    }
}
