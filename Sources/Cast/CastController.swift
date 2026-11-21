import SwiftUI
import AVFoundation
import AVKit

/// Watching on a TV: AirPlay (Apple TV and AirPlay TVs) or Chromecast / Google TV. The phone's own
/// player pauses while the TV plays; when you stop, it carries on here from where the TV got to.
///
/// The TV fetches the video straight from your provider: MP4 films, and live channels as HLS.
/// (The Mac version converts other formats on the fly; an iPhone can't run the converter.)
@MainActor
final class CastController: NSObject, ObservableObject {
    enum Mode: Equatable { case none, airplay, chromecast }

    @Published private(set) var mode: Mode = .none
    @Published private(set) var preparing = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var message: String?
    @Published private(set) var deviceName = ""

    weak var store: AppStore?
    let browser = CastBrowser()
    private var chromecast: ChromecastSession?

    /// The player AirPlay sends to the TV (never shown on the phone).
    let avPlayer: AVPlayer = {
        let p = AVPlayer()
        p.allowsExternalPlayback = true
        p.usesExternalPlaybackWhileExternalScreenIsActive = true
        p.actionAtItemEnd = .pause
        return p
    }()

    private var item: Item?
    private var live = false
    private var timeObserver: Any?
    private var externalObs: NSKeyValueObservation?
    private var rateObs: NSKeyValueObservation?
    private var pickerOpen = false

    override init() {
        super.init()
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in self?.tick(t) }
        }
        externalObs = avPlayer.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] p, _ in
            let on = p.isExternalPlaybackActive
            Task { @MainActor in self?.externalChanged(on) }
        }
        rateObs = avPlayer.observe(\.rate, options: [.new]) { [weak self] p, _ in
            let r = p.rate
            Task { @MainActor in self?.playing = r > 0 }
        }
    }

    var isCasting: Bool { mode != .none }
    var canSeek: Bool { !live }

    /// What the TV can fetch itself: the stream's address and its type, or nil.
    private func castable(_ it: Item, _ api: XtreamAPI) -> (URL, String)? {
        if it.kind == .live {
            return api.playURL(it, liveFormat: "m3u8").map { ($0, "application/x-mpegURL") }
        }
        let ext = (it.ext ?? "mp4").lowercased()
        guard let url = api.playURL(it, liveFormat: "ts") else { return nil }
        switch ext {
        case "mp4", "m4v", "mov": return (url, "video/mp4")
        case "m3u8": return (url, "application/x-mpegURL")
        case "mkv": return (url, "video/x-matroska") // Google TVs play these; older Chromecasts may not
        case "webm": return (url, "video/webm")
        default: return nil
        }
    }

    // MARK: AirPlay

    /// The AirPlay list is opening: get the stream ready for the TV in the background.
    func pickerWillOpen() {
        pickerOpen = true
        guard mode == .none, let store = store, let s = store.session, let api = store.api else { return }
        let it = s.item
        if item?.id == it.id, avPlayer.currentItem != nil { return } // already prepared
        teardown()
        item = it
        live = it.kind == .live
        let at = live ? 0 : store.player.time
        duration = live ? 0 : store.player.duration
        time = at
        message = nil
        guard let c = castable(it, api), c.1 != "video/x-matroska", c.1 != "video/webm" else {
            message = "This video's format can't be sent over AirPlay. Use Screen Mirroring from Control Centre instead."
            return
        }
        let asset = AVURLAsset(url: c.0, options: ["AVURLAssetHTTPUserAgentKey": XtreamAPI.userAgent])
        avPlayer.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        if at > 1 { avPlayer.seek(to: CMTime(seconds: at, preferredTimescale: 600)) }
    }

    func pickerDidClose() {
        pickerOpen = false
        // Nothing chosen: let go of what we prepared (a moment later, in case the TV is still connecting)
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if mode == .none && !pickerOpen && !avPlayer.isExternalPlaybackActive { teardown() }
        }
    }

    private func externalChanged(_ on: Bool) {
        if on && mode == .none {
            guard let store = store else { return }
            mode = .airplay
            message = nil
            deviceName = AVAudioSession.sharedInstance().currentRoute.outputs.first(where: { $0.portType == .airPlay })?.portName ?? ""
            if store.player.playing { store.player.togglePause() } // the phone stops; the TV takes over
            avPlayer.play()
        } else if !on && mode == .airplay {
            stop(resumeHere: true) // AirPlay turned off (here or from the TV)
        }
    }

    // MARK: Chromecast

    /// Play what's on now on this Chromecast / Google TV.
    func startChromecast(_ d: CastDevice) {
        guard let store = store, let s = store.session, let api = store.api else { return }
        if mode != .none { stop(resumeHere: false) }
        teardown()
        let it = s.item
        guard let c = castable(it, api) else {
            store.show("This video's format can't be sent to a Chromecast")
            return
        }
        item = it
        live = it.kind == .live
        let at = live ? 0 : store.player.time
        duration = live ? 0 : store.player.duration
        time = at
        deviceName = d.name
        message = nil
        mode = .chromecast
        preparing = true
        if store.player.playing { store.player.togglePause() }
        let session = ChromecastSession(device: d)
        chromecast = session
        session.onStatus = { [weak self] st in self?.chromecastStatus(st) }
        session.onClosed = { [weak self, weak session] err in
            guard let self = self, let session = session, self.chromecast === session else { return }
            self.chromecast = nil
            if self.mode == .chromecast {
                self.stop(resumeHere: true)
                if let e = err { self.store?.show(e) }
            }
        }
        session.load(url: c.0, contentType: c.1, live: live, at: at, title: titleFor(it), subtitle: subtitleFor(it), image: it.posterURL)
    }

    private func chromecastStatus(_ st: ChromecastSession.Status) {
        guard mode == .chromecast else { return }
        if st.state == "PLAYING" || st.state == "PAUSED" { preparing = false }
        if st.time.isFinite && (st.state == "PLAYING" || st.state == "PAUSED") { time = st.time }
        if duration <= 0 && st.duration > 0 { duration = st.duration }
        playing = st.state == "PLAYING" || st.state == "BUFFERING"
        if st.state == "IDLE" && st.idleReason == "ERROR" {
            preparing = false
            message = "The TV couldn't play this. Try another channel or film, or Screen Mirroring."
        }
        if st.state == "IDLE" && st.idleReason == "FINISHED" && !live && duration > 60 && time >= duration - 30 {
            store?.castFinished()
        }
    }

    private func titleFor(_ it: Item) -> String { it.kind == .episode ? (it.seriesName ?? it.name) : it.name }

    private func subtitleFor(_ it: Item) -> String? {
        it.kind == .episode ? [it.episodeLabel, it.name == it.seriesName ? nil : it.name].compactMap { $0 }.joined(separator: "  ·  ") : nil
    }

    // MARK: controls

    func togglePause() {
        if mode == .chromecast {
            if playing { chromecast?.pause() } else { chromecast?.play() }
            playing.toggle()
            return
        }
        if avPlayer.rate > 0 { avPlayer.pause() } else { avPlayer.play() }
    }

    func seek(to t: Double) {
        guard !live else { return }
        let target = max(0, duration > 0 ? min(t, duration - 5) : t)
        time = target
        if mode == .chromecast { chromecast?.seek(target); return }
        avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func jump(_ d: Double) { seek(to: time + d) }

    /// Stop watching on the TV. `resumeHere`: carry on in the phone's player from the same place.
    func stop(resumeHere: Bool) {
        let at = time
        let wasLive = live
        let was = mode
        mode = .none
        avPlayer.pause()
        if let c = chromecast { chromecast = nil; c.stop() }
        deviceName = ""
        teardown()
        guard was != .none, let store = store else { return }
        if resumeHere, store.session != nil {
            if wasLive { store.player.retry() } else {
                store.player.seek(at)
                if !store.player.playing { store.player.togglePause() }
            }
        }
    }

    private func teardown() {
        avPlayer.replaceCurrentItem(with: nil)
        item = nil
        preparing = false
    }

    private func tick(_ t: CMTime) {
        guard mode == .airplay else { return }
        let s = t.seconds
        if s.isFinite { time = s }
        if duration <= 0, let d = avPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        // Finished on the TV
        if !live, duration > 60, time >= duration - 2, avPlayer.rate == 0 {
            store?.castFinished()
        }
    }
}

/// Apple's AirPlay button, wired to the cast player.
struct AirPlayButton: UIViewRepresentable {
    @ObservedObject var cast: CastController

    func makeCoordinator() -> Coordinator { Coordinator(cast) }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        // (No `v.player` on iOS: that's macOS-only. On iPhone the picker routes the app's
        // playback, and avPlayer goes to the TV because it allows external playback.)
        v.delegate = context.coordinator
        v.prioritizesVideoDevices = true
        v.tintColor = .white
        v.activeTintColor = UIColor(red: 10 / 255, green: 132 / 255, blue: 1, alpha: 1)
        return v
    }

    func updateUIView(_ v: AVRoutePickerView, context: Context) {}

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        let cast: CastController
        init(_ c: CastController) { cast = c }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            Task { @MainActor in cast.pickerWillOpen() }
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            Task { @MainActor in cast.pickerDidClose() }
        }
    }
}

/// Shown in place of the picture while it plays on the TV.
struct CastingView: View {
    @ObservedObject var cast: CastController
    let title: String
    let subtitle: String?
    @State private var scrub: Double?

    private var tvName: String { cast.deviceName.isEmpty ? "your TV" : cast.deviceName }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: cast.mode == .chromecast ? "tv" : "airplayvideo").font(.system(size: 50, weight: .light)).foregroundStyle(Theme.accent)
            Text(cast.preparing ? "Connecting to " + tvName + "…" : "Playing on " + tvName)
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
            VStack(spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                if let s = subtitle, !s.isEmpty { Text(s).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
            }
            if cast.preparing { ProgressView().tint(.white) }
            if cast.canSeek && cast.duration > 0 {
                HStack(spacing: 12) {
                    Text(Fmt.clock(scrub ?? cast.time)).monospacedDigit()
                    Slider(value: Binding(get: { scrub ?? cast.time }, set: { scrub = $0 }), in: 0...max(cast.duration, 1),
                           onEditingChanged: { editing in
                               if !editing, let s = scrub { cast.seek(to: s); scrub = nil }
                           })
                    Text("-" + Fmt.clock(max(0, cast.duration - (scrub ?? cast.time)))).monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: 560)
            }
            HStack(spacing: 40) {
                if cast.canSeek { Button { cast.jump(-10) } label: { Image(systemName: "gobackward.10") } }
                Button { cast.togglePause() } label: { Image(systemName: cast.playing ? "pause.fill" : "play.fill").font(.system(size: 34)) }
                if cast.canSeek { Button { cast.jump(10) } label: { Image(systemName: "goforward.10") } }
            }
            .font(.system(size: 26))
            Button { cast.stop(resumeHere: true) } label: {
                Label("Stop Watching on TV", systemImage: "xmark.circle").padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .controlSize(.large)
            if let m = cast.message {
                Text(m).font(.callout).foregroundStyle(Theme.pink).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

/// The Cast list: Chromecasts and Google TVs on your network (as a sheet, like the phone app's picker).
struct CastPicker: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var cast: CastController
    @ObservedObject var browser: CastBrowser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if browser.devices.isEmpty {
                        HStack(spacing: 12) {
                            if browser.searching { ProgressView() }
                            Text(browser.searching ? "Looking for Chromecasts and Google TVs…" : "No Chromecasts found")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(browser.devices) { d in
                        Button {
                            dismiss()
                            if store.session == nil {
                                store.show("Start watching something, then choose your TV")
                            } else {
                                cast.startChromecast(d)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "tv")
                                VStack(alignment: .leading) {
                                    Text(d.name)
                                    if !d.model.isEmpty { Text(d.model).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if cast.mode == .chromecast && cast.deviceName == d.name { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                    }
                } header: {
                    Text("Chromecast & Google TV")
                } footer: {
                    Text("Your phone and the TV need to be on the same Wi-Fi. For an Apple TV or AirPlay TV, use the AirPlay button in the player.")
                }
                if cast.mode == .chromecast {
                    Section {
                        Button("Stop Watching on TV", role: .destructive) {
                            cast.stop(resumeHere: true)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Watch on TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { browser.start() }
        .presentationDetents([.medium, .large])
    }
}
