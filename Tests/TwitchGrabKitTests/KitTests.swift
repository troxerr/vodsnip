import Foundation
import Testing
@testable import TwitchGrabKit

@Suite struct TimeCodeTests {
    @Test func parses() {
        #expect(TimeCode.parse("90") == 90)
        #expect(TimeCode.parse("1:30") == 90)
        #expect(TimeCode.parse("01:02:03") == 3723)
        #expect(TimeCode.parse(" 0:00:10.5 ") == 10.5)
    }

    @Test func rejects() {
        #expect(TimeCode.parse("") == nil)
        #expect(TimeCode.parse("abc") == nil)
        #expect(TimeCode.parse("1:75") == nil)
        #expect(TimeCode.parse("1:2:3:4") == nil)
        #expect(TimeCode.parse("-5") == nil)
    }

    @Test func formats() {
        #expect(TimeCode.format(3725) == "01:02:05")
        #expect(TimeCode.fileSafe(3725) == "01-02-05")
    }
}

@Suite struct TwitchURLTests {
    @Test func vod() {
        #expect(TwitchURL.parse("https://www.twitch.tv/videos/123456") == .vod(id: "123456"))
        #expect(TwitchURL.parse("twitch.tv/videos/123456?t=1h2m") == .vod(id: "123456"))
        #expect(TwitchURL.parse("123456") == .vod(id: "123456"))
    }

    @Test func channel() {
        #expect(TwitchURL.parse("https://www.twitch.tv/Shroud") == .channel(name: "shroud"))
        #expect(TwitchURL.parse("https://twitch.tv/shroud/videos") == .channel(name: "shroud"))
        #expect(TwitchURL.parse("shroud") == .channel(name: "shroud"))
    }

    @Test func invalid() {
        #expect(TwitchURL.parse("https://example.com/videos/1") == nil)
        #expect(TwitchURL.parse("") == nil)
        #expect(TwitchURL.parse("https://www.twitch.tv/directory") == nil)
    }
}

@Suite struct DownloadRequestTests {
    @Test func entire() {
        let args = DownloadRequest(url: "https://www.twitch.tv/videos/1", outputDirectory: "/tmp/out").arguments()
        #expect(!args.contains("--download-sections"))
        #expect(args.last == "https://www.twitch.tv/videos/1")
        #expect(args.contains("--merge-output-format"))
    }

    @Test func section() {
        let r = DownloadRequest(
            url: "u", outputDirectory: "/tmp", range: .section(start: 720, end: 2730), accurateCuts: true,
            ffmpegPath: "/x/ffmpeg", cookiesPath: "/c.txt")
        let a = r.arguments()
        let i = a.firstIndex(of: "--download-sections")!
        #expect(a[i + 1] == "*00:12:00-00:45:30")
        #expect(a.contains("--force-keyframes-at-cuts"))
        #expect(a.contains("/x/ffmpeg"))
        #expect(a.contains("/c.txt"))
        #expect(a.joined(separator: " ").contains("[00-12-00 to 00-45-30]"))
    }

    @Test func openEnded() {
        let a = DownloadRequest(url: "u", outputDirectory: "/tmp", range: .section(start: 60, end: nil)).arguments()
        let i = a.firstIndex(of: "--download-sections")!
        #expect(a[i + 1] == "*00:01:00-inf")
    }

    @Test func audio() {
        let a = DownloadRequest(url: "u", outputDirectory: "/tmp", quality: .audio).arguments()
        #expect(!a.contains("--merge-output-format"))
    }
}

@Suite struct ProgressTests {
    @Test func fragments() {
        let p = ProgressLine.parse("TGP 1000|NA|5000|2000000.5|12|3|10")
        #expect(p?.fraction == 0.3)
        #expect(p?.speed == 2000000.5)
        #expect(p?.eta == 12)
    }

    @Test func bytesOnly() {
        let p = ProgressLine.parse("TGP 500|1000|NA|NA|NA|NA|NA")
        #expect(p?.fraction == 0.5)
        #expect(p?.speed == nil)
    }

    @Test func notProgress() {
        #expect(ProgressLine.parse("[download] hello") == nil)
    }
}

@Suite struct VideoInfoTests {
    @Test func decodes() throws {
        let json = #"{"id":"v1","title":"T","uploader":"U","duration":120.5,"is_live":false,"formats":[]}"#
        let i = try VideoInfo.decode(Data(json.utf8))
        #expect(i.title == "T")
        #expect(i.duration == 120.5)
        #expect(i.isLive == false)
    }

    @Test func newestEntry() throws {
        let json = #"{"entries":[{"id":"v99","url":"https://www.twitch.tv/videos/99"}]}"#
        #expect(try VideoList.decode(Data(json.utf8)).newestURL == "https://www.twitch.tv/videos/99")
    }
}

@Suite struct LiveRequestTests {
    @Test func nativeHLSForLiveRecording() {
        let a = DownloadRequest(url: "u", outputDirectory: "/tmp", nativeHLS: true).arguments()
        let i = a.firstIndex(of: "--downloader")!
        #expect(a[i + 1] == "m3u8:native")
        #expect(!a.contains("--download-sections"))
        #expect(!DownloadRequest(url: "u", outputDirectory: "/tmp").arguments().contains("--downloader"))
    }
}
