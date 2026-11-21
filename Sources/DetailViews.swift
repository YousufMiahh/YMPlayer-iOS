import SwiftUI
import UIKit

/// A film's or series' page (full screen on a phone, a large sheet on an iPad).
struct DetailPage: View {
    let item: Item

    var body: some View {
        if item.kind == .series { SeriesDetail(item: item) } else { MovieDetail(item: item) }
    }
}

/// The picture across the top, fading into the page; something you're part way through plays in it (muted).
private struct Hero: View {
    @EnvironmentObject var store: AppStore
    let url: URL?
    let fallback: URL?
    var previewOwner: String? = nil

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background {
                ZStack {
                    Theme.card
                    if url == nil { RemoteImage(url: fallback, maxPixel: 600).blur(radius: 24).opacity(0.7) }
                    RemoteImage(url: url ?? fallback, maxPixel: 1400, mode: url == nil ? .fit : .fill)
                    if let o = previewOwner, store.pagePreviewOwner == o {
                        PagePreviewLayer(preview: store.preview)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [Theme.bg.opacity(0), Theme.bg], startPoint: .top, endPoint: .bottom).frame(height: 60)
            }
            .clipped()
    }
}

/// Round close button floating over the artwork.
private struct CloseButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(PressableStyle())
        .padding(14)
    }
}

/// Netflix's big white Play button, full width.
struct PrimaryButton: View {
    let title: String
    var icon: String = "play.fill"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .foregroundStyle(Theme.onFocus)
                .background(Theme.focus, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Netflix's grey full-width button under Play ("Play From Beginning", "Audio & Subtitles").
struct SecondaryButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .foregroundStyle(.primary)
                .background(Theme.cardHi, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Icon over label ("♡ Favourite", "Trailer"…).
struct ActionIcon: View {
    let icon: String
    let label: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 21)).foregroundStyle(tint).frame(height: 24)
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Audio & Subtitles before you start: the languages the player picks when it can.
struct AudioSubtitlesMenu<MenuLabel: View>: View {
    @AppStorage("subLang") private var subLang = ""
    @AppStorage("audioLang") private var audioLang = ""
    @ViewBuilder let label: () -> MenuLabel

    var body: some View {
        Menu {
            Picker("Subtitles", selection: $subLang) {
                Text("Subtitles Off").tag("off")
                Text("English Subtitles").tag("en")
                Text("Subtitles as the Stream Sets Them").tag("")
            }
            Picker("Audio", selection: $audioLang) {
                Text("English Audio").tag("en")
                Text("Original Audio").tag("")
            }
        } label: { label() }
    }
}

/// Resume's progress: a thin bar and "38 min left".
private struct ResumeLine: View {
    let p: WatchProgress

    var body: some View {
        HStack(spacing: 10) {
            ProgressLine(value: p.fraction)
            Text(Fmt.clock(max(0, p.duration - p.position)) + " left").font(.system(size: 12)).foregroundStyle(Theme.text2)
        }
    }
}

struct MovieDetail: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var dl: Downloader
    @Environment(\.dismiss) private var dismiss
    let item: Item
    @State private var info: VodInfo?
    @State private var trailer: String?
    @State private var art: URL?

    private var meta: String {
        var parts: [String] = []
        if let d = info?.releaseDate { parts.append(String(d.prefix(4))) }
        if let d = info?.duration { parts.append(d) }
        if let r = info?.rating ?? item.rating { parts.append(r) }
        return parts.joined(separator: "   ")
    }

    var body: some View {
        let progress = store.data.progress[item.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Hero(url: art ?? Item.url(info?.backdrop), fallback: Item.url(info?.poster) ?? item.posterURL, previewOwner: item.id)
                VStack(alignment: .leading, spacing: 12) {
                    TitleLogo(kind: .movie, name: item.name, tmdb: item.tmdb ?? info?.tmdb, height: 80, maxWidth: 280,
                              font: .system(size: 26, weight: .bold))
                    if !meta.isEmpty { Text(meta).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2) }
                    if let g = info?.genre { Text(g).font(.system(size: 13)).foregroundStyle(Theme.text2).lineLimit(1) }
                    VStack(spacing: 8) {
                        if let p = progress {
                            PrimaryButton(title: "Resume") { go(nil) }
                            ResumeLine(p: p).padding(.bottom, 2)
                            SecondaryButton(title: "Play From Beginning", icon: "arrow.counterclockwise") { go(0) }
                        } else {
                            PrimaryButton(title: "Play") { go(0) }
                            AudioSubtitlesMenu {
                                Label("Audio & Subtitles", systemImage: "captions.bubble")
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 42)
                                    .foregroundStyle(.primary)
                                    .background(Theme.cardHi, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                    .padding(.top, 2)
                    if let p = info?.plot ?? item.plot {
                        Text(p).font(.system(size: 14)).lineSpacing(2)
                    } else if info == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if let c = info?.cast { Text("Cast: " + c).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(2) }
                    if let d = info?.director { Text("Director: " + d).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1) }
                    HStack(spacing: 0) {
                        ActionIcon(icon: store.isFavourite(item) ? "heart.fill" : "heart", label: "Favourite",
                                   tint: store.isFavourite(item) ? Theme.pink : .primary) { store.toggleFavourite(item) }
                        ActionIcon(icon: store.inQueue(item) ? "checkmark" : "plus", label: "Queue") { store.toggleQueue(item) }
                        ActionIcon(icon: store.isWatched(item) ? "checkmark.circle.fill" : "checkmark.circle", label: "Watched") {
                            store.setWatched(item, !store.isWatched(item))
                        }
                        if let id = TrailerSheet.youtubeId(info?.trailer) {
                            ActionIcon(icon: "film", label: "Trailer") { trailer = id }
                        }
                        DownloadAction(dl: dl, item: item)
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .topTrailing) { CloseButton() }
        .task {
            info = try? await store.api?.vodInfo(item)
            if info?.backdrop == nil, let id = await Tmdb.findId(.movie, name: item.name, known: item.tmdb ?? info?.tmdb) {
                art = await Tmdb.art(.movie, id: id).backdrop
            }
            // Part way through: it plays (muted) in the picture at the top after a moment, from where you were
            if let p = store.data.progress[item.id], p.position > 30 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { store.startPagePreview(item, at: p.position, owner: item.id) }
            }
        }
        .onDisappear { store.stopPagePreview(owner: item.id) }
        .fullScreenCover(item: Binding(get: { trailer.map { TrailerID(id: $0) } }, set: { trailer = $0?.id })) { t in
            TrailerSheet(videoId: t.id, title: item.name)
        }
    }

    private func go(_ from: Double?) {
        store.stopPagePreview(owner: item.id)
        var it = item
        if it.tmdb == nil { it.tmdb = info?.tmdb }
        store.detail = nil
        dismiss()
        store.play(it, from: from)
    }
}

/// The Download action on a film's page, showing its progress.
private struct DownloadAction: View {
    @ObservedObject var dl: Downloader
    let item: Item

    private func look(_ e: Downloader.Entry?) -> (String, String) {
        switch e?.state {
        case .some(.done): return ("checkmark.circle.fill", "Downloaded")
        case .some(.running): return ("stop.circle", "\(Int((e?.fraction ?? 0) * 100))%")
        case .some(.waiting): return ("clock", "Waiting")
        case .some(.failed): return ("exclamationmark.arrow.circlepath", "Retry")
        case .none: return ("arrow.down.to.line", "Download")
        }
    }

    var body: some View {
        let e = dl.entry(item)
        ActionIcon(icon: look(e).0, label: look(e).1, tint: e?.state == .done ? Theme.accent : .primary) {
            if let e = e {
                if e.state == .failed { dl.retry(e) } else if e.state != .done { dl.cancel(e) }
            } else { dl.add([item]) }
        }
    }
}

struct SeriesDetail: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var dl: Downloader
    @Environment(\.dismiss) private var dismiss
    let item: Item
    @State private var info: SeriesInfo?
    @State private var failed = false
    @State private var season = 0
    @State private var trailer: String?
    @State private var art: URL?
    @State private var scrollTarget: String?

    private var lastWatched: WatchProgress? {
        store.data.progress.values.filter { $0.item.seriesId == item.streamId }.max { $0.updated < $1.updated }
    }

    /// What Resume / Play starts (Netflix): the episode you were on (the next once it's finished), or the first.
    private var target: (ep: Item, resume: Bool)? {
        guard let info = info else { return nil }
        let all = info.allEpisodes
        guard let first = all.first(where: { ($0.season ?? 1) > 0 }) ?? all.first else { return nil }
        if let lw = lastWatched, let i = all.firstIndex(where: { $0.id == lw.item.id }) {
            var t = all[i]
            if store.isWatched(t), i + 1 < all.count { t = all[i + 1] }
            return (t, true)
        }
        return (first, false)
    }

    /// "S1: Ep. 3" to resume, "S1: E1" to start.
    private func heroName(_ ep: Item, resume: Bool) -> String {
        guard let s = ep.season, let e = ep.episode else { return ep.episodeLabel ?? "" }
        return resume ? "S\(s): Ep. \(e)" : "S\(s): E\(e)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Hero(url: art ?? Item.url(info?.backdrop), fallback: Item.url(info?.cover) ?? item.posterURL, previewOwner: item.id)
                    header
                        .padding(.horizontal, 16)
                        .frame(maxWidth: 760, alignment: .leading)
                    episodes(proxy)
                        .frame(maxWidth: 760, alignment: .leading)
                }
                .padding(.bottom, 30)
            }
            .onChange(of: scrollTarget) { id in
                if let id = id { withAnimation(Theme.ease) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .topTrailing) { CloseButton() }
        .fullScreenCover(item: Binding(get: { trailer.map { TrailerID(id: $0) } }, set: { trailer = $0?.id })) { t in
            TrailerSheet(videoId: t.id, title: item.name)
        }
        .task {
            do {
                let i = try await store.api?.seriesInfo(item)
                info = i
                let keys = i?.seasons.keys.sorted() ?? []
                if let lw = lastWatched?.item.season, keys.contains(lw) { season = lw } else { season = keys.first(where: { $0 > 0 }) ?? keys.first ?? 0 }
            } catch {
                failed = true
                return
            }
            if info?.backdrop == nil, let id = await Tmdb.findId(.tv, name: info?.name ?? item.name, known: info?.tmdb ?? item.tmdb) {
                art = await Tmdb.art(.tv, id: id).backdrop
            }
            // Part way through: it plays (muted) in the picture at the top after a moment, from where you were
            if let t = target, t.resume, let p = store.data.progress[t.ep.id], p.position > 30 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { store.startPagePreview(t.ep, at: p.position, owner: item.id) }
            }
        }
        .onDisappear { store.stopPagePreview(owner: item.id) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            TitleLogo(kind: .tv, name: info?.name ?? item.name, tmdb: info?.tmdb ?? item.tmdb, height: 80, maxWidth: 280,
                      font: .system(size: 26, weight: .bold))
            let meta = [info?.releaseDate.map { String($0.prefix(4)) }, info?.rating ?? item.rating,
                        info.map { "\($0.seasons.count) Season" + ($0.seasons.count == 1 ? "" : "s") }].compactMap { $0 }
            if !meta.isEmpty { Text(meta.joined(separator: "   ")).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2) }
            if let g = info?.genre ?? item.genre { Text(g).font(.system(size: 13)).foregroundStyle(Theme.text2).lineLimit(1) }
            if let t = target {
                VStack(spacing: 8) {
                    PrimaryButton(title: (t.resume ? "Resume " : "Play ") + heroName(t.ep, resume: t.resume)) { play(t.ep) }
                    if t.resume, let p = store.data.progress[t.ep.id], p.position > 0, p.duration > 0 {
                        ResumeLine(p: p).padding(.bottom, 2)
                    }
                    if t.resume {
                        SecondaryButton(title: "Play From Beginning", icon: "arrow.counterclockwise") { play(t.ep, from: 0) }
                    } else {
                        AudioSubtitlesMenu {
                            Label("Audio & Subtitles", systemImage: "captions.bubble")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .foregroundStyle(.primary)
                                .background(Theme.cardHi, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            } else if info == nil && !failed {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            if let p = info?.plot ?? item.plot {
                Text(p).font(.system(size: 14)).lineSpacing(2).lineLimit(6)
            }
            if let c = info?.cast { Text("Cast: " + c).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(2) }
            HStack(spacing: 0) {
                ActionIcon(icon: store.isFavourite(item) ? "heart.fill" : "heart", label: "Favourite",
                           tint: store.isFavourite(item) ? Theme.pink : .primary) { store.toggleFavourite(item) }
                if let t = target {
                    ActionIcon(icon: "list.bullet", label: "Episodes") { showEpisodes(t.ep) }
                }
                if let id = TrailerSheet.youtubeId(info?.trailer) {
                    ActionIcon(icon: "film", label: "Trailer") { trailer = id }
                }
                if let info = info, !info.seasons.isEmpty {
                    let eps = info.seasons[season] ?? []
                    ActionIcon(icon: "arrow.down.to.line", label: "Download") { downloadMenu = true }
                        .confirmationDialog("Download", isPresented: $downloadMenu) {
                            Button("Download " + seasonName(season)) { dl.add(eps) }
                            if info.seasons.count > 1 { Button("Download All Seasons") { dl.add(info.allEpisodes) } }
                            if eps.contains(where: { e in let s = dl.entry(e)?.state; return s == .waiting || s == .running }) {
                                Button("Cancel " + seasonName(season) + " Downloads", role: .destructive) { dl.cancelAll(eps) }
                            }
                        }
                }
            }
            .padding(.top, 4)
        }
        .padding(.bottom, 10)
    }

    @State private var downloadMenu = false

    private func seasonName(_ s: Int) -> String { s == 0 ? "Specials" : "Season \(s)" }

    /// Episodes & More: down to the season, on the episode you'd play.
    private func showEpisodes(_ ep: Item) {
        if let s = ep.season, info?.seasons[s] != nil { season = s }
        scrollTarget = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { scrollTarget = ep.id }
    }

    @ViewBuilder
    private func episodes(_ proxy: ScrollViewProxy) -> some View {
        if let info = info {
            let seasons = info.seasons.keys.sorted()
            if seasons.isEmpty {
                EmptyState(icon: "play.rectangle", title: "No episodes yet").frame(height: 200)
            } else {
                let eps = info.seasons[season] ?? []
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Menu {
                            Picker("Season", selection: $season) {
                                ForEach(seasons, id: \.self) { s in Text(seasonLabel(s, info.seasons[s] ?? [])).tag(s) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(seasonName(season))
                                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(Theme.cardHi, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        Spacer()
                        Menu {
                            Button(store.watchedCount(eps) == eps.count ? "Mark Season as Unwatched" : "Mark Season as Watched") {
                                store.setWatched(eps, store.watchedCount(eps) != eps.count)
                            }
                            Button("Download " + seasonName(season)) { dl.add(eps) }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).frame(width: 40, height: 36)
                                .foregroundStyle(.primary)
                        }
                    }
                    SeasonDownloadLine(dl: dl, season: season, episodes: eps)
                    LazyVStack(spacing: 18) {
                        ForEach(eps) { ep in
                            EpisodeRow(episode: ep, progress: store.data.progress[ep.id], watched: store.isWatched(ep),
                                       download: dl.entry(ep)?.state) { play(ep) }
                                .id(ep.id)
                                .contextMenu {
                                    Button { play(ep) } label: { Label("Play", systemImage: "play.fill") }
                                    Button { store.setWatched(ep, !store.isWatched(ep)) } label: {
                                        Label(store.isWatched(ep) ? "Mark as Unwatched" : "Mark as Watched", systemImage: "checkmark.circle")
                                    }
                                    Button { store.toggleQueue(ep) } label: {
                                        Label(store.inQueue(ep) ? "Remove from Queue" : "Add to Queue", systemImage: "plus.circle")
                                    }
                                    if let e = dl.entry(ep) {
                                        if e.state == .done {
                                            Button(role: .destructive) { dl.delete(e) } label: { Label("Delete Download", systemImage: "trash") }
                                        } else {
                                            Button(role: .destructive) { dl.cancel(e) } label: { Label("Cancel Download", systemImage: "xmark") }
                                        }
                                    } else {
                                        Button { dl.add([ep]) } label: { Label("Download Episode", systemImage: "arrow.down.circle") }
                                    }
                                    if store.data.progress[ep.id] != nil {
                                        Button { store.data.progress[ep.id] = nil } label: { Label("Remove from Continue Watching", systemImage: "xmark.circle") }
                                    }
                                }
                        }
                    }
                    .id(season)
                    .transition(.opacity.combined(with: .offset(y: 16))) // as on the apps: a new season's episodes rise in
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .animation(Theme.ease, value: season)
            }
        } else if failed {
            EmptyState(icon: "wifi.exclamationmark", title: "Couldn't load the episodes").frame(height: 220)
        }
    }

    private func seasonLabel(_ s: Int, _ eps: [Item]) -> String {
        let name = seasonName(s)
        let w = store.watchedCount(eps)
        if w == 0 || eps.isEmpty { return name }
        return w == eps.count ? name + "  ✓" : name + "  \(w)/\(eps.count)"
    }

    private func play(_ ep: Item, from: Double? = nil) {
        let list = info?.allEpisodes ?? [ep]
        store.stopPagePreview(owner: item.id)
        store.detail = nil
        dismiss()
        store.play(ep, list: list, from: from)
    }
}

/// "Season 2: 3 of 10 downloaded · about 40 min left"
struct SeasonDownloadLine: View {
    @ObservedObject var dl: Downloader
    let season: Int
    let episodes: [Item]

    var body: some View {
        let states = episodes.compactMap { dl.entry($0)?.state }
        if states.contains(.waiting) || states.contains(.running) {
            let done = states.filter { $0 == .done }.count
            HStack(spacing: 8) {
                ProgressView()
                Text(text(done)).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
        }
    }

    private func text(_ done: Int) -> String {
        var s = (season == 0 ? "Specials" : "Season \(season)") + ": \(done) of \(episodes.count) downloaded"
        if let t = dl.timeLeft(episodes) { s += "  ·  " + Downloader.timeText(t) }
        return s
    }
}

/// Netflix-style episode: thumbnail, title and time on one line, the plot underneath.
struct EpisodeRow: View {
    let episode: Item
    let progress: WatchProgress?
    var watched = false
    var download: Downloader.State? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ZStack {
                        Theme.card
                        Image(systemName: "play.rectangle").font(.title3).foregroundStyle(Theme.text3)
                        RemoteImage(url: episode.iconURL, maxPixel: 400)
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.black.opacity(0.5), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.2))
                    }
                    .frame(width: 128, height: 72)
                    .overlay(alignment: .bottom) {
                        if let p = progress, p.position > 0 { ProgressLine(value: p.fraction).padding(.horizontal, 5).padding(.bottom, 4) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if watched { WatchedBadge().padding(4).scaleEffect(0.85) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text((episode.episode.map { "\($0). " } ?? "") + episode.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        let sub = [episode.duration, download == .done ? "Downloaded" : download == .running ? "Downloading…" : download == .waiting ? "Waiting to download" : nil]
                            .compactMap { $0 }
                        if !sub.isEmpty { Text(sub.joined(separator: "  ·  ")).font(.system(size: 12)).foregroundStyle(Theme.text2) }
                    }
                    Spacer(minLength: 0)
                }
                if let p = episode.plot {
                    Text(p).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(3).multilineTextAlignment(.leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.primary)
    }
}

struct TrailerID: Identifiable { let id: String }
