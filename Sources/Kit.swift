import SwiftUI
import UIKit

// The Android app's look for settings and pickers, so the iPhone app matches it instead of
// iOS's grouped lists: rounded card rows with the value on the right, small capital section
// headings, and pickers as a sheet with a grip, a bold title and roomy rows.

extension Theme {
    /// The sheet's own colour (Android Sheet: 0x1C1C22 dark, white light).
    static let sheet = dyn(ui(0x1C1C22), .white)
    /// A row that isn't tappable (SURFACE_LO).
    static let cardLo = dyn(.white.withAlphaComponent(0.07), .black.withAlphaComponent(0.04))
}

/// A page's glow in one colour, fading into the background (Settings uses slate, as on Android).
struct TintedBackground: View {
    var hex: UInt32 = 0x3A3F52
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let top = AmbientBackground.tone(hex, dark: dark)
        let bg = dark ? Theme.ui(0x0A0B12) : Theme.ui(0xF2F2F7)
        LinearGradient(colors: [AmbientBackground.blend(top, bg, 0), AmbientBackground.blend(top, bg, 0.45),
                                AmbientBackground.blend(top, bg, 0.85), AmbientBackground.blend(top, bg, 1)],
                       startPoint: .top, endPoint: .center)
            .background(Theme.bg)
            .ignoresSafeArea()
    }
}

/// Back arrow and a big title, like the top of Android's Settings.
struct PageTitleBar<Trailing: View>: View {
    let title: String
    let back: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 4) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            Text(title).font(.system(size: 26, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            trailing()
        }
        .foregroundStyle(.primary)
        .padding(.leading, 6)
        .padding(.trailing, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

extension PageTitleBar where Trailing == EmptyView {
    init(title: String, back: @escaping () -> Void) {
        self.init(title: title, back: back) { EmptyView() }
    }
}

/// "ACCOUNTS": the small grey capitals above a group of rows.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .padding(.top, 26)
            .padding(.bottom, 8)
    }
}

/// Small print under a group of rows.
struct SettingNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }
}

/// One settings row: a rounded card, the name on the left and its value on the right.
/// Tapping does the row's action (turn on / off, go to the next choice, open a page).
struct SettingRow<Value: View>: View {
    let label: String
    var detail: String? = nil
    var destructive = false
    var action: (() -> Void)?
    @ViewBuilder var value: () -> Value

    var body: some View {
        let content = HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(destructive ? Theme.pink : Color.primary)
                if let d = detail { Text(d).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1) }
            }
            Spacer(minLength: 0)
            value()
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 50)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())

        Group {
            if let a = action {
                Button(action: a) {
                    content.background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(RowPressStyle())
            } else {
                content.background(Theme.cardLo, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.bottom, 6)
    }
}

extension SettingRow where Value == Text {
    init(_ label: String, _ value: String = "", detail: String? = nil, destructive: Bool = false, action: (() -> Void)? = nil) {
        self.init(label: label, detail: detail, destructive: destructive, action: action) { Text(value) }
    }
}

/// On / Off, flipped by tapping the row (as on Android).
struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(label, isOn ? "On" : "Off") { isOn.toggle() }
    }
}

/// Tapping the row moves to the next choice (Size: Small → Medium → Large …).
struct CycleRow: View {
    let label: String
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        SettingRow(label, options.indices.contains(selection) ? options[selection] : "") {
            selection = options.isEmpty ? 0 : (selection + 1) % options.count
        }
    }
}

/// A gentle dim and shrink while a row is held down.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.08 : 0.2), value: configuration.isPressed)
    }
}

// MARK: sheets

/// A picker sheet like Android's: grip, bold title, optional subtitle, then the rows.
struct SheetPanel<Content: View>: View {
    let title: String?
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(Theme.text3).frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 10)
            if let t = title {
                Text(t).font(.system(size: 18, weight: .bold)).lineLimit(1)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, subtitle == nil ? 8 : 0)
            }
            if let s = subtitle {
                Text(s).font(.system(size: 13)).foregroundStyle(Theme.text2).lineLimit(3)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sheet.ignoresSafeArea())
        .modifier(SheetLook())
    }
}

/// Hides iOS's own grip and uses the sheet's colour behind it (iOS 16.4+ does the rounding to match).
private struct SheetLook: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(18)
                .presentationBackground(Theme.sheet)
        } else {
            content.presentationDragIndicator(.hidden)
        }
    }
}

/// One choice in a sheet: the chosen one is bold with a tick.
struct SheetRow<Trailing: View>: View {
    let label: String
    var detail: String? = nil
    var checked = false
    var destructive = false
    var icon: String? = nil
    var iconColor: Color = Theme.text2
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 12) {
                    if let i = icon {
                        Image(systemName: i).font(.system(size: 16)).foregroundStyle(iconColor).frame(width: 22)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(.system(size: 16, weight: checked ? .bold : .medium))
                            .foregroundStyle(destructive ? Theme.pink : Color.primary)
                            .lineLimit(1)
                        if let d = detail { Text(d).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1) }
                    }
                    Spacer(minLength: 8)
                    if checked { Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)) }
                }
                .padding(.leading, 20)
                .padding(.trailing, Trailing.self == EmptyView.self ? 20 : 4)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            trailing()
        }
        .padding(.trailing, Trailing.self == EmptyView.self ? 0 : 6)
    }
}

extension SheetRow where Trailing == EmptyView {
    init(_ label: String, detail: String? = nil, checked: Bool = false, destructive: Bool = false,
         icon: String? = nil, iconColor: Color = Theme.text2, action: @escaping () -> Void) {
        self.init(label: label, detail: detail, checked: checked, destructive: destructive,
                  icon: icon, iconColor: iconColor, action: action) { EmptyView() }
    }
}

/// The heart at the end of a sheet row (favourite categories).
struct SheetHeart: View {
    let on: Bool
    let toggle: () -> Void
    @State private var pop = false

    var body: some View {
        Button {
            toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.11)) { pop = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { withAnimation(.easeOut(duration: 0.14)) { pop = false } }
        } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .font(.system(size: 18))
                .foregroundStyle(on ? Theme.pink : Theme.text3)
                .scaleEffect(pop ? 1.25 : 1)
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The search box at the top of a long sheet (categories).
struct SheetSearchField: View {
    let hint: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(Theme.text2)
            TextField(hint, text: $text)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { AppStore.hideKeyboard() }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 42)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }
}

/// A small grey heading inside a sheet ("SUBTITLES", "SEASON 2").
struct SheetHeading: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

/// Grey text in a sheet when there's nothing to choose.
struct SheetEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Theme.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
    }
}
