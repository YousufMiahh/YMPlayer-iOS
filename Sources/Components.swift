import SwiftUI
import UIKit

/// The same look as the TV, phone and Mac apps, in their dark and light themes: near-black navy (or
/// soft grey), system blue, see-through surfaces. Each colour follows the app's light / dark mode.
enum Theme {
    static let accent = Color(hex: 0x0A84FF)            // system blue
    static let pink = Color(hex: 0xFF453A)              // hearts (the apps' red)
    static let bg = dyn(ui(0x0A0B12), ui(0xF2F2F7))
    static let bar = dyn(ui(0x0B0B10, 0.95), ui(0xF7F7FA, 0.96))   // the tab bar
    static let card = dyn(.white.withAlphaComponent(0.10), .black.withAlphaComponent(0.07))     // SURFACE
    static let cardHi = dyn(.white.withAlphaComponent(0.18), .black.withAlphaComponent(0.13))   // SURFACE_HI
    static let text2 = dyn(ui(0xEBEBF5, 0.60), ui(0x3C3C43, 0.60))
    static let text3 = dyn(ui(0xEBEBF5, 0.30), ui(0x3C3C43, 0.36))
    static let focus = dyn(.white, ui(0x1D1D1F))         // the TV app's focus highlight / Netflix's white Play button
    static let onFocus = dyn(ui(0x0B0B0F), .white)
    /// A critically damped spring (no overshoot): it starts from wherever things are and at the speed
    /// they're already moving, so a transition can be interrupted and turned round without a jump.
    static let ease = Animation.spring(response: 0.36, dampingFraction: 1)

    static func ui(_ hex: UInt32, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// One colour for dark mode, another for light.
    static func dyn(_ dark: UIColor, _ light: UIColor) -> Color {
        Color(uiColor: UIColor { t in t.userInterfaceStyle == .dark ? dark : light })
    }

    /// Settings → Appearance: 0 = match the phone, 1 = light, 2 = dark.
    static func scheme(_ mode: Int) -> ColorScheme? { mode == 1 ? .light : mode == 2 ? .dark : nil }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Phone or tablet sizes: posters and spacing grow on an iPad.
struct Metrics {
    let wide: Bool
    var side: CGFloat { wide ? 28 : 16 }
    var poster: CGFloat { wide ? 150 : 112 }
    var ranked: CGFloat { wide ? 138 : 104 }
    var channel: CGFloat { wide ? 190 : 136 }
    var landscape: CGFloat { wide ? 300 : 220 }
    var gridMin: CGFloat { wide ? 140 : 100 }
}

private struct MetricsKey: EnvironmentKey { static let defaultValue = Metrics(wide: false) }

extension EnvironmentValues {
    var metrics: Metrics {
        get { self[MetricsKey.self] }
        set { self[MetricsKey.self] = newValue }
    }
}

/// The apps' ambient background: a soft glow of each section's colour at the top, fading into the
/// dark, and cross-fading as you move between sections (as on the TV and phone).
struct AmbientBackground: View {
    let page: Page
    @Environment(\.colorScheme) private var scheme

    static func base(_ p: Page) -> UInt32 {
        switch p {
        case .home: return 0x2A2F7A
        case .live: return 0x0F5C66
        case .movies: return 0x6A1F4A
        case .series: return 0x1F4E8C
        case .search: return 0x4A2A80
        case .downloads: return 0x1F5C7A
        }
    }

    /// Rich but calm (dark), or a pale wash (light): the same toning as the Android apps.
    static func tone(_ hex: UInt32, dark: Bool) -> UIColor {
        let c = Theme.ui(hex)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { h = 228 / 360; s = 0.30 }
        if dark {
            s = min(0.85, max(0.35, max(s * 1.25, 0.35)))
            return UIColor(hue: h, saturation: s, brightness: 0.46, alpha: 1)
        }
        s = min(0.32, max(0.10, s * 0.55))
        return UIColor(hue: h, saturation: s, brightness: 0.97, alpha: 1)
    }

    static func blend(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> Color {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(red: Double(r1 + (r2 - r1) * t), green: Double(g1 + (g2 - g1) * t), blue: Double(b1 + (b2 - b1) * t))
    }

    static func gradient(_ p: Page, dark: Bool) -> LinearGradient {
        let top = tone(base(p), dark: dark)
        let bg = dark ? Theme.ui(0x0A0B12) : Theme.ui(0xF2F2F7)
        return LinearGradient(colors: [blend(top, bg, 0), blend(top, bg, 0.45), blend(top, bg, 0.85), blend(top, bg, 1), blend(top, bg, 1)],
                              startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Theme.bg
            ForEach(Page.allCases) { p in
                AmbientBackground.gradient(p, dark: dark).opacity(p == page ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.7), value: page)
        .ignoresSafeArea()
    }
}

struct ProgressLine: View {
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Theme.accent).frame(width: g.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 3.5)
    }
}

/// Press feedback the instant a finger lands: the card gives a little, then springs back.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.1 : 0.22), value: configuration.isPressed)
    }
}

/// The page title at the top of a tab (with optional buttons on the right).
struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 30, weight: .bold)).lineLimit(1)
            Spacer()
            trailing()
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// A round icon button for headers (Cast, Settings, Guide…).
struct IconButton: View {
    let icon: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

/// The long-press menu for a film, series, episode or channel (as on the phone app).
struct ItemMenu: View {
    @EnvironmentObject var store: AppStore
    let item: Item

    var body: some View {
        if item.kind == .live {
            Button { store.play(item) } label: { Label("Watch", systemImage: "play.fill") }
        }
        if item.kind != .episode {
            Button { store.toggleFavourite(item) } label: {
                Label(store.isFavourite(item) ? "Remove from Favourites" : "Add to Favourites", systemImage: store.isFavourite(item) ? "heart.slash" : "heart")
            }
        }
        if item.kind == .movie || item.kind == .episode {
            Button { store.toggleQueue(item) } label: {
                Label(store.inQueue(item) ? "Remove from Queue" : "Add to Queue", systemImage: store.inQueue(item) ? "minus.circle" : "plus.circle")
            }
            Button { store.setWatched(item, !store.isWatched(item)) } label: {
                Label(store.isWatched(item) ? "Mark as Unwatched" : "Mark as Watched", systemImage: store.isWatched(item) ? "circle" : "checkmark.circle")
            }
        }
        if item.kind == .live && store.data.recentChannels.contains(where: { $0.id == item.id }) {
            Button(role: .destructive) { store.removeRecent(item) } label: { Label("Remove from Recent Channels", systemImage: "clock.badge.xmark") }
        }
    }
}

/// Movie / series / episode poster with the title underneath.
struct PosterCard: View {
    @EnvironmentObject var store: AppStore
    let item: Item
    var width: CGFloat? = 112
    var title: String? = nil
    var subtitle: String? = nil
    var progress: Double? = nil
    var showTitle = true
    let action: () -> Void
    var extraMenu: (() -> AnyView)? = nil

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .frame(width: width)
                    .background(Theme.card)
                    .overlay(
                        Text(item.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .padding(8)
                    )
                    .overlay(RemoteImage(url: item.posterURL, maxPixel: 360))
                    .overlay(alignment: .bottom) {
                        if let p = progress { ProgressLine(value: p).padding(7) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if store.isWatched(item) { WatchedBadge().padding(6) }
                        else if store.isFavourite(item) && item.kind != .episode {
                            Image(systemName: "heart.fill").font(.system(size: 12)).foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.6), radius: 2).padding(7)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if showTitle {
                    Text(title ?? item.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                        .frame(maxWidth: width ?? .infinity, alignment: .leading)
                    if let s = subtitle {
                        Text(s)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .frame(maxWidth: width ?? .infinity, alignment: .leading)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.primary)
        .contextMenu {
            ItemMenu(item: item)
            if let m = extraMenu { m() }
        }
    }
}

/// Continue Watching / Queue: a wide card with the episode's still (or the film's poster), Netflix-style.
struct LandscapeCard: View {
    @EnvironmentObject var store: AppStore
    let item: Item
    var width: CGFloat = 220
    var title: String
    var subtitle: String? = nil
    var progress: Double? = nil
    let action: () -> Void
    var extraMenu: (() -> AnyView)? = nil
    @State private var backdrop: URL?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    Theme.card
                    Text(initials(title)).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text3)
                    RemoteImage(url: item.posterURL, maxPixel: 300).blur(radius: 14).opacity(0.6)
                    RemoteImage(url: backdrop ?? (item.kind == .episode ? item.iconURL : nil), maxPixel: 600)
                }
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.55), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.2))
                        .padding(8)
                        .padding(.bottom, progress == nil ? 0 : 6)
                }
                .overlay(alignment: .bottom) {
                    if let p = progress { ProgressLine(value: p).padding(.horizontal, 8).padding(.bottom, 6) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
                if let s = subtitle {
                    Text(s).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1).frame(width: width, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.primary)
        .contextMenu {
            ItemMenu(item: item)
            if let m = extraMenu { m() }
        }
        .task(id: item.id) {
            // Films: TMDB's wide picture; episodes use their own still
            guard item.kind == .movie || (item.kind == .episode && item.icon == nil) else { return }
            let kind: Tmdb.Kind = item.kind == .movie ? .movie : .tv
            let name = item.kind == .episode ? (item.seriesName ?? item.name) : item.name
            guard let id = await Tmdb.findId(kind, name: name, known: item.tmdb) else { return }
            let a = await Tmdb.art(kind, id: id)
            if let b = a.backdrop { backdrop = b }
        }
    }
}

/// The muted preview's picture, faded in once it's actually playing.
struct PagePreviewLayer: View {
    @ObservedObject var preview: PlayerModel

    var body: some View {
        VideoSurface(video: preview.video)
            .opacity(preview.playing ? 1 : 0)
            .animation(.easeInOut(duration: 0.5), value: preview.playing)
            .allowsHitTesting(false)
    }
}

/// The ✓ in the corner of something you've watched.
struct WatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(Theme.onFocus)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Theme.focus.opacity(0.95)))
            .shadow(color: .black.opacity(0.5), radius: 3)
    }
}

/// A channel: its logo on a card, name underneath.
struct ChannelCard: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var epg: EpgStore
    let item: Item
    var width: CGFloat? = 136
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(width: width)
                    .background(Theme.card)
                    .overlay(
                        Text(initials(item.name))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.text3)
                    )
                    .overlay(RemoteImage(url: item.iconURL, maxPixel: 300, mode: .fit).padding(12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: width ?? .infinity, alignment: .leading)
                if let p = epg.now(item.streamId) {
                    Text(p.title)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                        .frame(maxWidth: width ?? .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.primary)
        .onAppear { epg.request(item) }
        .contextMenu { ItemMenu(item: item) }
    }
}

func initials(_ s: String) -> String {
    let words = s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    return String(words.prefix(2).compactMap { $0.first }).uppercased()
}

/// A titled horizontal row (Netflix-style shelf).
struct Shelf<Content: View>: View {
    @Environment(\.metrics) private var m
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: m.wide ? 21 : 18, weight: .bold)).lineLimit(1)
                if let s = subtitle { Text(s).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1) }
            }
            .padding(.horizontal, m.side)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: m.wide ? 14 : 8) { content() }
                    .padding(.horizontal, m.side)
                    .padding(.vertical, 6)
            }
        }
    }
}

/// Big rank number beside the poster, for the Top 10 rows.
struct RankedCard: View {
    @Environment(\.metrics) private var m
    let rank: Int
    let item: Item
    let action: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: -12) {
            OutlinedNumber(text: "\(rank)", size: m.wide ? 120 : 96)
                .frame(minWidth: m.wide ? 60 : 48)
                .offset(y: m.wide ? 18 : 14)
            PosterCard(item: item, width: m.ranked, showTitle: false, action: action)
        }
        .padding(.bottom, 6)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Theme.text3)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            if let m = message {
                Text(m).font(.subheadline).foregroundStyle(Theme.text2).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

struct LoadingView: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Give a category your own name (blank or "Original Name" puts the provider's back).
struct RenameSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let kind: Kind
    let category: Category
    @State private var name = ""

    var body: some View {
        let original = store.originalName(kind, category)
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .onSubmit(save)
                        .submitLabel(.done)
                } footer: {
                    Text("Original name: " + original)
                }
                Section {
                    Button("Use the Original Name") {
                        store.renameCategory(kind, category, to: "")
                        dismiss()
                    }
                }
            }
            .navigationTitle("Rename Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
        .presentationDetents([.medium])
        .onAppear { name = category.name }
    }

    private func save() {
        store.renameCategory(kind, category, to: name)
        dismiss()
    }
}

/// Netflix-style rank number: the background colour inside, a light edge around it.
struct OutlinedNumber: View {
    let text: String
    var size: CGFloat = 120

    var body: some View {
        let font = Font.system(size: size, weight: .black, design: .rounded)
        let edge = Theme.dyn(Theme.ui(0xEBEBF5, 0.8), Theme.ui(0x3C3C43, 0.7))
        ZStack {
            ForEach(0..<16, id: \.self) { i in
                let a = Double(i) / 16 * 2 * .pi
                Text(text).font(font).foregroundStyle(edge).offset(x: 2 * cos(a), y: 2 * sin(a))
            }
            Text(text).font(font).foregroundStyle(Theme.bg)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.5), radius: 6)
    }
}

/// A toast message at the bottom of the screen (Added to Favourites…).
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 24)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
