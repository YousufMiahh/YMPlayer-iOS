import SwiftUI
import UIKit

/// Live TV, Movies or Series: a category picker at the top and the list below (channels as rows,
/// movies and series as a poster grid), like the phone app. Changing category slides the new list in.
struct BrowseView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var epg: EpgStore
    @Environment(\.metrics) private var m
    let kind: Kind

    @State private var category: String?
    @State private var picking = false
    @State private var pickingFavs = false
    @State private var searching = false
    @State private var query = ""
    @State private var results: [Item]?
    @State private var searchTask: Task<Void, Never>?
    @AppStorage("guideOn") private var guideOn = false
    @FocusState private var searchFocused: Bool

    private var live: Bool { kind == .live }
    private var catKey: String { "lastCategory." + kind.rawValue }
    private var shown: [Item] { results ?? store.itemsFor(kind, category) }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: kind.title) {
                if live {
                    IconButton(icon: guideOn ? "list.bullet" : "calendar") { withAnimation(Theme.ease) { guideOn.toggle() } }
                }
            }
            bar
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            content
        }
        .task {
            await store.ensureLoaded(kind)
            if category == nil { category = startCategory() }
        }
        .onChange(of: category) { c in
            if let c = c { UserDefaults.standard.set(c, forKey: catKey) }
        }
        .onChange(of: query) { _ in runSearch() }
        .sheet(isPresented: $picking) {
            CategoryPicker(kind: kind, selection: $category, onlyFavourites: false).withStore(store)
        }
        .sheet(isPresented: $pickingFavs) {
            CategoryPicker(kind: kind, selection: $category, onlyFavourites: true).withStore(store)
        }
    }

    /// The last category you used, else Favourites if you have any, else everything.
    private func startCategory() -> String {
        if let c = UserDefaults.standard.string(forKey: catKey),
           c == Special.all || c == Special.favourites || c == Special.recent || store.visibleCategories(kind).contains(where: { $0.id == c }) {
            return c
        }
        return store.favourites(kind).isEmpty ? Special.all : Special.favourites
    }

    // MARK: [Category ▾]  [♥ Favourites]  [🔍 Search]

    @ViewBuilder
    private var bar: some View {
        if searching {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.text2)
                    TextField("Search \(kind.plural)", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3) }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button("Cancel") {
                    withAnimation(Theme.ease) {
                        searching = false
                        query = ""
                        results = nil
                    }
                }
            }
            .transition(.opacity)
        } else {
            HStack(spacing: 8) {
                Button { picking = true } label: {
                    HStack(spacing: 6) {
                        Text(store.categoryName(kind, category)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Theme.cardHi, in: Capsule())
                }
                .layoutPriority(1)
                pill("heart", "Favourites") { pickingFavs = true }
                pill("magnifyingglass", "Search") {
                    withAnimation(Theme.ease) { searching = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { searchFocused = true }
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(.primary)
            .transition(.opacity)
        }
    }

    private func pill(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                if m.wide || !live { Text(label).lineLimit(1) }
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.card, in: Capsule())
        }
    }

    // MARK: list / grid

    @ViewBuilder
    private var content: some View {
        if store.items[kind] == nil {
            if let e = store.loadError[kind] {
                VStack {
                    EmptyState(icon: "wifi.exclamationmark", title: "Couldn't load \(kind.plural)", message: e)
                    Button("Try Again") { Task { await store.ensureLoaded(kind, force: true) } }.buttonStyle(.bordered).padding(.bottom, 60)
                }
            } else {
                LoadingView(text: "Loading \(kind.plural)…")
            }
        } else {
            let list = shown
            ZStack {
                if list.isEmpty {
                    EmptyState(icon: category == Special.favourites ? "heart" : (live ? "tv" : "film"),
                               title: results != nil ? "Nothing found" : category == Special.favourites ? "No favourites yet" : "Nothing here",
                               message: results != nil ? nil : category == Special.favourites
                                   ? (live ? "Tap ♡ next to a channel to add it here." : "Press and hold a film or series and choose Add to Favourites.") : nil)
                } else if live && guideOn && results == nil {
                    PhoneGuide(channels: list)
                } else if live {
                    channelList(list)
                } else {
                    posterGrid(list)
                }
            }
            .id((category ?? "") + (results == nil ? "" : "?") + (guideOn ? "g" : ""))
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 30)), removal: .opacity))
            .animation(Theme.ease, value: category)
            .overlay(alignment: .top) {
                if let r = results {
                    Text("\(r.count) result\(r.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Theme.text3)
                        .padding(.top, -8)
                }
            }
        }
    }

    private func channelList(_ list: [Item]) -> some View {
        ScrollViewReader { proxy in
            List {
                ForEach(list) { ch in
                    ChannelRow(channel: ch) { store.play(ch, list: list) }
                        .id(ch.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 6))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: store.reselect[kind == .live ? .live : kind == .movie ? .movies : .series]) { _ in
                if let f = list.first { withAnimation(Theme.ease) { proxy.scrollTo(f.id, anchor: .top) } }
            }
        }
    }

    private func posterGrid(_ list: [Item]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: m.gridMin, maximum: m.gridMin * 1.4), spacing: m.wide ? 16 : 8)],
                          alignment: .leading, spacing: m.wide ? 20 : 14) {
                    ForEach(list) { it in
                        PosterCard(item: it, width: nil, title: store.isWatched(it) ? "✓  " + it.name : it.name,
                                   progress: store.data.progress[it.id]?.fraction) {
                            store.open(it)
                        }
                        .id(it.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: store.reselect[kind == .movie ? .movies : .series]) { _ in
                if let f = list.first { withAnimation(Theme.ease) { proxy.scrollTo(f.id, anchor: .top) } }
            }
        }
    }

    /// Same matching as the Search tab: ignores punctuation, spaces and accents; names starting with it come first.
    private func runSearch() {
        searchTask?.cancel()
        let q = query
        guard Match.Query(q).usable else {
            results = nil
            return
        }
        let k = kind
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            let idx = await store.searchIndex(k)
            let hits = await Task.detached { Match.rank(idx, q, max: 400) }.value
            if !Task.isCancelled { results = hits }
        }
    }
}

/// A channel in the list: logo, name, what's on now, and a heart.
struct ChannelRow: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var epg: EpgStore
    let channel: Item
    let action: () -> Void
    @State private var pop = false

    var body: some View {
        HStack(spacing: 14) {
            Button(action: action) {
                HStack(spacing: 14) {
                    ZStack {
                        Theme.card
                        Text(initials(channel.name)).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text3)
                        RemoteImage(url: channel.iconURL, maxPixel: 200, mode: .fit).padding(6)
                    }
                    .frame(width: 80, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(channel.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                        if let p = epg.now(channel.streamId) {
                            HStack(spacing: 6) {
                                Text(p.title).lineLimit(1)
                                ProgressLine(value: p.progress).frame(width: 34)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text2)
                        } else if let n = channel.num, !n.isEmpty {
                            Text("Channel " + n).font(.system(size: 12)).foregroundStyle(Theme.text3)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(.primary)
            Button {
                store.toggleFavourite(channel)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.easeOut(duration: 0.11)) { pop = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { withAnimation(.easeOut(duration: 0.14)) { pop = false } }
            } label: {
                let fav = store.isFavourite(channel)
                Image(systemName: fav ? "heart.fill" : "heart")
                    .font(.system(size: 18))
                    .foregroundStyle(fav ? Theme.pink : Theme.text3)
                    .scaleEffect(pop ? 1.25 : 1)
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .onAppear { epg.request(channel) }
        .contextMenu { ItemMenu(item: channel) }
    }
}

/// The category list: a search box, Favourites / All at the top, a heart to favourite each one.
/// Press and hold a category to favourite, rename or hide it.
struct CategoryPicker: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let kind: Kind
    @Binding var selection: String?
    let onlyFavourites: Bool
    @State private var filter = ""
    @State private var renaming: Category?

    private struct Entry: Identifiable {
        let id: String
        let name: String
        let icon: String
        let category: Category?
    }

    private var entries: [Entry] {
        var out: [Entry] = []
        if !onlyFavourites {
            out.append(Entry(id: Special.favourites, name: "Favourites", icon: "heart.fill", category: nil))
            if kind == .live { out.append(Entry(id: Special.recent, name: "Recent Channels", icon: "clock.arrow.circlepath", category: nil)) }
            out.append(Entry(id: Special.all, name: "All " + kind.title, icon: "square.grid.2x2", category: nil))
        }
        let cats = store.visibleCategories(kind)
        let favs = cats.filter { store.isFavCategory(kind, $0) }
        let rest = onlyFavourites ? [] : cats.filter { !store.isFavCategory(kind, $0) }
        for c in favs + rest { out.append(Entry(id: c.id, name: c.name, icon: "folder", category: c)) }
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return f.isEmpty ? out : out.filter { $0.name.lowercased().contains(f) }
    }

    var body: some View {
        NavigationStack {
            List {
                if onlyFavourites && entries.isEmpty {
                    Text(filter.isEmpty ? "Tap ♡ next to a category in the full list to add it here." : "No matches")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { e in
                    HStack(spacing: 12) {
                        Button {
                            selection = e.id
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: e.icon)
                                    .foregroundStyle(e.category == nil && e.id == Special.favourites ? Theme.pink : Color.secondary)
                                    .frame(width: 24)
                                Text(e.name).lineLimit(2).foregroundStyle(.primary)
                                Spacer()
                                if selection == e.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if let c = e.category {
                            Button { store.toggleFavCategory(kind, c) } label: {
                                Image(systemName: store.isFavCategory(kind, c) ? "heart.fill" : "heart")
                                    .foregroundStyle(store.isFavCategory(kind, c) ? Theme.pink : Color.secondary)
                                    .frame(width: 36, height: 30)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .contextMenu {
                        if let c = e.category {
                            Button { store.toggleFavCategory(kind, c) } label: {
                                Label(store.isFavCategory(kind, c) ? "Remove from Favourite Categories" : "Add to Favourite Categories", systemImage: "heart")
                            }
                            Button { renaming = c } label: { Label("Rename…", systemImage: "pencil") }
                            Button(role: .destructive) { hide(c) } label: { Label("Hide This Category", systemImage: "eye.slash") }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if let c = e.category {
                            Button(role: .destructive) { hide(c) } label: { Label("Hide", systemImage: "eye.slash") }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a category")
            .navigationTitle(onlyFavourites ? "Favourite Categories" : kind.title + " Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Text("Press and hold a category to rename or hide it")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .sheet(item: $renaming) { c in RenameSheet(kind: kind, category: c).withStore(store) }
    }

    private func hide(_ c: Category) {
        if selection == c.id { selection = Special.all }
        store.hideCategory(kind, c)
    }
}
