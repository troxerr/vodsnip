import Foundation

/// What a pasted Twitch link points at.
public enum TwitchURL: Equatable, Sendable {
    case vod(id: String)
    case channel(name: String)
    case other(String)

    /// The address to hand to yt-dlp.
    public var canonical: String {
        switch self {
        case .vod(let id): "https://www.twitch.tv/videos/\(id)"
        case .channel(let name): "https://www.twitch.tv/\(name)"
        case .other(let s): s
        }
    }

    private static let reserved: Set<String> = [
        "videos", "directory", "downloads", "jobs", "turbo", "settings", "p", "store", "login", "signup",
    ]

    public static func parse(_ input: String) -> TwitchURL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        // A bare number is a VOD id; a bare word is a channel name.
        if text.allSatisfy(\.isNumber) { return .vod(id: text) }
        if text.range(of: "^[A-Za-z0-9_]{3,25}$", options: .regularExpression) != nil {
            return .channel(name: text.lowercased())
        }
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: withScheme), let host = url.host?.lowercased() else { return nil }
        guard host == "twitch.tv" || host.hasSuffix(".twitch.tv") else { return nil }
        if host.hasPrefix("clips.") { return .other(withScheme) }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let first = parts.first else { return nil }
        if first == "videos", parts.count >= 2, parts[1].allSatisfy(\.isNumber) { return .vod(id: parts[1]) }
        if parts.count >= 3, parts[1] == "clip" { return .other(withScheme) }
        if reserved.contains(first.lowercased()) { return nil }
        return .channel(name: first.lowercased())
    }
}
