import Foundation

/// The parts of `yt-dlp -J` output the app uses.
public struct VideoInfo: Decodable, Sendable, Equatable {
    public var id: String
    public var title: String?
    public var uploader: String?
    public var duration: Double?
    public var isLive: Bool?
    public var thumbnail: String?
    public var webpageUrl: String?

    public static func decode(_ data: Data) throws -> VideoInfo {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(VideoInfo.self, from: data)
    }
}

/// The result of `yt-dlp -J --flat-playlist` on a channel's videos page.
public struct VideoList: Decodable, Sendable {
    public struct Entry: Decodable, Sendable {
        public var id: String?
        public var url: String?
        public var title: String?
    }
    public var entries: [Entry]?

    public static func decode(_ data: Data) throws -> VideoList {
        try JSONDecoder().decode(VideoList.self, from: data)
    }

    /// The newest video (Twitch lists newest first), as a watch URL.
    public var newestURL: String? {
        guard let e = entries?.first else { return nil }
        if let url = e.url, url.hasPrefix("http") { return url }
        if let id = e.id { return "https://www.twitch.tv/videos/\(id.replacingOccurrences(of: "v", with: ""))" }
        return nil
    }
}
