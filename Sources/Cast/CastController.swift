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
    /// Files the Apple TV can't open (MKV…) are repackaged on the phone while you watch.
    private var remux: AirPlayRemux?
    private var remuxSource: URL?
    /// Where the current remux started (the TV's clock counts from there).
    private var remuxOffset: Double = 0
    /// Don't try AirPlay again for something that just failed, until AirPlay is turned off.
    private var failedItem: String?
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
        // Picking the TV in the AirPlay list changes the audio route. That's the signal to hand the video
        // over: the cast player only goes to the TV once it's actually playing, so waiting for it to report
        // "external playback" first never happens (the TV just gets the phone player's sound).
        routeObs = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.routeChanged() }
        }
    }

    private var routeObs: NSObjectProtocol?

    /// The AirPlay device the sound is going to now, if any.
    private var airPlayOutput: AVAudioSessionPortDescription? {
        AVAudioSession.sharedInstance().currentRoute.outputs.first(where: { $0.portType == .airPlay })
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
        prepare()
    }

    private enum Prepared { case direct, remux(URL), unsupported }

    /// Get ready to send what's playing on the phone: straight to the TV (MP4, HLS, live) is loaded into the
    /// cast player (paused) now; anything else needs repackaging on the phone, started once the TV is chosen.
    @discardableResult
    private func prepare() -> Prepared {
        guard mode == .none, let store = store, let s = store.session, let api = store.api else { return .unsupported }
        let it = s.item
        if item?.id == it.id, avPlayer.currentItem != nil { return .direct } // already prepared
        teardown()
        item = it
        live = it.kind == .live
        let at = live ? 0 : store.player.time
        duration = live ? 0 : store.player.duration
        time = at
        message = nil
        guard let c = castable(it, api), c.1 != "video/x-matroska", c.1 != "video/webm" else {
            // MKV, AVI and the like: the phone repackages them for the TV
            if !live, let src = api.playURL(it, liveFormat: "ts") { return .remux(src) }
            message = "This video's format can't be sent over AirPlay. Use Screen Mirroring from Control Centre instead."
            return .unsupported
        }
        let asset = AVURLAsset(url: c.0, options: ["AVURLAssetHTTPUserAgentKey": XtreamAPI.userAgent])
        avPlayer.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        if at > 1 { avPlayer.seek(to: CMTime(seconds: at, preferredTimescale: 600)) }
        return .direct
    }

    func pickerDidClose() {
        pickerOpen = false
        routeChanged() // in case the route changed while the list was still on screen
        // Nothing chosen: let go of what we prepared (a moment later, in case the TV is still connecting)
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if mode == .none && !pickerOpen && !avPlayer.isExternalPlaybackActive && airPlayOutput == nil { teardown() }
        }
    }

    /// The sound moved to (or off) an AirPlay device: start or stop playing on the TV.
    private func routeChanged() {
        if let out = airPlayOutput {
            guard mode == .none, let s = store?.session, failedItem != s.item.id else { return }
            switch prepare() {
            case .direct:
                startAirPlay(name: out.portName)
            case .remux(let src):
                startAirPlay(name: out.portName, remuxing: src)
            case .unsupported:
                failedItem = s.item.id
                if let m = message { store?.show(m) }
            }
        } else {
            failedItem = nil
            if mode == .airplay, !avPlayer.isExternalPlaybackActive {
                stop(resumeHere: true) // AirPlay turned off (here, in Control Centre or from the TV)
            }
        }
    }

    /// The phone's player stops and the cast player starts, which sends the picture to the TV.
    private func startAirPlay(name: String, remuxing src: URL? = nil) {
        guard mode == .none, let store = store else { return }
        mode = .airplay
        message = nil
        deviceName = name
        if store.player.playing { store.player.togglePause() }
        if let src = src {
            startRemux(src, at: live ? 0 : store.player.time)
        } else {
            avPlayer.play()
        }
    }

    /// Repackage the file on the phone from `at` seconds and play that on the TV once it's ready.
    private func startRemux(_ src: URL, at: Double) {
        remux?.stop()
        avPlayer.replaceCurrentItem(with: nil)
        remuxSource = src
        remuxOffset = max(0, at)
        time = remuxOffset
        preparing = true
        let r = AirPlayRemux(source: src, start: remuxOffset, userAgent: XtreamAPI.userAgent)
        remux = r
        r.onReady = { [weak self, weak r] url in
            guard let self = self, let r = r, self.remux === r, self.mode == .airplay else { return }
            self.avPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
            self.avPlayer.play()
            self.preparing = false
        }
        r.onFailure = { [weak self, weak r] msg in
            guard let self = self, let r = r, self.remux === r else { return }
            self.failedItem = self.item?.id
            self.store?.show(msg)
            self.stop(resumeHere: true)
        }
        r.start()
    }

    private func externalChanged(_ on: Bool) {
        if on && mode == .none {
            startAirPlay(name: airPlayOutput?.portName ?? "")
        } else if !on && mode == .airplay, airPlayOutput == nil {
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
        if let r = remux, let src = remuxSource {
            // Within what's been made: skip there; otherwise start making it again from the new place
            let rel = target - remuxOffset
            if !preparing, rel >= 0, rel <= r.produced - 4 {
                avPlayer.seek(to: CMTime(seconds: rel, preferredTimescale: 600))
            } else {
                startRemux(src, at: target)
            }
            return
        }
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
        remux?.stop()
        remux = nil
        remuxSource = nil
        remuxOffset = 0
        avPlayer.replaceCurrentItem(with: nil)
        item = nil
        preparing = false
    }

    private func tick(_ t: CMTime) {
        guard mode == .airplay, !preparing else { return }
        let s = t.seconds
        if let r = remux {
            // The TV's clock starts where the repackaging started
            if s.isFinite { time = remuxOffset + s; r.playhead = s }
        } else {
            if s.isFinite { time = s }
            if duration <= 0, let d = avPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        }
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

/// Keeps the AirPlay player attached to a video layer. Without one, iOS can send only the audio to the TV
/// (the picture stays on the phone); with one, AirPlay hands the whole video over. It's tiny and almost invisible.
struct CastVideoLayer: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.isUserInteractionEnabled = false
        v.alpha = 0.01
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
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
        SheetPanel(title: "Watch on TV",
                   subtitle: "Your phone and the TV need to be on the same Wi-Fi. For an Apple TV or AirPlay TV, use the AirPlay button in the player.") {
            ScrollView {
                VStack(spacing: 0) {
                    SheetHeading(text: "Chromecast & Google TV")
                    if browser.devices.isEmpty {
                        HStack(spacing: 12) {
                            if browser.searching { ProgressView() }
                            Text(browser.searching ? "Looking for Chromecasts and Google TVs…" : "No Chromecasts found")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.text2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 50)
                    }
                    ForEach(browser.devices) { d in
                        SheetRow(d.name, detail: d.model.isEmpty ? nil : d.model,
                                 checked: cast.mode == .chromecast && cast.deviceName == d.name, icon: "tv") {
                            dismiss()
                            if store.session == nil {
                                store.show("Start watching something, then choose your TV")
                            } else {
                                cast.startChromecast(d)
                            }
                        }
                    }
                    if cast.mode == .chromecast {
                        SheetRow("Stop Watching on TV", destructive: true, icon: "xmark.circle", iconColor: Theme.pink) {
                            cast.stop(resumeHere: true)
                            dismiss()
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .onAppear { browser.start() }
        .presentationDetents([.medium, .large])
    }
}
