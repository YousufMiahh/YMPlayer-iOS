import SwiftUI
import UIKit
import AVFoundation
import MobileVLCKit

/// The view VLC draws into. One per player; it's moved between the full-screen player, the
/// live preview and the page previews as needed.
final class VideoHostView: UIView {
    /// The view changed size (rotation, iPad split view): Fill / Stretch follow the new shape.
    var onResize: (() -> Void)?
    private var lastSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            lastSize = bounds.size
            onResize?()
        }
    }
}

struct VideoSurface: UIViewRepresentable {
    let video: UIView

    func makeUIView(context: Context) -> UIView {
        let c = UIView()
        c.backgroundColor = .black
        c.isUserInteractionEnabled = false
        VideoSurface.attach(video, to: c)
        return c
    }

    func updateUIView(_ c: UIView, context: Context) {
        if video.superview !== c { VideoSurface.attach(video, to: c) }
    }

    static func attach(_ v: UIView, to c: UIView) {
        v.removeFromSuperview()
        v.frame = c.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        c.addSubview(v)
    }
}

/// Hands a finished VLC player to a background queue to be stopped.
private final class RetiredPlayer: @unchecked Sendable {
    let player: VLCMediaPlayer
    init(_ p: VLCMediaPlayer) { player = p }
}

struct Track: Identifiable, Hashable {
    let id: Int32
    let name: String
}

/// libVLC playback, the same engine as the TV app's live preview: plays the TS / MKV / HLS
/// streams Xtream providers send, with all audio and subtitle tracks.
@MainActor
final class PlayerModel: ObservableObject {
    /// Recreated when the subtitle style changes (VLC only reads it when it starts up).
    private(set) var vlc: VLCMediaPlayer
    private var vlcStyle: [String]
    let video = VideoHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))

    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var buffering = false
    @Published var failed = false
    @Published var ended = false
    @Published var volume: Double = (UserDefaults.standard.object(forKey: "volume") as? Double) ?? 100 {
        didSet {
            applyVolume()
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    @Published var muted = false { didSet { applyVolume() } }

    private(set) var url: URL?
    private(set) var isLive = false
    private var timer: Timer?
    private var retries = 0
    private var lastRetry = Date.distantPast

    init() {
        vlcStyle = SubtitleStyle.vlcOptions
        vlc = VLCMediaPlayer(options: vlcStyle)
        vlc.drawable = video
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        video.onResize = { [weak self] in
            Task { @MainActor in self?.applyPicture() } // turned sideways / resized: Fill / Stretch follow the new shape
        }
    }

    // MARK: picture shape

    private(set) var picture: PictureMode = .fit
    private var aspectBuf: UnsafeMutablePointer<CChar>?
    private var cropBuf: UnsafeMutablePointer<CChar>?

    func setPicture(_ m: PictureMode) {
        picture = m
        applyPicture()
        objectWillChange.send()
    }

    private func applyPicture() {
        let s = video.bounds.size
        let w = max(1, Int(s.width.rounded())), h = max(1, Int(s.height.rounded()))
        var aspect: String?, crop: String?
        switch picture {
        case .fit: break
        case .fill: crop = "\(w):\(h)"          // crop the video to the window's shape, then fit it
        case .stretch: aspect = "\(w):\(h)"     // pretend the video is the window's shape
        case .wide: aspect = "16:9"
        case .classic: aspect = "4:3"
        }
        let oldA = aspectBuf, oldC = cropBuf
        aspectBuf = aspect.flatMap { strdup($0) }
        cropBuf = crop.flatMap { strdup($0) }
        vlc.videoAspectRatio = aspectBuf
        vlc.videoCropGeometry = cropBuf
        if let o = oldA { free(o) }
        if let o = oldC { free(o) }
    }

    /// Sound plays even with the ring / silent switch off, like any video app.
    static func activateAudio() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func play(url: URL, start: Double = 0, live: Bool) {
        PlayerModel.activateAudio()
        self.url = url
        isLive = live
        retries = 0
        recoveries = 0
        open(url, start: start)
    }

    private func open(_ url: URL, start: Double) {
        // Subtitle look changed in Settings: a fresh VLC with the new style, from this video on
        let style = SubtitleStyle.vlcOptions
        if style != vlcStyle {
            vlcStyle = style
            replaceVLC()
        }
        frozenSince = nil
        lastPictures = -1
        languagesApplied = false
        let m = VLCMedia(url: url)
        m.addOption(":http-user-agent=\(XtreamAPI.userAgent)")
        m.addOption(":network-caching=\(isLive ? 2000 : 4000)")
        m.addOption(":http-reconnect")
        if start > 1 { m.addOption(":start-time=\(Int(start))") }
        vlc.media = m
        failed = false
        ended = false
        buffering = true
        time = max(0, start)
        duration = 0
        vlc.play()
        applyVolume()
        applyPicture()
    }

    /// VLC's stop() waits for the stream to let go, which can take seconds (or hang) while it's
    /// still buffering, and on the main thread that froze the app, so the Back button did nothing.
    /// The old player is stopped in the background and a fresh one takes its place straight away.
    private func replaceVLC() {
        let old = RetiredPlayer(vlc)
        vlc = VLCMediaPlayer(options: vlcStyle)
        vlc.drawable = video
        DispatchQueue.global(qos: .userInitiated).async { old.player.stop() }
    }

    func retry() {
        guard let u = url else { return }
        open(u, start: isLive ? 0 : time)
    }

    func stop() {
        url = nil
        replaceVLC()
        playing = false
        buffering = false
        failed = false
        ended = false
    }

    func togglePause() {
        if vlc.isPlaying { vlc.pause() } else { vlc.play() }
    }

    func seek(_ seconds: Double) {
        var s = max(0, seconds)
        if duration > 0 { s = min(s, duration - 2) }
        vlc.time = VLCTime(int: Int32(s * 1000))
        time = s
    }

    func jump(_ d: Double) { seek(time + d) }

    private func applyVolume() {
        let a: VLCAudio? = vlc.audio
        a?.volume = Int32(muted ? 0 : volume)
    }

    private func tick() {
        guard url != nil else { return }
        let st = vlc.state
        let t = Double(vlc.time.intValue) / 1000
        let m: VLCMedia? = vlc.media
        let len = Double(m?.length.intValue ?? 0) / 1000
        if abs(t - time) > 0.3 && t >= 0 { time = t }
        if len > 0 && abs(len - duration) > 0.5 { duration = len }
        let p = vlc.isPlaying
        if p != playing { playing = p }
        let b = !p && (st == .opening || st == .buffering)
        if b != buffering { buffering = b }

        // Live streams sometimes drop: reconnect quietly a few times before giving up
        if isLive && (st == .ended || st == .error) && retries < 5 && Date().timeIntervalSince(lastRetry) > 3 {
            retries += 1
            lastRetry = Date()
            retry()
            return
        }
        let f = st == .error
        if f != failed { failed = f }
        let e = st == .ended && !isLive
        if e != ended { ended = e }
        if p { retries = 0 }
        if p && !languagesApplied && t > 1.5 { applyLanguages() }
        checkFrozen(playing: p, buffering: b)
    }

    // MARK: Audio & Subtitles (chosen on the film / series page)

    /// "" = as the stream sets it, "off" = no subtitles, "en" = English when there is some.
    static var subtitleLanguage: String { UserDefaults.standard.string(forKey: "subLang") ?? "" }
    /// "" = as the stream sets it, "en" = English when there is some.
    static var audioLanguage: String { UserDefaults.standard.string(forKey: "audioLang") ?? "" }
    private var languagesApplied = false

    private static func isEnglish(_ name: String) -> Bool {
        let l = name.lowercased()
        return l.contains("english") || l.contains("eng") || l.contains("[en]") || l.hasPrefix("en ")
    }

    /// Once the tracks are known: the languages picked under Audio & Subtitles.
    private func applyLanguages() {
        languagesApplied = true
        let sub = PlayerModel.subtitleLanguage, aud = PlayerModel.audioLanguage
        if sub == "off" {
            if vlc.currentVideoSubTitleIndex != -1 { vlc.currentVideoSubTitleIndex = -1 }
        } else if sub == "en", let t = subtitleTracks.first(where: { $0.id >= 0 && PlayerModel.isEnglish($0.name) }) {
            vlc.currentVideoSubTitleIndex = t.id
        }
        if aud == "en", let t = audioTracks.first(where: { $0.id >= 0 && PlayerModel.isEnglish($0.name) }), t.id != vlc.currentAudioTrackIndex {
            vlc.currentAudioTrackIndex = t.id
        }
        objectWillChange.send()
    }

    // MARK: frozen picture

    /// Settings → Fix Frozen Video: playing, but no new frames for a few seconds → reconnect.
    static var fixFrozen: Bool { UserDefaults.standard.object(forKey: "fixFrozen") as? Bool ?? true }
    private var lastPictures = -1
    private var frozenSince: Date?
    private var recoveries = 0

    private func checkFrozen(playing: Bool, buffering: Bool) {
        guard PlayerModel.fixFrozen, playing, !buffering, vlc.hasVideoOut, let m = vlc.media else {
            frozenSince = nil
            return
        }
        let shown = Int(m.numberOfDisplayedPictures)
        if shown != lastPictures {
            lastPictures = shown
            frozenSince = nil
            return
        }
        if frozenSince == nil { frozenSince = Date(); return }
        if let f = frozenSince, Date().timeIntervalSince(f) > 4, recoveries < 3 {
            recoveries += 1
            frozenSince = nil
            lastPictures = -1
            retry() // live: from now; films: from where it froze
        }
    }

    // MARK: tracks

    var audioTracks: [Track] { tracks(vlc.audioTrackIndexes, vlc.audioTrackNames) }
    var subtitleTracks: [Track] { tracks(vlc.videoSubTitlesIndexes, vlc.videoSubTitlesNames) }

    var currentAudio: Int32 { vlc.currentAudioTrackIndex }
    var currentSubtitle: Int32 { vlc.currentVideoSubTitleIndex }

    func setAudio(_ id: Int32) {
        vlc.currentAudioTrackIndex = id
        objectWillChange.send()
    }

    func setSubtitle(_ id: Int32) {
        vlc.currentVideoSubTitleIndex = id
        objectWillChange.send()
    }

    func addSubtitle(_ url: URL) {
        _ = vlc.addPlaybackSlave(url, type: .subtitle, enforce: true)
        objectWillChange.send()
    }

    private func tracks(_ ids: [Any]?, _ names: [Any]?) -> [Track] {
        let i = (ids ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        let n = (names ?? []).map { "\($0)" }
        return zip(i, n).map { Track(id: $0.0, name: $0.1) }
    }
}

