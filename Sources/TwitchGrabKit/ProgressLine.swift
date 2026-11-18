import Foundation

public struct DownloadProgress: Equatable, Sendable {
    /// 0...1, nil when yt-dlp does not know the total yet.
    public var fraction: Double?
    /// Bytes per second.
    public var speed: Double?
    /// Seconds left.
    public var eta: Double?
    public var downloadedBytes: Double?
}

/// Reads the lines made by `DownloadRequest.progressTemplate`.
public enum ProgressLine {
    public static func parse(_ line: String) -> DownloadProgress? {
        guard line.hasPrefix("TGP ") else { return nil }
        let f = line.dropFirst(4).split(separator: "|", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard f.count >= 7 else { return nil }
        let downloaded = f[0], total = f[1] ?? f[2], fragIndex = f[5], fragCount = f[6]
        var fraction: Double?
        if let fragCount, fragCount > 0, let fragIndex {
            fraction = fragIndex / fragCount
        } else if let downloaded, let total, total > 0 {
            fraction = downloaded / total
        }
        return DownloadProgress(
            fraction: fraction.map { min(1, max(0, $0)) }, speed: f[3], eta: f[4], downloadedBytes: downloaded)
    }
}
