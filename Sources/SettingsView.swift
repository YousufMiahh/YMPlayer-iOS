import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var dl: Downloader
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var updater = Updater.shared
    @AppStorage("liveFormat") private var liveFormat = "ts"
    @AppStorage("previewMode") private var previewMode = 2
    @AppStorage("homePreviews") private var homePreviews = true
    @AppStorage("appearance") private var appearance = 0
    @AppStorage("homeRowsVersion") private var homeRowsVersion = 0
    @AppStorage("subSize") private var subSize = 1
    @AppStorage("subColour") private var subColour = 0
    @AppStorage("subBackground") private var subBackground = false
    @AppStorage("subOpacity") private var subOpacity = 2
    @AppStorage("fixFrozen") private var fixFrozen = true
    @AppStorage("userAgent") private var userAgent = ""
    @State private var showAdd = false
    @State private var confirmClear: String?

    private var tagsLabel: String {
        let n = store.data.hiddenTags.count
        return n == 0 ? "Showing everything" : "\(n) hidden"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(store.accounts) { a in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.label).fontWeight(.medium)
                                Text(a.server).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if a.id == store.currentId {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                            } else {
                                Button("Switch") {
                                    store.switchTo(a.id)
                                    dismiss()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { store.removeAccount(a.id) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                    Button { showAdd = true } label: { Label("Add Account", systemImage: "plus") }
                } header: {
                    Text("Accounts")
                } footer: {
                    if let i = store.accountInfo { Text(i) } else { Text("Swipe left on an account to remove it.") }
                }

                SyncSettings(sync: store.sync)

                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("Match my iPhone").tag(0)
                        Text("Light").tag(1)
                        Text("Dark").tag(2)
                    }
                }

                Section {
                    ForEach(HomeRows.all) { r in
                        Toggle(r.name, isOn: Binding(get: { HomeRows.shows(r.key) }, set: {
                            UserDefaults.standard.set($0, forKey: "home." + r.key)
                            homeRowsVersion += 1
                        }))
                    }
                    Toggle("Film & series previews", isOn: $homePreviews)
                    if !store.data.recBlocked.isEmpty {
                        HStack {
                            Text("Because You Watched: \(store.data.recBlocked.count) turned off")
                            Spacer()
                            Button("Bring Back") {
                                store.data.recBlocked = []
                                Task { await store.loadRecs() }
                            }
                        }
                    }
                } header: {
                    Text("Home Screen")
                } footer: {
                    Text("With previews on, something you're part way through plays (muted) at the top of its page.")
                }

                Section {
                    Picker("Size", selection: $subSize) {
                        ForEach(0..<SubtitleStyle.sizes.count, id: \.self) { Text(SubtitleStyle.sizes[$0]).tag($0) }
                    }
                    Picker("Colour", selection: $subColour) {
                        ForEach(0..<SubtitleStyle.colourNames.count, id: \.self) { Text(SubtitleStyle.colourNames[$0]).tag($0) }
                    }
                    Toggle("Background behind the text", isOn: $subBackground)
                    if subBackground {
                        Picker("Background opacity", selection: $subOpacity) {
                            ForEach(0..<SubtitleStyle.opacityNames.count, id: \.self) { Text(SubtitleStyle.opacityNames[$0]).tag($0) }
                        }
                    }
                    HStack {
                        Spacer()
                        Text("This is how subtitles will look")
                            .font(.system(size: [14, 17, 20, 24][min(3, max(0, subSize))], weight: .bold))
                            .foregroundStyle(Color(hex: SubtitleStyle.colours[min(SubtitleStyle.colours.count - 1, max(0, subColour))]))
                            .shadow(color: subBackground ? .clear : .black, radius: 2)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.black.opacity(subBackground ? Double(SubtitleStyle.opacities[min(3, max(0, subOpacity))]) / 255 : 0))
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .listRowBackground(LinearGradient(colors: [Color(hex: 0x3A4A5A), Color(hex: 0x1A2230)], startPoint: .top, endPoint: .bottom))
                } header: {
                    Text("Subtitles")
                } footer: {
                    Text("Changes apply from the next video you play.")
                }

                Section {
                    Picker("Live stream format", selection: $liveFormat) {
                        Text("MPEG-TS (recommended)").tag("ts")
                        Text("HLS (m3u8)").tag("m3u8")
                    }
                    Toggle("Fix frozen video automatically", isOn: $fixFrozen)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("If the picture freezes while the sound carries on, the stream is reconnected. In the player: tap for controls, double-tap the left or right side to skip, swipe up or down on Live TV to change channel, pinch to fill the screen.")
                }

                Section {
                    NavigationLink { TagsPage() } label: {
                        HStack { Text("Countries & languages"); Spacer(); Text(tagsLabel).foregroundStyle(.secondary) }
                    }
                    NavigationLink { HiddenPage() } label: {
                        HStack { Text("Hidden categories"); Spacer(); Text("\(store.hiddenCategoryList().count)").foregroundStyle(.secondary) }
                    }
                } header: {
                    Text("Hide What You Don't Watch")
                } footer: {
                    Text("Press and hold a category in Live TV, Movies or Series to favourite, rename or hide it. Things in categories you hide yourself still turn up in search.")
                }

                Section {
                    TextField(XtreamAPI.defaultUserAgent, text: $userAgent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout)
                    if !userAgent.isEmpty { Button("Use the Default") { userAgent = "" } }
                } header: {
                    Text("User Agent")
                } footer: {
                    Text("Only change this if your provider asks you to. It's the app name YM Player gives your provider; some only let in certain apps.")
                }

                Section("Library") {
                    Button("Refresh Channels, Movies & Series") {
                        store.refreshAll()
                        dismiss()
                    }
                    Button("Clear Continue Watching", role: .destructive) { confirmClear = "continue" }
                    Button("Clear Recent Channels", role: .destructive) { store.data.recentChannels = [] }
                    Button("Clear Your Queue", role: .destructive) { store.data.queue = [] }
                    Button("Clear Watched Marks", role: .destructive) { confirmClear = "watched" }
                    if !store.data.catNames.isEmpty {
                        Button("Restore Original Category Names") { store.data.catNames = [:] }
                    }
                }

                Section {
                    LabeledContent("Version", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                                   + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") + ")")
                    Button("Check for Updates") { Updater.shared.check(manual: true) }
                    Button("What's New") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { store.showWhatsNew() }
                    }
                    Button("Show Tutorial") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { store.showTour = true }
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("Developed by Yousuf Miah")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showAdd) { LoginView(isSheet: true).withStore(store) }
            .alert(updater.notice ?? "", isPresented: Binding(get: { updater.notice != nil }, set: { if !$0 { updater.notice = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .confirmationDialog(confirmClear == "watched" ? "Clear all watched marks?" : "Clear Continue Watching?",
                                isPresented: Binding(get: { confirmClear != nil }, set: { if !$0 { confirmClear = nil } }),
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive) {
                    if confirmClear == "watched" { store.data.watched = [] } else { store.data.progress = [:] }
                    confirmClear = nil
                }
            } message: {
                Text("This also clears it on your other devices that sync.")
            }
        }
    }
}

struct TagsPage: View {
    @EnvironmentObject var store: AppStore
    @State private var tags: [TagCount] = []

    var body: some View {
        let allShown = tags.allSatisfy { !store.data.hiddenTags.contains($0.tag) }
        List {
            Section {
                if tags.isEmpty {
                    Text("Nothing to filter yet: your provider's categories aren't loaded, or they don't have country tags.").foregroundStyle(.secondary)
                }
                ForEach(tags, id: \.tag) { t in
                    Toggle(isOn: Binding(get: { !store.data.hiddenTags.contains(t.tag) }, set: { store.setTag(t.tag, hidden: !$0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(Filters.tagName(t.tag))
                                if !t.tag.hasPrefix("#") && Filters.tagName(t.tag) != t.tag { Text(t.tag).foregroundStyle(.secondary) }
                            }
                            Text("\(t.count) categor\(t.count == 1 ? "y" : "ies")").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }
            } footer: {
                Text("Turn off what you don't watch. Categories for those countries, languages and writing systems disappear everywhere, including search.")
            }
        }
        .navigationTitle("Countries & Languages")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(allShown ? "Hide All" : "Show All") { store.setTags(tags.map { $0.tag }, hidden: allShown) }
                    .disabled(tags.isEmpty)
            }
        }
        .onAppear { tags = store.detectedTags() }
    }
}

struct HiddenPage: View {
    @EnvironmentObject var store: AppStore
    @State private var rows: [(Kind, Category)] = []

    var body: some View {
        List {
            Section {
                if rows.isEmpty { Text("Nothing is hidden").foregroundStyle(.secondary) }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    Toggle(isOn: Binding(get: { !store.isHidden(r.0, r.1) }, set: { store.setHidden(r.0, r.1, !$0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.1.name)
                            Text(r.0.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Everything hidden, by you or by your countries & languages choices. Turn one on to bring it back.")
            }
        }
        .navigationTitle("Hidden Categories")
        .onAppear { rows = store.hiddenCategoryList() }
    }
}

/// Settings › Sync: on / off, and when it last synced.
struct SyncSettings: View {
    @ObservedObject var sync: SyncService

    var body: some View {
        Section {
            Toggle("Sync with your other devices", isOn: Binding(get: { sync.enabled }, set: { sync.enabled = $0 }))
            HStack {
                Text(sync.label).foregroundStyle(.secondary)
                Spacer()
                Button("Sync Now") { sync.now() }
                    .disabled(!sync.configured || !sync.enabled || sync.syncing)
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Favourites, Continue Watching, watched, your queue, categories, subtitle style and Home rows follow you to your Fire TV, Android phone, Mac and Samsung TV when they use the same login. It's encrypted on this device: the sync server can't see your login or what you watch.")
        }
    }
}
