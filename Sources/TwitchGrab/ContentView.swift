import SwiftUI
import TwitchGrabKit

struct ContentView: View {
    @Environment(DownloaderModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            if model.tools == nil { toolsMissing }
            linkSection
            if let info = model.info { videoSection(info) }
            if model.info != nil { optionsSection }
            statusSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420)
    }

    // MARK: Sections

    private var toolsMissing: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("yt-dlp isn't installed", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("TwitchGrab uses yt-dlp and ffmpeg. Install them with Homebrew, then check again:")
                    .foregroundStyle(.secondary)
                Text("brew install yt-dlp ffmpeg")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button("Check Again") { model.recheckTools() }
            }
        }
    }

    private var linkSection: some View {
        @Bindable var model = model
        return Section("Twitch link") {
            HStack {
                TextField("Video or channel link", text: $model.urlText, prompt: Text("twitch.tv/videos/123456789  or  twitch.tv/channel"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.fetch() } }
                Button("Fetch") { Task { await model.fetch() } }
                    .disabled(!model.canFetch)
            }
            if model.phase == .fetching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking up video…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func videoSection(_ info: VideoInfo) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(info.title ?? "Untitled").font(.headline).lineLimit(2)
                    if model.isLiveNow {
                        Text("LIVE")
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .background(.red, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                Text(subtitle(info)).foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(_ info: VideoInfo) -> String {
        var parts: [String] = []
        if let u = info.uploader { parts.append(u) }
        if let d = info.duration {
            parts.append(model.isLiveNow ? "\(TimeCode.format(d)) recorded so far" : TimeCode.format(d))
        }
        return parts.joined(separator: " · ")
    }

    private var optionsSection: some View {
        @Bindable var model = model
        return Section("What to download") {
            Picker("Portion", selection: $model.mode) {
                ForEach(Mode.allCases) { m in
                    Text(m.title).tag(m)
                        .selectionDisabled(m == .startToNow && !model.isLiveNow)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isBusy)

            if model.mode == .range {
                HStack {
                    TextField("Start", text: $model.startText, prompt: Text("00:00:00"))
                        .frame(maxWidth: 120)
                    Text("to")
                    TextField("End", text: $model.endText, prompt: Text("end of video"))
                        .frame(maxWidth: 120)
                    Spacer()
                }
                .font(.system(.body, design: .monospaced))
                .disabled(model.isBusy)
                Toggle("Frame-accurate cuts (slower)", isOn: $model.accurateCuts)
                    .disabled(model.isBusy)
                if model.isLiveNow {
                    Text("Ranges from a stream that's still live download at about real-time speed and can come up short. Use Start → now for speed, or cut the range after the stream ends.")
                        .foregroundStyle(.secondary)
                }
            }
            if model.mode == .startToNow {
                Text("Downloads the live stream's recording from its start up to this moment.")
                    .foregroundStyle(.secondary)
            }

            Picker("Quality", selection: $model.quality) {
                ForEach(Quality.allCases) { Text($0.title).tag($0) }
            }
            .disabled(model.isBusy)

            LabeledContent("Save to") {
                HStack {
                    Text(model.outputDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                    Button("Choose…") { model.chooseFolder() }.disabled(model.isBusy)
                }
            }
            LabeledContent("Cookies (optional)") {
                HStack {
                    Text(model.cookiesPath.isEmpty ? "None" : (model.cookiesPath as NSString).lastPathComponent)
                        .foregroundStyle(.secondary)
                    Button("Choose…") { model.chooseCookies() }.disabled(model.isBusy)
                    if !model.cookiesPath.isEmpty { Button("Clear") { model.cookiesPath = "" }.disabled(model.isBusy) }
                }
            }
            .help("A cookies.txt from your browser lets yt-dlp download subscriber-only videos you can watch.")
        }
    }

    private var statusSection: some View {
        Section {
            switch model.phase {
            case .downloading:
                VStack(alignment: .leading, spacing: 8) {
                    if let f = model.progress?.fraction {
                        ProgressView(value: f)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(progressText).foregroundStyle(.secondary).monospacedDigit()
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) { model.cancel() }
                    }
                }
            case .done(let file):
                Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let file { Text((file as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Reveal in Finder") { model.reveal(file) }
                    Spacer()
                    downloadButton
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                if model.info != nil { HStack { Spacer(); downloadButton } }
            case .ready:
                HStack { Spacer(); downloadButton }
            default:
                EmptyView()
            }
            if !model.log.isEmpty && model.phase != .downloading {
                DisclosureGroup("Log") {
                    ScrollView {
                        Text(model.log.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
    }

    private var downloadButton: some View {
        Button("Download") { Task { await model.download() } }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canDownload)
    }

    private var progressText: String {
        guard let p = model.progress else { return "Starting…" }
        var parts: [String] = []
        if let f = p.fraction { parts.append("\(Int(f * 100))%") }
        if let b = p.downloadedBytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)) }
        if let s = p.speed { parts.append(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file) + "/s") }
        if let e = p.eta { parts.append(TimeCode.format(e) + " left") }
        return parts.joined(separator: " · ")
    }
}
