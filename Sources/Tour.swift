import SwiftUI
import UIKit

/// The quick tour: shown once after you first sign in, and again from Settings → Show Tutorial
/// (the iPhone and iPad version of the TV and phone apps' tips).
struct TourSheet: View {
    @EnvironmentObject var store: AppStore
    @State private var step = 0

    private struct Step {
        let icon: String
        let title: String
        let text: String
    }

    private let steps: [Step] = [
        Step(icon: "square.grid.2x2", title: "Getting around",
             text: "Home, Live TV, Movies, Series, Downloads and Search are along the bottom. Tap a tab again to jump back to the top. Settings is the gear at the top of Home."),
        Step(icon: "hand.tap", title: "Press and hold for more",
             text: "Press and hold a film, series, episode or channel to favourite it, add it to your Queue or mark it as watched. Press and hold a category to favourite, rename or hide it."),
        Step(icon: "play.rectangle", title: "Watching",
             text: "Videos turn sideways to fill the screen. Tap for controls, double-tap the left or right side to skip, swipe up or down on Live TV to change channel, and pinch to fill the screen."),
        Step(icon: "captions.bubble", title: "Picture and subtitles",
             text: "While watching, Settings at the bottom has audio, subtitles and the picture shape. Subtitle size and colour are in Settings → Subtitles."),
        Step(icon: "arrow.down.circle", title: "Downloads",
             text: "Download a film, an episode or a whole season from its page to watch without streaming. They're on the Downloads tab, and in the Files app."),
    ]

    var body: some View {
        let s = steps[step]
        VStack(spacing: 18) {
            Image(systemName: s.icon)
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(height: 56)
                .id(step)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            Text(s.title).font(.system(size: 24, weight: .bold))
            Text(s.text)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 420, minHeight: 110, alignment: .top)
            HStack(spacing: 7) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Capsule().fill(i == step ? Theme.accent : Theme.cardHi).frame(width: i == step ? 18 : 7, height: 7)
                }
            }
            HStack {
                Button("Skip") { store.finishTour() }
                Spacer()
                if step > 0 { Button("Back") { withAnimation(Theme.ease) { step -= 1 } } }
                Button(step == steps.count - 1 ? "Done" : "Next") {
                    if step == steps.count - 1 { store.finishTour() } else { withAnimation(Theme.ease) { step += 1 } }
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(30)
        .frame(maxWidth: 500)
        .animation(Theme.ease, value: step)
    }
}
