import SwiftUI
import UIKit

/// The TV guide for Live TV: channels down the side, programmes across. Swipe sideways (or use the
/// arrows) to move through time; tap a channel to watch, a programme for details.
struct PhoneGuide: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var epg: EpgStore
    @Environment(\.metrics) private var m
    let channels: [Item]
    @State private var start = PhoneGuide.roundedNow()
    @State private var shown: GuidePick?

    private var span: TimeInterval { m.wide ? 3 * 3600 : 2 * 3600 }
    private var chanW: CGFloat { m.wide ? 170 : 92 }

    static func roundedNow() -> Date {
        let t = Date().timeIntervalSince1970
        return Date(timeIntervalSince1970: t - t.truncatingRemainder(dividingBy: 1800))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(Fmt.day.string(from: start)).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2)
                Spacer()
                Button { move(-3600) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 30) }
                    .disabled(start <= PhoneGuide.roundedNow())
                Button("Now") { withAnimation(Theme.ease) { start = PhoneGuide.roundedNow() } }
                    .font(.system(size: 13, weight: .semibold))
                Button { move(3600) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 30) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            GeometryReader { g in
                let w = max(120, g.size.width - chanW - 24)
                VStack(spacing: 0) {
                    timeHeader(w)
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(channels) { ch in
                                GuideRow(channel: ch, start: start, span: span, width: w, chanW: chanW,
                                         watch: { store.play(ch, list: channels) },
                                         pick: { p in shown = GuidePick(programme: p, channel: ch) })
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
                .padding(.horizontal, 10)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
                guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                move(v.translation.width < 0 ? 3600 : -3600)
            })
        }
        .sheet(item: $shown) { s in
            ProgrammeDetail(programme: s.programme, channel: s.channel) {
                shown = nil
                store.play(s.channel, list: channels)
            }
            .presentationDetents([.medium])
        }
    }

    private func move(_ d: TimeInterval) {
        let next = start.addingTimeInterval(d)
        guard next >= PhoneGuide.roundedNow() else { return }
        withAnimation(Theme.ease) { start = next }
    }

    private func timeHeader(_ w: CGFloat) -> some View {
        let slots = Int(span / 1800)
        return HStack(spacing: 0) {
            Color.clear.frame(width: chanW + 4, height: 22)
            ZStack(alignment: .topLeading) {
                ForEach(0..<slots, id: \.self) { i in
                    Text(Fmt.hm.string(from: start.addingTimeInterval(Double(i) * 1800)))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.text2)
                        .offset(x: CGFloat(i) * w / CGFloat(slots) + 4, y: 3)
                }
            }
            .frame(width: w, height: 22, alignment: .topLeading)
            .clipped()
        }
    }
}

struct GuidePick: Identifiable {
    let programme: Programme
    let channel: Item
    var id: String { channel.id + programme.id }
}

struct GuideRow: View {
    @EnvironmentObject var epg: EpgStore
    let channel: Item
    let start: Date
    let span: TimeInterval
    let width: CGFloat
    let chanW: CGFloat
    let watch: () -> Void
    let pick: (Programme) -> Void

    private let rowH: CGFloat = 56

    var body: some View {
        HStack(spacing: 4) {
            Button(action: watch) {
                VStack(spacing: 3) {
                    ZStack {
                        Text(initials(channel.name)).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text3)
                        RemoteImage(url: channel.iconURL, maxPixel: 160, mode: .fit)
                    }
                    .frame(width: 54, height: 28)
                    Text(channel.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                }
                .padding(.horizontal, 4)
                .frame(width: chanW, height: rowH)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(.primary)

            ZStack(alignment: .topLeading) {
                Color.clear
                if let progs = epg.get(channel.streamId) {
                    let visible = progs.filter { $0.stop > start && $0.start < start.addingTimeInterval(span) }
                    if visible.isEmpty {
                        Text("No guide information")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                            .padding(.leading, 10)
                            .frame(height: rowH)
                    }
                    ForEach(visible) { p in block(p) }
                } else {
                    Text("Loading…").font(.system(size: 12)).foregroundStyle(Theme.text3).padding(.leading, 10).frame(height: rowH)
                }
                let nx = x(Date())
                if nx >= 0 && nx <= width {
                    Rectangle().fill(Theme.accent).frame(width: 2, height: rowH).offset(x: nx)
                }
            }
            .frame(width: width, height: rowH, alignment: .topLeading)
            .clipped()
        }
        .onAppear { epg.request(channel) }
    }

    private func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(start) / span) * width }

    private func block(_ p: Programme) -> some View {
        let x1 = max(0, x(p.start)), x2 = min(width, x(p.stop))
        return Button { pick(p) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(p.timeRange).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.text2).lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(width: max(0, x2 - x1 - 3), height: rowH, alignment: .leading)
            .background(p.isNow ? Theme.cardHi : Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: x1)
    }
}

struct ProgrammeDetail: View {
    let programme: Programme
    let channel: Item
    let watch: () -> Void

    private var status: String {
        let now = Date()
        if programme.isNow { return "On now, \(Int(programme.stop.timeIntervalSince(now) / 60)) min left" }
        if programme.start > now {
            let m = Int((programme.start.timeIntervalSince(now) + 59) / 60)
            return m >= 60 ? "Starts in \(m / 60) hr \(m % 60) min" : "Starts in \(m) min"
        }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(programme.title).font(.system(size: 20, weight: .bold))
            Text(channel.name + "  ·  " + programme.timeRange + (status.isEmpty ? "" : "  ·  " + status))
                .font(.callout).foregroundStyle(.secondary)
            if !programme.desc.isEmpty {
                ScrollView { Text(programme.desc).frame(maxWidth: .infinity, alignment: .leading) }
            }
            Spacer(minLength: 0)
            Button(action: watch) {
                Label(programme.isNow ? "Watch Now" : "Watch \(channel.name)", systemImage: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(22)
    }
}
