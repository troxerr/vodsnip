import AppKit
import SwiftUI
import TwitchGrabKit

/// One column, three zones: the link bar, what you chose (empty state, video, options), and the action bar.
struct ContentView: View {
    @Environment(DownloaderModel.self) private var model
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                if model.tools == nil { ToolsMissingCard() }
                LinkBar()
                if case .failed(let message) = model.phase { ErrorBanner(message: message) }
                if model.phase == .fetching && model.info == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking up video…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else if let info = model.info {
                    VideoCard(info: info)
                    OptionsCard(showAdvanced: $showAdvanced)
                    if !model.log.isEmpty && model.phase != .downloading { LogDisclosure() }
                } else if model.phase != .fetching {
                    EmptyHero()
                }
            }
            .padding(20)

            if model.info != nil {
                Divider()
                ActionBar()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.bar)
            }
        }
        .frame(width: 560)
        .onAppear {
            // Open calm: nothing focused, no ring, no blinking cursor.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .animation(.snappy(duration: 0.25), value: model.info != nil)
        .task {
            // TWITCHGRAB_URL=<link> TwitchGrab   open with a link already fetched (for screenshots and tests)
            if let url = ProcessInfo.processInfo.environment["TWITCHGRAB_URL"], !url.isEmpty {
                model.urlText = url
                await model.fetch()
                if ProcessInfo.processInfo.environment["TWITCHGRAB_MODE"] == "range" {
                    model.mode = .range
                    model.startText = "01:12:00"
                    model.endText = "01:45:30"
                }
            }
        }
    }
}

// MARK: - Link bar

private struct LinkBar: View {
    @Environment(DownloaderModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("Twitch video or channel link", text: $model.urlText)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await model.fetch() } }
                if !model.urlText.isEmpty {
                    Button { model.urlText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                    .accessibilityLabel("Clear link")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            Button("Paste", systemImage: "doc.on.clipboard") {
                if let s = NSPasteboard.general.string(forType: .string) {
                    model.urlText = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await model.fetch() }
                }
            }
            .labelStyle(.iconOnly)
            .help("Paste a link and fetch it")
            .disabled(model.isBusy)

            Button("Fetch") { Task { await model.fetch() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canFetch)
        }
        .controlSize(.large)
    }
}

// MARK: - Empty state and banners

private struct EmptyHero: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("Save Twitch video").font(.title2.bold())
            Text("Paste a video link to keep a whole stream or just one part of it. Paste a channel that's live to grab the stream from its start.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
            HStack(spacing: 16) {
                Label("Whole video", systemImage: "film")
                Label("Time range", systemImage: "scissors")
                Label("Live so far", systemImage: "dot.radiowaves.left.and.right")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
    }
}

private struct ToolsMissingCard: View {
    @Environment(DownloaderModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("yt-dlp isn't installed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("TwitchGrab uses yt-dlp and ffmpeg. Install them with Homebrew, then check again:")
                .foregroundStyle(.secondary)
            Text("brew install yt-dlp ffmpeg")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            Button("Check Again") { model.recheckTools() }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Video

private struct VideoCard: View {
    @Environment(DownloaderModel.self) private var model
    let info: VideoInfo

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Thumbnail(urlString: info.thumbnail, isLive: model.isLiveNow)
                .frame(width: 160, height: 90) // grid: ok 16:9 thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title ?? "Untitled")
                    .font(.headline)
                    .lineLimit(3)
                if let u = info.uploader {
                    Label(u, systemImage: "person.fill").foregroundStyle(.secondary)
                }
                if let d = info.duration {
                    Label(
                        model.isLiveNow ? "\(TimeCode.format(d)) recorded so far" : TimeCode.format(d),
                        systemImage: "clock"
                    )
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
    }
}

private struct Thumbnail: View {
    let urlString: String?
    let isLive: Bool

    private var url: URL? {
        // Twitch serves a "processing" placeholder while a live recording is still being made.
        guard let s = urlString, !s.contains("404_processing") else { return nil }
        return URL(string: s)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                default:
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "play.rectangle.fill").font(.title).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 160, height: 90) // grid: ok 16:9 thumbnail
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if isLive {
                // Text over user content sits on a solid capsule so it stays readable.
                Text("LIVE")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.red, in: Capsule())
                    .padding(8)
            }
        }
        .accessibilityLabel(isLive ? "Live stream thumbnail" : "Video thumbnail")
    }
}

// MARK: - Options

private struct OptionsCard: View {
    @Environment(DownloaderModel.self) private var model
    @Binding var showAdvanced: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    RowLabel("Portion")
                    Picker("Portion", selection: $model.mode) {
                        ForEach(Mode.allCases) { m in
                            Text(m.title).tag(m).selectionDisabled(m == .startToNow && !model.isLiveNow)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if model.mode == .range {
                    GridRow {
                        RowLabel("Range")
                        HStack(spacing: 8) {
                            TimeField(title: "Start", prompt: "00:00:00", text: $model.startText)
                            Text("to").foregroundStyle(.secondary)
                            TimeField(title: "End", prompt: "end", text: $model.endText)
                            Text(rangeLength).foregroundStyle(.secondary).monospacedDigit()
                            Spacer(minLength: 0)
                        }
                    }
                }

                GridRow {
                    RowLabel("Quality")
                    HStack {
                        Picker("Quality", selection: $model.quality) {
                            ForEach(Quality.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Spacer(minLength: 0)
                    }
                }

                GridRow {
                    RowLabel("Save to")
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(abbreviated(model.outputDirectory))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") { model.chooseFolder() }
                    }
                }
            }
            .disabled(model.isBusy)

            if model.mode == .startToNow {
                Note("Downloads the live stream's recording from its start up to the moment you click Download.", symbol: "info.circle")
            }
            if model.mode == .range && model.isLiveNow {
                Note("Ranges from a stream that's still live download at about real-time speed and can come up short. Use Start → now for speed, or cut the range after the stream ends.", symbol: "exclamationmark.circle")
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    if model.mode == .range {
                        Toggle("Frame-accurate cuts (slower)", isOn: $model.accurateCuts)
                    }
                    HStack(spacing: 8) {
                        Text("Cookies").foregroundStyle(.secondary)
                        Text(model.cookiesPath.isEmpty ? "None" : (model.cookiesPath as NSString).lastPathComponent)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") { model.chooseCookies() }
                        if !model.cookiesPath.isEmpty { Button("Clear") { model.cookiesPath = "" } }
                    }
                    .help("A cookies.txt from your browser lets yt-dlp download subscriber-only videos you can watch.")
                }
                .padding(.top, 12)
                .disabled(model.isBusy)
            }
        }
        .card()
    }

    private func abbreviated(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var rangeLength: String {
        guard let s = TimeCode.parse(model.startText) else { return "" }
        let end = TimeCode.parse(model.endText) ?? model.info?.duration
        guard let end, end > s else { return "" }
        return "· " + TimeCode.format(end - s)
    }
}

private struct RowLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

private struct TimeField: View {
    let title: String
    let prompt: String
    @Binding var text: String

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .multilineTextAlignment(.center)
            .frame(width: 96)
            .accessibilityLabel("\(title) time")
    }
}

private struct Note: View {
    let text: String
    let symbol: String
    init(_ text: String, symbol: String) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Action bar

private struct ActionBar: View {
    @Environment(DownloaderModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .downloading:
                VStack(alignment: .leading, spacing: 4) {
                    if let f = model.progress?.fraction {
                        ProgressView(value: f)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(progressText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Button("Cancel", role: .cancel) { model.cancel() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            case .fetching:
                ProgressView().controlSize(.small)
                Text("Reading video info…").foregroundStyle(.secondary)
                Spacer()
            case .done(let file):
                Label {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Saved").font(.headline)
                        if let file {
                            Text((file as NSString).lastPathComponent)
                                .font(.callout).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                }
                Spacer()
                Button("Show in Finder") { model.reveal(file) }.controlSize(.large)
                downloadButton("Download Again", prominent: false)
            default:
                Text(summary).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                downloadButton("Download", prominent: true)
            }
        }
    }

    private func downloadButton(_ title: String, prominent: Bool) -> some View {
        Button(title, systemImage: "arrow.down.circle.fill") { Task { await model.download() } }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(prominent ? .accentColor : .secondary)
            .disabled(!model.canDownload)
    }

    private var summary: String {
        switch model.mode {
        case .entire: "Whole video"
        case .startToNow: "From the start until now"
        case .range: "Selected range"
        }
    }

    private var progressText: String {
        guard let p = model.progress else { return "Starting…" }
        var parts: [String] = []
        if let f = p.fraction { parts.append("\(Int(f * 100))%") }
        if let b = p.downloadedBytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)) }
        if let s = p.speed { parts.append(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file) + "/s") }
        if let e = p.eta { parts.append(TimeCode.format(e) + " left") }
        return parts.isEmpty ? "Working…" : parts.joined(separator: " · ")
    }
}

// MARK: - Log

private struct LogDisclosure: View {
    @Environment(DownloaderModel.self) private var model

    var body: some View {
        DisclosureGroup("Log") {
            ScrollView {
                Text(model.log.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 120)
            .padding(.top, 8)
        }
    }
}

// MARK: - Card style

private extension View {
    /// A content group: system control background with a hairline, concentric 12 pt corners.
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}
