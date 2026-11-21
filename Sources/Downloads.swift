import SwiftUI
import UIKit

/// Films and episodes saved to the phone, one at a time, to YM Player's Downloads folder (also
/// in the Files app, under On My iPhone → YM Player).
/// Remembered per account; a downloaded item plays from the file.
@MainActor
final class Downloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum State: String, Codable { case waiting, running, done, failed }

    struct Entry: Codable, Identifiable, Hashable {
        var item: Item
        var state: State = .waiting
        var file: String?          // full path once finished
        var total: Int64 = 0
        var done: Int64 = 0
        var error: String?
        var added = Date()
        var id: String { item.id }
        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    }

    @Published private(set) var entries: [Entry] = []
    /// Bytes per second of the running download (smoothed).
    @Published private(set) var speed: Double = 0

    var apiProvider: () -> XtreamAPI? = { nil }
    private var account: UUID?
    private var task: URLSessionDownloadTask?
    private var runningId: String?
    private var runToken = ""            // tells this download's callbacks from a cancelled earlier one
    private var lastPublish = Date.distantPast
    private var lastBytes: Int64 = 0
    private var lastTick = Date()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60 * 60 * 12
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    // MARK: folder

    static let defaultFolder: URL = {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    var folder: URL { Downloader.defaultFolder }

    /// The app's folder moves when it's updated or reinstalled: saved paths are re-found inside today's Downloads folder.
    static func resolve(_ path: String?) -> String? {
        guard let p = path, !p.isEmpty else { return nil }
        if FileManager.default.fileExists(atPath: p) { return p }
        guard let r = p.range(of: "/Documents/Downloads/") else { return nil }
        let moved = defaultFolder.appendingPathComponent(String(p[r.upperBound...])).path
        return FileManager.default.fileExists(atPath: moved) ? moved : nil
    }

    // MARK: account

    func setAccount(_ id: UUID?) {
        if id == account && !entries.isEmpty { return }
        task?.cancel()
        task = nil
        runningId = nil
        account = id
        entries = []
        if let id = id, let d = try? Data(contentsOf: listURL(id)), let e = try? JSONDecoder().decode([Entry].self, from: d) {
            entries = e.map { var x = $0; if x.state == .running { x.state = .waiting; x.done = 0 }; x.file = Downloader.resolve(x.file) ?? x.file; return x }
            // Files you deleted in the Files app are gone from the list too
            entries.removeAll { $0.state == .done && Downloader.resolve($0.file) == nil }
        }
        pump()
    }

    /** A removed account: its download list goes (the files stay in the folder). */
    func forget(_ id: UUID) { try? FileManager.default.removeItem(at: listURL(id)) }

    private func listURL(_ id: UUID) -> URL { Storage.support.appendingPathComponent("downloads-\(id.uuidString).json") }

    private func save() {
        guard let id = account, let d = try? JSONEncoder().encode(entries) else { return }
        try? d.write(to: listURL(id), options: .atomic)
    }

    // MARK: queries

    func entry(_ it: Item) -> Entry? { entries.first { $0.id == it.id } }

    func localURL(for it: Item) -> URL? {
        guard let e = entry(it), e.state == .done, let f = Downloader.resolve(e.file) else { return nil }
        return URL(fileURLWithPath: f)
    }

    var running: Entry? { entries.first { $0.state == .running } }

    /// Rough time left for these items: what's left of the running one, plus the waiting ones at its size.
    func timeLeft(_ items: [Item]) -> Double? {
        guard speed > 1000 else { return nil }
        let ids = Set(items.map(\.id))
        let mine = entries.filter { ids.contains($0.id) }
        var bytes: Int64 = 0
        let typical = running?.total ?? mine.first(where: { $0.total > 0 })?.total ?? 0
        guard typical > 0 else { return nil }
        for e in mine {
            switch e.state {
            case .running: bytes += max(0, e.total - e.done)
            case .waiting: bytes += typical
            default: break
            }
        }
        return bytes > 0 ? Double(bytes) / speed : nil
    }

    static func timeText(_ s: Double) -> String {
        let m = Int((s / 60).rounded(.up))
        if m < 1 { return "less than a minute left" }
        if m < 60 { return "about \(m) min left" }
        let h = m / 60, r = m % 60
        return r == 0 ? "about \(h) hr left" : "about \(h) hr \(r) min left"
    }

    // MARK: actions

    func add(_ items: [Item]) {
        var n = 0
        for it in items where it.kind == .movie || it.kind == .episode {
            if let i = entries.firstIndex(where: { $0.id == it.id }) {
                if entries[i].state == .failed { entries[i].state = .waiting; entries[i].error = nil; n += 1 }
                continue
            }
            entries.append(Entry(item: it))
            n += 1
        }
        save()
        pump()
    }

    func cancel(_ e: Entry) {
        if runningId == e.id {
            task?.cancel()
            task = nil
            runningId = nil
        }
        entries.removeAll { $0.id == e.id }
        save()
        pump()
    }

    func cancelAll(_ items: [Item]) {
        let ids = Set(items.map(\.id))
        for e in entries where ids.contains(e.id) && (e.state == .waiting || e.state == .running) { cancel(e) }
    }

    func delete(_ e: Entry) {
        if let f = Downloader.resolve(e.file) { try? FileManager.default.removeItem(atPath: f) }
        cancel(e)
    }

    func retry(_ e: Entry) { add([e.item]) }

    /// Starts the next waiting download when nothing is running.
    func pump() {
        guard runningId == nil, let api = apiProvider(),
              let i = entries.firstIndex(where: { $0.state == .waiting }) else { return }
        let it = entries[i].item
        guard let url = api.playURL(it, liveFormat: "ts") else {
            entries[i].state = .failed
            entries[i].error = "No link for this"
            save()
            pump()
            return
        }
        entries[i].state = .running
        entries[i].done = 0
        runningId = it.id
        lastBytes = 0
        lastTick = Date()
        speed = 0
        var r = URLRequest(url: url)
        r.setValue("VLC/3.0.20 LibVLC/3.0.20", forHTTPHeaderField: "User-Agent")
        beginBackground()
        let t = session.downloadTask(with: r)
        runToken = UUID().uuidString
        t.taskDescription = runToken + "|" + it.id
        task = t
        t.resume()
        save()
    }

    private func destination(_ it: Item, ext: String) -> URL {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        func safe(_ s: String) -> String { s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
        var dir = folder
        var name: String
        if it.kind == .episode {
            let series = safe(it.seriesName ?? "Series")
            dir = dir.appendingPathComponent(series, isDirectory: true)
            name = series
            if let s = it.season, let e = it.episode { name += String(format: " - S%02dE%02d", s, e) }
            if it.name != it.seriesName && !it.name.isEmpty { name += " - " + safe(it.name) }
        } else {
            name = safe(it.name)
        }
        if name.isEmpty { name = it.streamId }
        while name.utf8.count > 200 { name.removeLast() } // file names are limited to 255 bytes, not characters
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var u = dir.appendingPathComponent(name + "." + ext)
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent(name + " (\(n))." + ext)
            n += 1
        }
        return u
    }

    // MARK: keep going for a while when you leave the app

    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private func beginBackground() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "downloads") { [weak self] in
            Task { @MainActor in self?.endBackground() }
        }
    }

    private func endBackground() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: URLSession (called off the main thread)

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskDescription
        Task { @MainActor in self.progress(id, totalBytesWritten, totalBytesExpectedToWrite) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is deleted when this returns, so move it somewhere safe first
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("ymdl-" + UUID().uuidString)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let ok = status < 400 && (try? FileManager.default.moveItem(at: location, to: staged)) != nil
        let id = downloadTask.taskDescription
        Task { @MainActor in self.finished(id, ok ? staged : nil, status) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        let id = task.taskDescription
        let cancelled = (error as? URLError)?.code == .cancelled
        Task { @MainActor in self.failed(id, cancelled ? nil : error.localizedDescription) }
    }

    /// "token|itemId" → the item id, if it's the download running now (not a cancelled one).
    private func current(_ desc: String?) -> String? {
        guard let d = desc, let bar = d.firstIndex(of: "|"), String(d[..<bar]) == runToken else { return nil }
        let id = String(d[d.index(after: bar)...])
        return id == runningId ? id : nil
    }

    private func progress(_ desc: String?, _ done: Int64, _ total: Int64) {
        guard let id = current(desc), let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        // At most a few updates a second: every redraw costs, and chunks arrive hundreds of times a second
        if now.timeIntervalSince(lastPublish) < 0.5 && (total <= 0 || done < total) { return }
        lastPublish = now
        entries[i].done = done
        if total > 0 { entries[i].total = total }
        let dt = now.timeIntervalSince(lastTick)
        if dt >= 1 {
            let s = Double(done - lastBytes) / dt
            speed = speed == 0 ? s : speed * 0.7 + s * 0.3
            lastBytes = done
            lastTick = now
        }
    }

    private func finished(_ desc: String?, _ staged: URL?, _ status: Int) {
        guard let id = current(desc), entries.contains(where: { $0.id == id }) else {
            if let s = staged { try? FileManager.default.removeItem(at: s) }
            return
        }
        guard let s = staged, let it = entries.first(where: { $0.id == id })?.item else {
            if let i = entries.firstIndex(where: { $0.id == id }) {
                entries[i].state = .failed
                entries[i].error = status >= 400 ? "The server refused (\(status))" : "Download failed"
            }
            done(id)
            return
        }
        let dest = destination(it, ext: it.ext ?? "mp4")
        // Off the main thread: to another drive a "move" is a copy of several GB
        Task.detached(priority: .utility) {
            var ok = true
            do { try FileManager.default.moveItem(at: s, to: dest) } catch {
                ok = false
                try? FileManager.default.removeItem(at: s)
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value
            await MainActor.run {
                if let i = self.entries.firstIndex(where: { $0.id == id }) {
                    if ok {
                        self.entries[i].state = .done
                        self.entries[i].file = dest.path
                        if let size = size { self.entries[i].total = size; self.entries[i].done = size }
                    } else {
                        self.entries[i].state = .failed
                        self.entries[i].error = "Couldn't save it (is the phone full?)"
                    }
                }
                self.done(id)
            }
        }
    }

    /// The running download is over (one way or another): on to the next.
    private func done(_ id: String) {
        if runningId == id { runningId = nil; task = nil }
        if !entries.contains(where: { $0.state == .waiting }) { endBackground() }
        speed = 0
        save()
        pump()
    }

    private func failed(_ desc: String?, _ message: String?) {
        guard let id = current(desc) else { return } // a cancelled download: already dealt with
        if let i = entries.firstIndex(where: { $0.id == id }), let m = message {
            entries[i].state = .failed
            entries[i].error = m
        }
        done(id)
    }
}

/// The Downloads tab.
struct DownloadsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var dl: Downloader

    var body: some View {
        let list = dl.entries.sorted { order($0) < order($1) }
        VStack(spacing: 0) {
            PageHeader(title: "Downloads")
            if list.isEmpty {
                EmptyState(icon: "arrow.down.circle", title: "No downloads",
                           message: "Download a film, an episode or a whole season from its page to watch it without streaming. They're also in the Files app, under On My iPhone → YM Player.")
            } else {
                List {
                    ForEach(list) { e in
                        DownloadRow(dl: dl, entry: e)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    if e.state == .done { dl.delete(e) } else { dl.cancel(e) }
                                } label: { Label(e.state == .done ? "Delete" : "Cancel", systemImage: e.state == .done ? "trash" : "xmark") }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func order(_ e: Downloader.Entry) -> Int {
        switch e.state {
        case .running: return 0
        case .waiting: return 1
        case .failed: return 2
        case .done: return 3
        }
    }
}

private struct DownloadRow: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var dl: Downloader
    let entry: Downloader.Entry

    private var title: String {
        let it = entry.item
        return it.kind == .episode ? (it.seriesName ?? it.name) : it.name
    }

    private var sub: String? {
        let it = entry.item
        guard it.kind == .episode else { return nil }
        return [it.episodeLabel, it.name == it.seriesName ? nil : it.name].compactMap { $0 }.joined(separator: "  ·  ")
    }

    private var status: String {
        switch entry.state {
        case .waiting: return "Waiting"
        case .running:
            var s = bytes(entry.done) + (entry.total > 0 ? " of " + bytes(entry.total) : "")
            if entry.total > 0, dl.speed > 1000 { s += "  ·  " + Downloader.timeText(Double(entry.total - entry.done) / dl.speed) }
            return s
        case .failed: return entry.error ?? "Failed"
        case .done: return "Downloaded" + (entry.total > 0 ? "  ·  " + bytes(entry.total) : "")
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Theme.card
                RemoteImage(url: entry.item.posterURL, maxPixel: 200)
            }
            .frame(width: 50, height: 75)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if let s = sub, !s.isEmpty { Text(s).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                if entry.state == .running { ProgressLine(value: entry.fraction).padding(.vertical, 2) }
                Text(status).font(.system(size: 12)).foregroundStyle(entry.state == .failed ? Theme.pink : Color.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            switch entry.state {
            case .done:
                Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundStyle(Theme.accent)
            case .failed:
                Button("Retry") { dl.retry(entry) }.buttonStyle(.bordered)
            default:
                Button { dl.cancel(entry) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if entry.state == .done { store.play(entry.item) } }
        .contextMenu {
            if entry.state == .done {
                Button { store.play(entry.item) } label: { Label("Play", systemImage: "play.fill") }
                Button(role: .destructive) { dl.delete(entry) } label: { Label("Delete Download", systemImage: "trash") }
            } else {
                Button(role: .destructive) { dl.cancel(entry) } label: { Label("Cancel Download", systemImage: "xmark") }
            }
        }
    }

    private func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}

/// "Download" button for a film or episode, showing its progress.
struct DownloadButton: View {
    @ObservedObject var dl: Downloader
    let item: Item

    var body: some View {
        let e = dl.entry(item)
        Button {
            if let e = e {
                if e.state == .failed { dl.retry(e) } else if e.state != .done { dl.cancel(e) }
            } else { dl.add([item]) }
        } label: {
            switch e?.state {
            case .some(.done): Label("Downloaded", systemImage: "checkmark.circle.fill")
            case .some(.running): Label(runningText(e), systemImage: "stop.circle")
            case .some(.waiting): Label("Waiting", systemImage: "clock")
            case .some(.failed): Label("Retry", systemImage: "exclamationmark.arrow.circlepath")
            case .none: Label("Download", systemImage: "arrow.down.circle")
            }
        }
        .disabled(e?.state == .done)
    }

    private func runningText(_ e: Downloader.Entry?) -> String {
        guard let e = e else { return "Downloading" }
        return "\(Int(e.fraction * 100))%"
    }
}
