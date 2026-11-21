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

    private enum Sub: Hashable { case tags, hidden }
    @State private var path: [Sub] = []
    @State private var removing: Account?

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
            + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") + ")"
    }

    /// Like the Android app: a title with a back arrow, then groups of rounded rows. Tapping a row
    /// turns it on / off or moves to its next choice, right there.
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    PageTitleBar(title: "Settings") { dismiss() }
                    VStack(spacing: 0) { rows }.padding(.horizontal, 16).padding(.bottom, 40)
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(TintedBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Sub.self) { p in
                switch p {
                case .tags: TagsPage()
                case .hidden: HiddenPage()
                }
            }
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
            .confirmationDialog("Remove " + (removing?.label ?? "this account") + "?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let a = removing { store.removeAccount(a.id) }
                    removing = nil
                }
            } message: {
                Text("Its login, favourites and progress are removed from this iPhone. You can add it again at any time.")
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        Group {
            SectionLabel(text: "Accounts")
            ForEach(store.accounts) { a in
                let inUse = a.id == store.currentId
                let switchTo: (() -> Void)? = inUse ? nil : {
                    store.switchTo(a.id)
                    dismiss()
                }
                SettingRow(a.label, inUse ? "✓  In use" : "Switch", detail: a.server, action: switchTo)
            }
            SettingRow("Subscription", store.accountInfo ?? "Checking…")
            SettingRow("Add Account") { showAdd = true }
            if let cur = store.current {
                SettingRow("Remove This Account", destructive: true) { removing = cur }
            }

        }
        Group {
            SyncSettings(sync: store.sync)

        }
        Group {
            SectionLabel(text: "Appearance")
            CycleRow(label: "Theme", options: ["Match my iPhone", "Light", "Dark"], selection: $appearance)
            ToggleRow(label: "Film & Series Previews", isOn: $homePreviews)
            SettingNote(text: "With previews on, something you're part way through plays (muted) at the top of its page.")

        }
        Group {
            SectionLabel(text: "Hide What You Don't Watch")
            SettingRow("Countries & Languages", tagsLabel) { path.append(.tags) }
            SettingRow("Hidden Categories", "\(store.hiddenCategoryList().count) hidden") { path.append(.hidden) }
            if !store.data.catNames.isEmpty {
                SettingRow("Rename Categories", "Restore the original names") { store.data.catNames = [:] }
            }
            SettingNote(text: "Press and hold a category in Live TV, Movies or Series to favourite, rename or hide it. Things in categories you hide yourself still turn up in search.")

        }
        Group {
            SectionLabel(text: "Customise Home Screen")
            ForEach(HomeRows.all) { r in
                ToggleRow(label: r.name, isOn: Binding(get: { HomeRows.shows(r.key) }, set: {
                    UserDefaults.standard.set($0, forKey: "home." + r.key)
                    homeRowsVersion += 1
                }))
            }
            if !store.data.recBlocked.isEmpty {
                SettingRow("Because You Watched", "\(store.data.recBlocked.count) turned off  ·  Bring back") {
                    store.data.recBlocked = []
                    Task { await store.loadRecs() }
                }
            }

        }
        Group {
            SectionLabel(text: "Subtitles")
            CycleRow(label: "Size", options: SubtitleStyle.sizes, selection: $subSize)
            CycleRow(label: "Colour", options: SubtitleStyle.colourNames, selection: $subColour)
            ToggleRow(label: "Background", isOn: $subBackground)
            if subBackground {
                CycleRow(label: "Background Opacity", options: SubtitleStyle.opacityNames, selection: $subOpacity)
            }
            subtitleSample
            SettingNote(text: "Changes apply from the next video you play.")

        }
        Group {
            SectionLabel(text: "Playback")
            CycleRow(label: "Live Stream Format", options: ["MPEG-TS (recommended)", "HLS (m3u8)"],
                     selection: Binding(get: { liveFormat == "m3u8" ? 1 : 0 }, set: { liveFormat = $0 == 1 ? "m3u8" : "ts" }))
            ToggleRow(label: "Fix Frozen Video Automatically", isOn: $fixFrozen)
            SettingNote(text: "If the picture freezes while the sound carries on, the stream is reconnected.")

        }
        Group {
            SectionLabel(text: "User Agent")
            HStack(spacing: 10) {
                TextField(XtreamAPI.defaultUserAgent, text: $userAgent)
                    .font(.system(size: 15))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                if !userAgent.isEmpty {
                    Button("Default") { userAgent = "" }.font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.bottom, 6)
            SettingNote(text: "Only change this if your provider asks you to. Some providers only let in certain apps.")

        }
        Group {
            SectionLabel(text: "Library")
            SettingRow("Refresh Channels, Movies & Series") {
                store.refreshAll()
                dismiss()
            }
            SettingRow("Clear Continue Watching", destructive: true) { confirmClear = "continue" }
            SettingRow("Clear Recent Channels", destructive: true) { store.data.recentChannels = [] }
            SettingRow("Clear Your Queue", destructive: true) { store.data.queue = [] }
            SettingRow("Clear Watched Marks", destructive: true) { confirmClear = "watched" }

        }
        Group {
            SectionLabel(text: "About")
            SettingRow("Version", version)
            SettingRow("Check for Updates") { Updater.shared.check(manual: true) }
            SettingRow("What's New") {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { store.showWhatsNew() }
            }
            SettingRow("Show Tutorial") {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { store.showTour = true }
            }
            Text("Developed by Yousuf Miah")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)

        }
    }

    private var subtitleSample: some View {
        Text("This is how subtitles will look")
            .font(.system(size: [14, 17, 20, 24][min(3, max(0, subSize))], weight: .bold))
            .foregroundStyle(Color(hex: SubtitleStyle.colours[min(SubtitleStyle.colours.count - 1, max(0, subColour))]))
            .shadow(color: subBackground ? .clear : .black, radius: 2)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.black.opacity(subBackground ? Double(SubtitleStyle.opacities[min(3, max(0, subOpacity))]) / 255 : 0))
            .frame(maxWidth: .infinity)
            .frame(height: 90)
            .background(LinearGradient(colors: [Color(hex: 0x3A4A5A), Color(hex: 0x1A2230)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.bottom, 6)
    }
}

struct TagsPage: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [TagCount] = []

    var body: some View {
        let allShown = tags.allSatisfy { !store.data.hiddenTags.contains($0.tag) }
        ScrollView {
            VStack(spacing: 0) {
                PageTitleBar(title: "Countries & Languages") { dismiss() } trailing: {
                    if !tags.isEmpty {
                        Button(allShown ? "Hide All" : "Show All") { store.setTags(tags.map { $0.tag }, hidden: allShown) }
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                VStack(spacing: 0) {
                    SettingNote(text: "Turn off what you don't watch. Categories for those countries, languages and writing systems disappear everywhere, including search.")
                        .padding(.top, 8).padding(.bottom, 10)
                    if tags.isEmpty {
                        SettingRow("Nothing to filter yet", "Categories aren't loaded, or have no country tags")
                    }
                    ForEach(tags, id: \.tag) { t in
                        let shown = !store.data.hiddenTags.contains(t.tag)
                        let name = Filters.tagName(t.tag)
                        SettingRow(label: name + (!t.tag.hasPrefix("#") && name != t.tag ? "  ·  " + t.tag : ""),
                                   detail: "\(t.count) categor\(t.count == 1 ? "y" : "ies")",
                                   action: { store.setTag(t.tag, hidden: shown) }) {
                            Text(shown ? "Showing" : "Hidden").foregroundStyle(shown ? Theme.text2 : Theme.pink)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(TintedBackground())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { tags = store.detectedTags() }
    }
}

struct HiddenPage: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [(Kind, Category)] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PageTitleBar(title: "Hidden Categories") { dismiss() }
                VStack(spacing: 0) {
                    SettingNote(text: "Everything hidden, by you or by your countries & languages choices. Tap one to bring it back.")
                        .padding(.top, 8).padding(.bottom, 10)
                    if rows.isEmpty { SettingRow("Nothing is hidden") }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        let hidden = store.isHidden(r.0, r.1)
                        SettingRow(label: r.1.name, detail: r.0.title, action: { store.setHidden(r.0, r.1, !hidden) }) {
                            Text(hidden ? "Hidden" : "Showing").foregroundStyle(hidden ? Theme.pink : Theme.text2)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(TintedBackground())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { rows = store.hiddenCategoryList() }
    }
}

/// Settings › Sync: on / off, and when it last synced.
struct SyncSettings: View {
    @ObservedObject var sync: SyncService

    var body: some View {
        SectionLabel(text: "Sync")
        ToggleRow(label: "Sync With Your Other Devices", isOn: Binding(get: { sync.enabled }, set: { sync.enabled = $0 }))
        let canSync = sync.configured && sync.enabled && !sync.syncing
        SettingRow("Sync Now", sync.syncing ? "Syncing…" : sync.label, action: canSync ? { sync.now() } : nil)
        SettingNote(text: "Favourites, Continue Watching, watched, your queue, categories, subtitle style and Home rows follow you to your Fire TV, Android phone, Mac and Samsung TV. It's encrypted on this device: the sync server can't see your login or what you watch.")
    }
}
