import SwiftUI
import UIKit
import Combine

/// Settings → Home Screen: which rows show (the same rows you can switch off on the TV and phone).
enum HomeRows {
    struct Row: Identifiable {
        let key: String
        let name: String
        var id: String { key }
    }

    static let all: [Row] = [
        Row(key: "continue", name: "Continue Watching"), Row(key: "queue", name: "Your Queue"),
        Row(key: "fav_live", name: "Favourite Channels"), Row(key: "recent", name: "Recent Channels"),
        Row(key: "top_movies", name: "Top 10 Movies in the UK"), Row(key: "top_series", name: "Top 10 Series in the UK"),
        Row(key: "recommended", name: "Because You Watched…"), Row(key: "favourites", name: "My Favourites"),
        Row(key: "new_movies", name: "Recently Added Movies"), Row(key: "new_series", name: "Recently Added Series"),
    ]
    static func shows(_ key: String) -> Bool { UserDefaults.standard.object(forKey: "home." + key) as? Bool ?? true }
}

/// Home: Continue Watching, your Queue, channels, the UK Top 10s, picks based on what you watch,
/// favourites and what's new, as rows you swipe through (like the phone app).
struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var cast: CastWatch
    @Environment(\.metrics) private var m
    @AppStorage("homeRowsVersion") private var rowsVersion = 0 // bumped by Settings so Home redraws

    private func recentlyAdded(_ k: Kind) -> [Item] {
        Array(store.visibleItems(k).sorted { $0.added > $1.added }.prefix(30))
    }

    var body: some View {
        let _ = rowsVersion
        let cont = HomeRows.shows("continue") ? store.continueWatching : []
        let favChannels = HomeRows.shows("fav_live") ? store.favourites(.live) : []
        let favVod = HomeRows.shows("favourites") ? store.data.favourites.filter { $0.kind == .movie || $0.kind == .series } : []
        let recentCh = HomeRows.shows("recent") ? Array(store.data.recentChannels.prefix(20)) : []
        let newMovies = HomeRows.shows("new_movies") ? recentlyAdded(.movie) : []
        let newSeries = HomeRows.shows("new_series") ? recentlyAdded(.series) : []
        let queue = HomeRows.shows("queue") ? store.data.queue : []
        let topFilms = HomeRows.shows("top_movies") ? store.top10Films : []
        let topSeries = HomeRows.shows("top_series") ? store.top10Series : []
        let recs = HomeRows.shows("recommended") ? store.recRows : []
        let nothingYet = store.items[.movie] == nil && store.items[.series] == nil && store.items[.live] == nil
        let empty = cont.isEmpty && queue.isEmpty && favChannels.isEmpty && recentCh.isEmpty && topFilms.isEmpty && topSeries.isEmpty
            && recs.isEmpty && favVod.isEmpty && newMovies.isEmpty && newSeries.isEmpty

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: m.wide ? 26 : 20) {
                    header.id("top")

                    if nothingYet {
                        if let e = store.loadError[.live] ?? store.loadError[.movie] {
                            EmptyState(icon: "wifi.exclamationmark", title: "Couldn't load your library", message: e)
                                .frame(height: 300)
                        } else {
                            LoadingView(text: "Loading your channels, movies and series…").frame(height: 300)
                        }
                    } else if empty {
                        EmptyState(icon: "sparkles.tv", title: "Welcome to YM Player",
                                   message: "Pick Live TV, Movies or Series below to get started.")
                            .frame(height: 320)
                    }

                    if !cont.isEmpty {
                        Shelf(title: "Continue Watching", subtitle: "Hold for options") {
                            ForEach(cont, id: \.item.id) { p in
                                LandscapeCard(item: p.item, width: m.landscape,
                                              title: p.item.kind == .episode ? (p.item.seriesName ?? p.item.name) : p.item.name,
                                              subtitle: (p.item.episodeLabel.map { $0 + "  ·  " } ?? "") + (p.position > 0 ? Fmt.clock(p.duration - p.position) + " left" : "Next episode"),
                                              progress: p.position > 0 ? p.fraction : nil,
                                              action: { resume(p) },
                                              extraMenu: { AnyView(Button(role: .destructive) { store.removeFromContinue(p) } label: {
                                                  Label("Remove from Continue Watching", systemImage: "xmark.circle")
                                              }) })
                            }
                        }
                    }

                    if !queue.isEmpty {
                        Shelf(title: "Your Queue", subtitle: "Plays next, in order") {
                            ForEach(queue) { it in
                                LandscapeCard(item: it, width: m.landscape,
                                              title: it.displayTitle,
                                              subtitle: it.episodeLabel.map { $0 + "  ·  " + it.name } ?? it.rating,
                                              progress: store.data.progress[it.id]?.fraction,
                                              action: { store.play(it) },
                                              extraMenu: { AnyView(Group {
                                                  Button { store.moveInQueue(it, to: 0) } label: { Label("Move to Front", systemImage: "arrow.left.to.line") }
                                                  Button { store.moveInQueue(it, to: Int.max) } label: { Label("Move to End", systemImage: "arrow.right.to.line") }
                                              }) })
                            }
                        }
                    }

                    if !recentCh.isEmpty {
                        Shelf(title: "Recent Channels") {
                            ForEach(recentCh) { ch in ChannelCard(item: ch, width: m.channel) { store.play(ch, list: recentCh) } }
                        }
                    }

                    if !favChannels.isEmpty {
                        Shelf(title: "Favourite Channels") {
                            ForEach(favChannels) { ch in ChannelCard(item: ch, width: m.channel) { store.play(ch, list: favChannels) } }
                        }
                    }

                    if !topFilms.isEmpty {
                        Shelf(title: "Top 10 Movies in the UK") {
                            ForEach(Array(topFilms.enumerated()), id: \.element.id) { i, it in
                                RankedCard(rank: i + 1, item: it) { store.open(it) }
                            }
                        }
                    }

                    if !topSeries.isEmpty {
                        Shelf(title: "Top 10 Series in the UK") {
                            ForEach(Array(topSeries.enumerated()), id: \.element.id) { i, it in
                                RankedCard(rank: i + 1, item: it) { store.open(it) }
                            }
                        }
                    }

                    ForEach(recs) { row in
                        Shelf(title: row.title, subtitle: row.sourceId == nil ? nil : "Hold for options") {
                            ForEach(row.items) { it in
                                PosterCard(item: it, width: m.poster, subtitle: it.kind == .series ? (it.genre ?? "Series") : it.rating,
                                           action: { store.open(it) },
                                           extraMenu: recMenu(row))
                            }
                        }
                    }

                    if !favVod.isEmpty {
                        Shelf(title: "My Favourites") {
                            ForEach(favVod) { it in PosterCard(item: it, width: m.poster, subtitle: it.kind == .series ? "Series" : it.rating) { store.open(it) } }
                        }
                    }

                    if !newMovies.isEmpty {
                        Shelf(title: "Recently Added Movies") {
                            ForEach(newMovies) { it in PosterCard(item: it, width: m.poster, subtitle: it.rating) { store.open(it) } }
                        }
                    }

                    if !newSeries.isEmpty {
                        Shelf(title: "Recently Added Series") {
                            ForEach(newSeries) { it in PosterCard(item: it, width: m.poster, subtitle: it.genre) { store.open(it) } }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .refreshable { store.refreshAll() }
            .onChange(of: store.reselect[.home]) { _ in withAnimation(Theme.ease) { proxy.scrollTo("top", anchor: .top) } }
        }
    }

    /// Logo and name on the left, Cast and Settings on the right.
    private var header: some View {
        HStack(spacing: 10) {
            Image("Logo")
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("YM Player").font(.system(size: 21, weight: .bold))
                if let a = store.current, store.accounts.count > 1 {
                    Text(a.label).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
                }
            }
            Spacer()
            IconButton(icon: cast.on ? "tv.fill" : "tv", tint: cast.on ? Theme.accent : .primary) { store.showCast = true }
            IconButton(icon: "gearshape") { store.showSettings = true }
        }
        .padding(.leading, m.side)
        .padding(.trailing, m.side - 8)
        .padding(.top, 6)
    }

    /// Hold a "Because you watched X" card: stop basing rows on X.
    private func recMenu(_ row: RecRow) -> (() -> AnyView)? {
        guard row.sourceId != nil else { return nil }
        let name = row.sourceName ?? "This"
        return {
            AnyView(Button(role: .destructive) { store.blockRecommendations(row) } label: {
                Label("Don't Recommend Based on " + name, systemImage: "hand.thumbsdown")
            })
        }
    }

    private func resume(_ p: WatchProgress) {
        if p.item.kind == .episode {
            // Open the series so the rest of the episodes are there for "next episode"
            if let sid = p.item.seriesId, let s = store.items[.series]?.first(where: { $0.streamId == sid }) {
                Task {
                    if let info = try? await store.api?.seriesInfo(s) {
                        store.play(p.item, list: info.allEpisodes)
                    } else {
                        store.play(p.item)
                    }
                }
                return
            }
            store.play(p.item)
        } else {
            store.play(p.item)
        }
    }
}

/// Whether something is playing on a TV (for the Cast button's colour), without redrawing Home
/// on every tick of the cast player.
@MainActor
final class CastWatch: ObservableObject {
    @Published private(set) var on = false
    private var obs: AnyCancellable?

    init(_ cast: CastController) {
        obs = cast.$mode.map { $0 != .none }.removeDuplicates().sink { [weak self] v in self?.on = v }
    }
}
