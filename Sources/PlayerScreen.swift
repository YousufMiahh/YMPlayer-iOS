import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The full-screen player, sideways on an iPhone. Tap for controls, double-tap the left or right side
/// to skip (taps add up), swipe up / down on Live TV to change channel, pinch to fill the screen.
struct PlayerScreen: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var epg: EpgStore
    @ObservedObject var player: PlayerModel
    @ObservedObject var cast: CastController
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrub: Double?
    @State private var nextHidden = false   // you closed the Next card for this one
    @State private var nextFired = false
    @State private var burst: Double = 0     // double-tap skipping adds up: "+30 sec"
    @State private var burstSide = 0
    @State private var burstTask: Task<Void, Never>?
    @State private var panel: Panel?
    @State private var pickingSubtitle = false

    static let back: Double = 5, forward: Double = 10

    enum Panel: String, Identifiable {
        case settings, tracks, picture, channels, episodes
        var id: String { rawValue }
    }

    private var item: Item? { store.session?.item }
    private var live: Bool { item?.kind == .live }

    private var title: String {
        guard let it = item else { return "" }
        if it.kind == .live { return (it.num.map { "\($0)  ·  " } ?? "") + it.name }
        return it.kind == .episode ? (it.seriesName ?? it.name) : it.name
    }

    private var subtitle: String? {
        guard let it = item else { return nil }
        switch it.kind {
        case .live: return nil
        case .episode: return [it.episodeLabel, it.name == it.seriesName ? nil : it.name].compactMap { $0 }.joined(separator: "  ·  ")
        default: return it.rating
        }
    }

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(video: player.video)
            PlayerGestures(
                onTap: tapped,
                onDoubleTap: doubleTapped,
                onSwipe: { up in if live && panel == nil { store.step(up ? 1 : -1); poke() } },
                onPinch: { out in
                    if out && player.picture != .fill { store.setPicture(.fill) }
                    else if !out && player.picture != .fit { store.setPicture(.fit) }
                })
            if player.buffering && !player.failed && !cast.isCasting {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }
            burstBubbles
            if player.failed && !cast.isCasting { failure }
            if (controls || (!player.playing && !player.buffering && !player.failed)) && !cast.isCasting {
                overlay.transition(.opacity)
            }
            if showSkip { skipButton }
            if let nx = store.upNext, showNext { nextCard(nx) }
            if cast.isCasting {
                CastingView(cast: cast, title: title, subtitle: subtitle)
                    .overlay(alignment: .topLeading) {
                        Button { store.closePlayer() } label: {
                            Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .padding(16)
                    }
                    .transition(.opacity)
            }
            if let t = store.toast {
                VStack {
                    ToastView(text: t).padding(.top, 24)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            poke()
            if let it = item, it.kind == .live { epg.request(it) }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            hideTask?.cancel()
        }
        .onChange(of: store.session?.item.id) { _ in
            if let it = item, it.kind == .live { epg.request(it) }
            nextHidden = false
            nextFired = false
            poke()
        }
        .onChange(of: player.time) { _ in
            // Netflix-style: when the card's timer fills, the next one starts
            if showNext && nextFill >= 1 && !nextFired && player.playing {
                nextFired = true
                store.playNext()
            }
        }
        .sheet(item: $panel) { p in panelView(p).withStore(store).environment(\.colorScheme, .dark) }
        .fileImporter(isPresented: $pickingSubtitle,
                      allowedContentTypes: ["srt", "vtt", "ass", "ssa", "sub"].compactMap { UTType(filenameExtension: $0) } + [.plainText],
                      allowsMultipleSelection: false) { r in
            guard case .success(let urls) = r, let u = urls.first else { return }
            // Copy it somewhere VLC can read after the security-scoped access ends
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: u, to: dest)) != nil { player.addSubtitle(dest) }
        }
        .animation(.easeOut(duration: 0.25), value: showSkip)
        .animation(.easeOut(duration: 0.3), value: showNext)
        .animation(.easeOut(duration: 0.2), value: controls)
    }

    // MARK: gestures

    private func tapped() {
        if controls {
            withAnimation(.easeOut(duration: 0.2)) { controls = false }
            hideTask?.cancel()
        } else {
            poke()
        }
    }

    private func doubleTapped(_ x: CGFloat, _ width: CGFloat) {
        guard player.url != nil, !cast.isCasting else { return }
        if live { player.togglePause(); poke(); return }
        if x < width * 0.38 { seekBy(-PlayerScreen.back, side: -1) }
        else if x > width * 0.62 { seekBy(PlayerScreen.forward, side: 1) }
        else { player.togglePause(); poke() }
    }

    /// Repeated taps add up ("+30 sec"), shown on that side of the screen.
    private func seekBy(_ d: Double, side: Int) {
        if side != burstSide { burst = 0 }
        burstSide = side
        burst += d
        player.jump(d)
        burstTask?.cancel()
        burstTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.25)) { burst = 0; burstSide = 0 } }
        }
        if controls { poke() }
    }

    private var burstBubbles: some View {
        HStack {
            if burstSide < 0 { bubble("«  −\(Int(abs(burst))) sec") }
            Spacer()
            if burstSide > 0 { bubble("+\(Int(burst)) sec  »") }
        }
        .padding(.horizontal, 60)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: burst)
    }

    private func bubble(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(.black.opacity(0.45), in: Capsule())
            .transition(.opacity.combined(with: .scale))
    }

    private func poke() {
        if !controls { withAnimation(.easeOut(duration: 0.15)) { controls = true } }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled || scrub != nil || panel != nil { return }
            withAnimation(.easeIn(duration: 0.3)) { controls = false }
        }
    }

    // MARK: Skip Intro / Next card

    /// The recap is playing (rather than the intro).
    private var skipRecap: Bool {
        guard let s = store.segments, s.hasRecap else { return false }
        return player.time >= s.recapStart - 0.5 && player.time < s.recapEnd - 1.5
    }

    private var showSkip: Bool {
        guard !live, !cast.isCasting, let s = store.segments, s.hasIntro || s.hasRecap, scrub == nil else { return false }
        let t = player.time
        return skipRecap || (s.hasIntro && t >= s.introStart - 0.5 && t < s.introEnd - 1.5)
    }

    private func skipIntro() {
        guard let s = store.segments else { return }
        let recap = skipRecap
        player.seek(recap ? s.recapEnd : s.introEnd)
        store.show(recap ? "Skipped the recap" : "Skipped the intro")
    }

    private var skipButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(action: skipIntro) {
                    Text(skipRecap ? "Skip Recap" : "Skip Intro")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20).padding(.vertical, 11)
                        .background(.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.trailing, 40)
        .padding(.bottom, controls ? 120 : 40)
        .transition(.opacity)
    }

    private static let countdown: Double = 10

    /// When the Next card shows: as the end credits start (if known), else 30 seconds before the end.
    private var cardAt: Double {
        let d = player.duration
        if let c = store.segments?.creditsStart, c > d * 0.7, c < d - 5 { return c } // earlier = a bad match
        return d - 30
    }

    private var showNext: Bool {
        guard !live, !cast.isCasting, !nextHidden, !nextFired, scrub == nil, player.duration > 120, store.upNext != nil else { return false }
        return player.time >= cardAt && player.time < player.duration - 0.5
    }

    private var nextFill: Double { min(1, max(0, (player.time - cardAt) / Self.countdown)) }

    private func nextCard(_ nx: Item) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                NextCard(item: nx, label: nx.kind == .episode && store.session?.list.contains(where: { $0.id == nx.id }) == true ? "Next Episode" : "Next in Queue",
                         fill: nextFill,
                         play: { nextFired = true; store.playNext() },
                         close: { nextHidden = true })
            }
        }
        .padding(.trailing, 40)
        .padding(.bottom, controls ? 120 : 40)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var failure: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
            Text("Couldn't play this").font(.title3.bold())
            Text("The stream didn't start. It may be offline, or your account may be in use on another device.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack {
                Button("Try Again") { player.retry() }.buttonStyle(.borderedProminent)
                Button("Close") { store.closePlayer() }.buttonStyle(.bordered).tint(.white)
            }
            .controlSize(.large)
        }
        .foregroundStyle(.white)
        .padding(26)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: controls

    private var overlay: some View {
        ZStack {
            Color.black.opacity(0.25).allowsHitTesting(false)
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom).frame(height: 120)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.6), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom).frame(height: 200)
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .modifier(SafePadding())

            centre
            if let s = scrub {
                Text(Fmt.clock(s))
                    .font(.system(size: 34, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 8)
                    .offset(y: -90)
                    .allowsHitTesting(false)
            }
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Button { store.closePlayer() } label: {
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                    .contentShape(Rectangle()) // the whole 44pt square is tappable, not just the thin arrow
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                if let s = subtitle, !s.isEmpty { Text(s).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
            }
            Spacer()
            AirPlayButton(cast: cast).frame(width: 44, height: 44)
            Button { castSheet = true } label: {
                Image(systemName: cast.mode == .chromecast ? "tv.fill" : "tv").font(.system(size: 19)).frame(width: 44, height: 44)
            }
        }
        .buttonStyle(PressableStyle())
        .sheet(isPresented: $castSheet) {
            CastPicker(cast: cast, browser: cast.browser).withStore(store).environment(\.colorScheme, .dark)
        }
    }

    @State private var castSheet = false

    /// Back 5 s / play-pause / forward 10 s (channel down / up on Live TV).
    private var centre: some View {
        HStack(spacing: 56) {
            Button { if live { store.step(-1) } else { seekBy(-PlayerScreen.back, side: -1) }; poke() } label: {
                Image(systemName: live ? "chevron.up" : "gobackward.5").font(.system(size: 30, weight: .medium)).frame(width: 60, height: 60)
            }
            Button { player.togglePause(); poke() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 44)).frame(width: 72, height: 72)
            }
            Button { if live { store.step(1) } else { seekBy(PlayerScreen.forward, side: 1) }; poke() } label: {
                Image(systemName: live ? "chevron.down" : "goforward.10").font(.system(size: 30, weight: .medium)).frame(width: 60, height: 60)
            }
        }
        .buttonStyle(PressableStyle())
        .opacity(player.buffering && !player.playing ? 0 : 1)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if live {
                liveInfo
            } else if player.duration > 0 {
                HStack(spacing: 10) {
                    Text(Fmt.clock(scrub ?? player.time)).font(.system(size: 12, weight: .medium).monospacedDigit())
                    SeekBar(value: scrub ?? player.time, total: player.duration) { v in
                        scrub = v
                        hideTask?.cancel()
                    } done: { v in
                        player.seek(v)
                        scrub = nil
                        poke()
                    }
                    Text("−" + Fmt.clock(max(0, player.duration - (scrub ?? player.time)))).font(.system(size: 12, weight: .medium).monospacedDigit())
                }
            }
            // Centred when they fit; scrolls sideways only on a narrow screen
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { actions }
                    .frame(maxWidth: .infinity)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { actions }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if live { action("list.bullet", "Channels") { panel = .channels } }
        action("gearshape", "Settings") { panel = .settings }
        if let fav = favTarget {
            action(store.isFavourite(fav) ? "heart.fill" : "heart", "Favourite") {
                store.toggleFavourite(fav)
                poke()
            }
        }
        if !live {
            action("arrow.counterclockwise", "Start Over") {
                player.seek(0)
                if !player.playing { player.togglePause() }
                store.show("Playing from the beginning")
                poke()
            }
        }
        if item?.kind == .episode { action("rectangle.stack", "Episodes") { panel = .episodes } }
        if !live, store.upNext != nil {
            action("forward.end.fill", store.hasNextEpisode ? "Next Episode" : "Next in Queue") {
                nextFired = true
                store.playNext()
            }
        }
    }

    /// Episodes add their series to Favourites.
    private var favTarget: Item? {
        guard let it = item else { return nil }
        if it.kind != .episode { return it }
        guard let sid = it.seriesId else { return nil }
        if let s = store.items[.series]?.first(where: { $0.streamId == sid }) { return s }
        var s = Item(kind: .series, streamId: sid, name: it.seriesName ?? it.name)
        s.icon = it.cover
        return s
    }

    private func action(_ icon: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 15))
                Text(label).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    /// Live TV: the channel's logo, what's on now with its progress, and what's next.
    private var liveInfo: some View {
        let progs = item.flatMap { epg.get($0.streamId) } ?? []
        let now = progs.first { $0.isNow }
        let next = progs.first { $0.start >= (now?.stop ?? Date()) }
        return HStack(spacing: 14) {
            ZStack {
                Color.white.opacity(0.15)
                RemoteImage(url: item?.iconURL, maxPixel: 200, mode: .fit).padding(6)
            }
            .frame(width: 76, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(now?.title ?? "No guide information").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if let n = now { Text(n.timeRange).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7)) }
                }
                if let n = now { ProgressLine(value: n.progress) }
                if let nx = next {
                    Text("Next: " + Fmt.hm.string(from: nx.start) + "  " + nx.title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
        }
    }

    // MARK: panels

    @ViewBuilder
    private func panelView(_ p: Panel) -> some View {
        switch p {
        case .settings: settingsPanel
        case .tracks: tracksPanel
        case .picture: picturePanel
        case .channels: channelsPanel
        case .episodes: episodesPanel
        }
    }

    /// Subtitles & Audio and Picture under one Settings button, like Netflix's cog.
    private var settingsPanel: some View {
        NavigationStack {
            List {
                Button { switchPanel(.tracks) } label: {
                    Label(live ? "Audio & Subtitles" : "Subtitles & Audio", systemImage: "captions.bubble")
                }
                Button { switchPanel(.picture) } label: {
                    HStack {
                        Label("Picture", systemImage: "aspectratio")
                        Spacer()
                        Text(player.picture == .fill ? "Fill Screen" : player.picture.title).foregroundStyle(.secondary)
                    }
                }
                if item?.kind == .episode { // what the skip-intro lookup found for this episode
                    Text("Skip Intro: " + (store.segments?.status ?? "looking up this episode…")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } } }
        }
        .presentationDetents([.medium])
    }

    private func switchPanel(_ p: Panel) {
        panel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { panel = p }
    }

    private var tracksPanel: some View {
        NavigationStack {
            List {
                Section("Subtitles") {
                    let subs = player.subtitleTracks
                    if subs.isEmpty { Text("None in this stream").foregroundStyle(.secondary) }
                    ForEach(subs) { t in
                        Button { player.setSubtitle(t.id) } label: { check(t.name, t.id == player.currentSubtitle) }
                    }
                    Button { panel = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { pickingSubtitle = true } } label: {
                        Label("Add a Subtitle File…", systemImage: "doc.badge.plus")
                    }
                }
                Section("Audio") {
                    let audio = player.audioTracks
                    if audio.isEmpty { Text("Only one").foregroundStyle(.secondary) }
                    ForEach(audio) { t in
                        Button { player.setAudio(t.id) } label: { check(t.name, t.id == player.currentAudio) }
                    }
                }
            }
            .navigationTitle(live ? "Audio & Subtitles" : "Subtitles & Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var picturePanel: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(PictureMode.allCases) { m in
                        Button { store.setPicture(m) } label: { check(m.title, m == player.picture) }
                    }
                } footer: {
                    Text("Remembered for " + (item?.kind == .episode ? "this series" : live ? "this channel" : "this film") + ". You can also pinch the picture to fill the screen.")
                }
            }
            .navigationTitle("Picture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func check(_ name: String, _ on: Bool) -> some View {
        HStack {
            Text(name).foregroundStyle(.primary)
            Spacer()
            if on { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
        }
    }

    /// The channels from the list this one was opened from; tap one to switch.
    private var channelsPanel: some View {
        let list = store.session?.list ?? []
        return NavigationStack {
            ScrollViewReader { proxy in
                List(list) { ch in
                    Button {
                        panel = nil
                        if ch.id != item?.id { store.play(ch, list: list) }
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Color.white.opacity(0.08)
                                RemoteImage(url: ch.iconURL, maxPixel: 160, mode: .fit).padding(4)
                            }
                            .frame(width: 64, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ch.name).lineLimit(1).foregroundStyle(.primary)
                                if let p = epg.now(ch.streamId) { Text(p.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer()
                            if ch.id == item?.id { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.accent) }
                        }
                    }
                    .id(ch.id)
                    .onAppear { epg.request(ch) }
                }
                .listStyle(.plain)
                .onAppear { if let id = item?.id { proxy.scrollTo(id, anchor: .center) } }
            }
            .navigationTitle("Channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } } }
        }
    }

    /// The series' episodes, every season, opened on the one playing; tap one to watch it.
    private var episodesPanel: some View {
        let list = (store.session?.list ?? []).filter { $0.kind == .episode }
        let seasons = Array(Set(list.compactMap { $0.season })).sorted()
        return NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(seasons, id: \.self) { sn in
                        Section(sn == 0 ? "Specials" : "Season \(sn)") {
                            ForEach(list.filter { $0.season == sn }) { ep in
                                Button {
                                    panel = nil
                                    if ep.id != item?.id { store.play(ep, list: list) }
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            Color.white.opacity(0.08)
                                            RemoteImage(url: ep.iconURL, maxPixel: 300)
                                        }
                                        .frame(width: 96, height: 54)
                                        .overlay(alignment: .bottom) {
                                            if let p = store.data.progress[ep.id], p.position > 0 { ProgressLine(value: p.fraction).padding(4) }
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text((ep.episode.map { "\($0). " } ?? "") + ep.name).lineLimit(2).foregroundStyle(.primary)
                                            if let d = ep.duration { Text(d).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer()
                                        if ep.id == item?.id { Image(systemName: "play.fill").foregroundStyle(Theme.accent) }
                                        else if store.isWatched(ep) { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                                    }
                                }
                                .id(ep.id)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .onAppear { if let id = item?.id { proxy.scrollTo(id, anchor: .center) } }
            }
            .navigationTitle("Episodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } } }
        }
    }
}

/// Keeps the controls clear of the notch / Dynamic Island and the home bar (the player itself goes edge to edge).
private struct SafePadding: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { g in
            content
                .padding(.leading, g.safeAreaInsets.leading)
                .padding(.trailing, g.safeAreaInsets.trailing)
                .padding(.top, g.safeAreaInsets.top)
                .padding(.bottom, max(0, g.safeAreaInsets.bottom - 8))
        }
    }
}

/// The progress bar: drag anywhere along it to move through the video.
private struct SeekBar: View {
    let value: Double
    let total: Double
    let changing: (Double) -> Void
    let done: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let f = total > 0 ? min(1, max(0, value / total)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: dragging ? 6 : 4)
                Capsule().fill(Theme.accent).frame(width: g.size.width * f, height: dragging ? 6 : 4)
                Circle().fill(.white).frame(width: dragging ? 20 : 14, height: dragging ? 20 : 14)
                    .offset(x: g.size.width * f - (dragging ? 10 : 7))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    changing(min(1, max(0, v.location.x / max(1, g.size.width))) * total)
                }
                .onEnded { v in
                    dragging = false
                    done(min(total - 1, min(1, max(0, v.location.x / max(1, g.size.width))) * total))
                })
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 32)
    }
}

/// Netflix-style "Next Episode" card: the button fills up, then the next one plays.
private struct NextCard: View {
    let item: Item
    let label: String
    let fill: Double
    let play: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: item.kind == .episode ? (item.iconURL ?? item.posterURL) : item.posterURL, maxPixel: 400)
                .frame(width: 120, height: 68)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(label.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                Text(item.kind == .episode ? (item.episodeLabel.map { $0 + "  ·  " } ?? "") + item.name : item.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: 200, alignment: .leading)
                HStack(spacing: 8) {
                    Button(action: play) {
                        ZStack(alignment: .leading) {
                            GeometryReader { g in
                                Rectangle().fill(.white).frame(width: g.size.width * fill)
                            }
                            Label("Play Now", systemImage: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .blendMode(.difference)
                                .padding(.horizontal, 12)
                        }
                        .frame(width: 120, height: 32)
                        .background(.white.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Button(action: close) {
                        Text("Hide")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(height: 32)
                            .padding(.horizontal, 12)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
            }
        }
        .padding(12)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .compositingGroup()
    }
}

/// Touch handling over the video, with UIKit's recognisers (a single tap waits for a double tap to fail).
private struct PlayerGestures: UIViewRepresentable {
    let onTap: () -> Void
    let onDoubleTap: (CGFloat, CGFloat) -> Void
    let onSwipe: (Bool) -> Void   // true = up
    let onPinch: (Bool) -> Void   // true = out (fill)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let c = context.coordinator
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.double(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.single(_:)))
        single.require(toFail: double)
        let up = UISwipeGestureRecognizer(target: c, action: #selector(Coordinator.swipeUp(_:)))
        up.direction = .up
        let down = UISwipeGestureRecognizer(target: c, action: #selector(Coordinator.swipeDown(_:)))
        down.direction = .down
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        for g in [double, single, up, down, pinch] as [UIGestureRecognizer] { v.addGestureRecognizer(g) }
        return v
    }

    func updateUIView(_ v: UIView, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject {
        var parent: PlayerGestures
        init(_ p: PlayerGestures) { parent = p }

        @objc func single(_ g: UITapGestureRecognizer) { parent.onTap() }

        @objc func double(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            parent.onDoubleTap(g.location(in: v).x, v.bounds.width)
        }

        @objc func swipeUp(_ g: UISwipeGestureRecognizer) { parent.onSwipe(true) }
        @objc func swipeDown(_ g: UISwipeGestureRecognizer) { parent.onSwipe(false) }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard g.state == .ended else { return }
            if g.scale > 1.15 { parent.onPinch(true) } else if g.scale < 0.87 { parent.onPinch(false) }
        }
    }
}
