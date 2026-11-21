import SwiftUI
import UIKit

/// New versions from the GitHub releases, like the TV, phone and Mac apps: on launch it asks GitHub
/// for the newest release and, if it's newer, offers it. An iPhone can't install an app by itself:
/// "Download" opens the release in Safari, and you sideload the new .ipa as before.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "YousufMiahh/YMPlayer-iOS"

    struct Release: Identifiable {
        let number: Int
        let name: String
        let notes: String
        let ipa: URL?
        let page: URL
        var id: Int { number }
    }

    /// A newer version to offer (shown as an alert by the root view).
    @Published var offer: Release?
    /// A one-off answer to "Check for Updates" (up to date / couldn't check).
    @Published var notice: String?

    private var busy = false

    static var installedNumber: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    /// - Parameter manual: from Settings: always check, and say so if there's nothing new.
    func check(manual: Bool) {
        guard !busy else { return }
        let d = UserDefaults.standard
        busy = true
        Task {
            defer { busy = false }
            guard let r = await latest() else {
                if manual { notice = "Couldn't check for updates. Check your internet connection and try again." }
                return
            }
            if r.number <= Updater.installedNumber {
                if manual { notice = "You're up to date: YM Player 1.0.\(Updater.installedNumber) is the newest version." }
                return
            }
            if !manual, d.integer(forKey: "updateLater") == r.number,
               Date().timeIntervalSince1970 - d.double(forKey: "updateLaterAt") < 24 * 3600 { return } // "Later" today
            offer = r
        }
    }

    func later(_ r: Release) {
        UserDefaults.standard.set(r.number, forKey: "updateLater")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "updateLaterAt")
        offer = nil
    }

    func download(_ r: Release) {
        offer = nil
        UIApplication.shared.open(r.ipa ?? r.page)
    }

    private func latest() async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("YMPlayer-Updater", forHTTPHeaderField: "User-Agent")
        guard let res = try? await URLSession.shared.data(for: req), (res.1 as? HTTPURLResponse)?.statusCode == 200,
              let o = (try? JSONSerialization.jsonObject(with: res.0)) as? [String: Any],
              let tag = o["tag_name"] as? String,
              let n = Int(tag.split(separator: ".").last ?? ""),
              let page = (o["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = o["assets"] as? [[String: Any]] ?? []
        let ipa = (assets.first(where: { ($0["name"] as? String)?.hasSuffix(".ipa") == true })?["browser_download_url"] as? String).flatMap(URL.init(string:))
        let notes = ((o["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "(?m)^- ", with: "•  ", options: .regularExpression)
        return Release(number: n, name: "YM Player " + tag.replacingOccurrences(of: "v", with: ""), notes: notes, ipa: ipa, page: page)
    }
}
