import SwiftUI
import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Which ways the screen may turn: everything, except on an iPhone, where the app is upright and
    /// the player is sideways (like the Android phone app).
    static var orientations: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientations
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PlayerModel.activateAudio()
        return true
    }

    /// The player opens sideways and the rest of the app goes back upright (iPhone only; an iPad turns freely).
    static func setLandscape(_ landscape: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        orientations = landscape ? .landscape : .portrait
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            ws.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            ws.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) { _ in }
        }
    }
}

@main
struct YMPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore()
    @AppStorage("appearance") private var appearance = 0

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(store.guide)
                .environmentObject(store.downloads)
                .environmentObject(store.castWatch)
                .preferredColorScheme(Theme.scheme(appearance))
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var epg: EpgStore
    @ObservedObject private var updater = Updater.shared
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.scenePhase) private var phase
    @State private var intro = true // the logo animation at launch

    private var playing: Bool { store.session != nil }

    var body: some View {
        Group {
            if store.current == nil {
                LoginView()
            } else {
                main
            }
        }
        .environment(\.metrics, Metrics(wide: hSize == .regular))
        .overlay {
            if intro { LaunchIntro { intro = false } }
        }
        .sheet(isPresented: Binding(get: { !intro && store.whatsNew != nil && !playing && !store.showTour },
                                    set: { if !$0 { store.whatsNew = nil } })) {
            WhatsNewSheet(lines: store.whatsNew ?? [])
        }
        .sheet(isPresented: Binding(get: { !intro && store.showTour && store.current != nil && !playing },
                                    set: { if !$0 { store.finishTour() } })) {
            TourSheet().environmentObject(store).presentationDetents([.medium, .large])
        }
        .alert(item: Binding(get: { playing || intro ? nil : updater.offer }, set: { if $0 == nil { updater.offer = nil } })) { r in
            Alert(title: Text(r.name + " is available"),
                  message: Text(r.notes.isEmpty ? "A new version is on GitHub." : r.notes),
                  primaryButton: .default(Text("Download")) { updater.download(r) },
                  secondaryButton: .cancel(Text("Later")) { updater.later(r) })
        }
        .task {
            // New version on GitHub? Every launch, once things have settled (not while something's playing)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            for _ in 0..<200 {
                if store.whatsNew == nil && !store.showTour && store.session == nil { Updater.shared.check(manual: false); break }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .onChange(of: phase) { p in
            if p == .background {
                store.saveCurrentProgress()
                // The app can now run in the background (to keep feeding AirPlay); on the phone itself,
                // leaving the app still pauses the video as before
                if !store.cast.isCasting, store.player.playing { store.player.togglePause() }
            }
        }
        .tint(Theme.accent)
    }

    private var main: some View {
        ZStack {
            MainTabs()
                .sheet(item: Binding(get: { hSize == .regular ? store.detail : nil }, set: { store.detail = $0 })) { it in
                    DetailPage(item: it).withStore(store)
                }
                .fullScreenCover(item: Binding(get: { hSize == .regular ? nil : store.detail }, set: { store.detail = $0 })) { it in
                    DetailPage(item: it).withStore(store)
                }
                .sheet(isPresented: $store.showSettings) {
                    SettingsView().withStore(store)
                }
                .sheet(isPresented: Binding(get: { store.showCast && !playing }, set: { store.showCast = $0 })) {
                    CastPicker(cast: store.cast, browser: store.cast.browser).withStore(store)
                }

            if playing {
                PlayerScreen(player: store.player, cast: store.cast)
                    .environment(\.colorScheme, .dark) // video: always dark, whatever the app's mode
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: playing)
        .onChange(of: playing) { p in AppDelegate.setLandscape(p) }
    }
}

extension View {
    /// Sheets don't inherit environment objects reliably: hand them over again.
    func withStore(_ store: AppStore) -> some View {
        self.environmentObject(store)
            .environmentObject(store.guide)
            .environmentObject(store.downloads)
            .environmentObject(store.castWatch)
            .tint(Theme.accent)
    }
}

/// Six tabs along the bottom (Home, Live TV, Movies, Series, Downloads, Search), like the Android
/// app: the highlight glides across and the new page slides in from that side.
struct MainTabs: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.metrics) private var m
    @Namespace private var pill
    /// Pages you've opened stay alive, so they keep their place when you come back.
    @State private var opened: Set<Page> = [.home]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                AmbientBackground(page: store.page)
                ForEach(Page.allCases) { p in
                    if opened.contains(p) {
                        page(p)
                            .opacity(p == store.page ? 1 : 0)
                            .offset(x: p == store.page ? 0 : (Page.allCases.firstIndex(of: p)! < Page.allCases.firstIndex(of: store.page)! ? -24 : 24))
                            .allowsHitTesting(p == store.page)
                            .accessibilityHidden(p != store.page)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let t = store.toast, store.session == nil {
                    ToastView(text: t).padding(.bottom, 14)
                }
            }
            .animation(.easeOut(duration: 0.25), value: store.toast)
            tabBar
        }
        .animation(Theme.ease, value: store.page)
    }

    @ViewBuilder
    private func page(_ p: Page) -> some View {
        switch p {
        case .home: HomeView()
        case .live: BrowseView(kind: .live)
        case .movies: BrowseView(kind: .movie)
        case .series: BrowseView(kind: .series)
        case .downloads: DownloadsView(dl: store.downloads)
        case .search: SearchView()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Page.allCases) { p in
                let on = p == store.page
                Button {
                    if on {
                        store.reselect[p, default: 0] += 1 // tap again: back to the top
                    } else {
                        opened.insert(p)
                        store.page = p
                    }
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            if on {
                                Capsule().fill(Theme.cardHi)
                                    .frame(width: 56, height: 30)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                            Image(systemName: on ? p.selectedIcon : p.icon)
                                .font(.system(size: 18, weight: on ? .semibold : .regular))
                                .frame(height: 30)
                        }
                        Text(p.title)
                            .font(.system(size: 10.5, weight: on ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(on ? Color.primary : Theme.text2)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: m.wide ? 640 : .infinity)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            Theme.bar
                .overlay(alignment: .top) { Rectangle().fill(Theme.text3.opacity(0.4)).frame(height: 0.5) }
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// "What's New in YM Player 1.0.N", after an update.
struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let lines: [String]

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image("Logo").resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New").font(.system(size: 24, weight: .bold))
                    Text("YM Player " + version).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(Theme.accent).frame(width: 7, height: 7).offset(y: -2)
                            line(l)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { dismiss() } label: {
                Text("Got It").font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
    }

    /// "Skip Intro: a button…" — the part before the colon in bold.
    private func line(_ l: String) -> Text {
        if let r = l.range(of: ": "), l.distance(from: l.startIndex, to: r.lowerBound) < 40 {
            return Text(String(l[..<r.lowerBound])).bold() + Text(": " + String(l[r.upperBound...]))
        }
        return Text(l)
    }
}

/// First run (and Settings → Add Account): your provider's Xtream Codes details.
struct LoginView: View {
    var isSheet = false
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var server = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var field: Int?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image("Logo")
                    .resizable()
                    .frame(width: 88, height: 88)
                    .padding(.top, isSheet ? 20 : 50)
                Text(isSheet ? "Add an Account" : "Welcome to YM Player").font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center)
                Text("Sign in with the Xtream Codes details from your provider.")
                    .foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    input("Server address, e.g. http://example.com:8080", $server, tag: 0, keyboard: .URL)
                    input("Username", $user, tag: 1)
                    SecureField("Password", text: $pass)
                        .textContentType(.password)
                        .focused($field, equals: 2)
                        .submitLabel(.next)
                        .onSubmit { field = 3 }
                        .modifier(InputStyle())
                    input("Name for this account (optional)", $name, tag: 3)
                }
                .padding(.top, 6)
                if let e = error {
                    Text(e).foregroundStyle(Theme.pink).multilineTextAlignment(.center)
                }
                Button(action: signIn) {
                    Group {
                        if busy { ProgressView().tint(Theme.onFocus) } else { Text("Sign In").font(.system(size: 17, weight: .semibold)) }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundStyle(Theme.onFocus)
                    .background(Theme.focus, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .disabled(busy || server.trimmingCharacters(in: .whitespaces).isEmpty || user.isEmpty || pass.isEmpty)
                .opacity(busy || server.trimmingCharacters(in: .whitespaces).isEmpty || user.isEmpty || pass.isEmpty ? 0.5 : 1)
                if isSheet {
                    Button("Cancel") { dismiss() }.padding(.top, 4)
                } else {
                    Text("Developed by Yousuf Miah").font(.caption).foregroundStyle(Theme.text3).padding(.top, 20)
                }
            }
            .padding(24)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AmbientBackground(page: .home))
    }

    private func input(_ hint: String, _ text: Binding<String>, tag: Int, keyboard: UIKeyboardType = .default) -> some View {
        TextField(hint, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($field, equals: tag)
            .submitLabel(tag == 3 ? .go : .next)
            .onSubmit { if tag == 3 { signIn() } else { field = tag + 1 } }
            .modifier(InputStyle())
    }

    private func signIn() {
        guard !busy, !server.trimmingCharacters(in: .whitespaces).isEmpty, !user.isEmpty, !pass.isEmpty else { return }
        busy = true
        error = nil
        field = nil
        let a = Account(name: name, server: XtreamAPI.normalize(server), user: user.trimmingCharacters(in: .whitespaces), pass: pass)
        Task {
            do {
                _ = try await XtreamAPI(a).login()
                store.addAccount(a)
                if isSheet { dismiss() }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct InputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 16, weight: .medium))
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
