import Foundation
import Network
import Libavformat
import Libavcodec
import Libavutil
import Libswresample

/// AirPlay for files an Apple TV can't open itself (MKV, AVI…).
///
/// The Apple TV only plays MP4 / MOV / HLS. For anything else the phone reads the file from the provider and
/// repackages it, without re-encoding the picture, into HLS (fragmented MP4 segments) in a temporary folder.
/// A small web server on the phone hands those segments to the Apple TV over Wi-Fi.
///
/// - Video: H.264 and HEVC are copied as they are (every Apple TV plays them).
/// - Sound: AAC, AC-3 and E-AC-3 are copied; anything else (DTS, TrueHD, FLAC, Opus, MP3…) becomes AAC.
/// - It starts from where you are, stays a couple of minutes ahead of the TV, and starts again from the new
///   place when you skip outside what's been made.
final class AirPlayRemux: @unchecked Sendable {
    /// Called on the main thread with the address the TV should play, once the first segments are ready,
    /// and where in the film that starts (the keyframe at or just before where you were).
    var onReady: (@MainActor (URL, Double) -> Void)?
    /// Called on the main thread when it can't carry on, with a message for the user.
    var onFailure: (@MainActor (String) -> Void)?

    let source: URL
    let startTime: Double
    private let userAgent: String
    private let dir: URL
    private let token = UUID().uuidString.lowercased()
    private let server: LocalFileServer
    private let flag = CancelFlag()
    private var httpSource: HTTPSource?
    private let lock = NSLock()
    private var _playhead: Double = 0
    private var _produced: Double = 0

    /// How far into this session the TV has got (seconds from `start`). Keeps the remux from racing ahead.
    var playhead: Double {
        get { lock.lock(); defer { lock.unlock() }; return _playhead }
        set { lock.lock(); _playhead = newValue; lock.unlock() }
    }

    /// How much has been made so far (seconds from `start`).
    var produced: Double {
        lock.lock(); defer { lock.unlock() }
        return _produced
    }

    private func setProduced(_ s: Double) { lock.lock(); _produced = max(_produced, s); lock.unlock() }

    /// Stay this far ahead of the TV at most.
    private let ahead: Double = 150

    init(source: URL, start: Double, userAgent: String) {
        self.source = source
        self.startTime = max(0, start)
        self.userAgent = userAgent
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("airplay-" + UUID().uuidString, isDirectory: true)
        server = LocalFileServer(root: dir, token: token)
    }

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let ip = LocalFileServer.wifiAddress() else {
            fail("Connect your iPhone to the same Wi-Fi as the TV to AirPlay this video.")
            return
        }
        server.start { [weak self] port in
            guard let self = self else { return }
            guard let port = port else {
                self.fail("Couldn't start sending this video to the TV. Try again, or use Screen Mirroring.")
                return
            }
            let url = URL(string: "http://\(ip):\(port)/\(self.token)/index.m3u8")!
            let t = Thread { [self] in self.run(playURL: url) }
            t.name = "YM Player AirPlay remux"
            t.qualityOfService = .userInitiated
            t.start()
        }
    }

    /// Stop making segments, stop serving them and delete them.
    func stop() {
        flag.cancelled = true
        lock.lock(); let src = httpSource; lock.unlock()
        src?.cancel()
        server.stop()
        let d = dir
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            try? FileManager.default.removeItem(at: d)
        }
    }

    private func fail(_ message: String) {
        guard !flag.cancelled else { return }
        let cb = onFailure
        Task { @MainActor in cb?(message) }
    }

    private var startedAt: Double = 0

    private func ready(_ url: URL) {
        guard !flag.cancelled else { return }
        let cb = onReady, at = startedAt
        Task { @MainActor in cb?(url, at) }
    }

    // MARK: the remux

    private static let EOF: Int32 = -541_478_725 // AVERROR_EOF
    private static let noPTS = Int64.min         // AV_NOPTS_VALUE
    private static let microseconds = AVRational(num: 1, den: 1_000_000)

    private static func describe(_ err: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        av_strerror(err, &buf, buf.count)
        return String(cString: buf)
    }

    /// FFmpeg's own short name for a format ("h264", "hevc", "aac"…). Compared by name, not by number:
    /// the numbers in the bundled headers don't always match the library's.
    static func codecName(_ id: AVCodecID) -> String {
        String(cString: avcodec_get_name(id))
    }

    private func run(playURL: URL) {
        // The file comes through iOS's networking (as everywhere else in the app), not FFmpeg's
        let src = HTTPSource(url: source, userAgent: userAgent)
        lock.lock(); httpSource = src; lock.unlock()
        defer { src.cancel() }
        if flag.cancelled { return }
        if let e = src.open() {
            fail("Couldn't get this video from your provider for AirPlay (\(e)).")
            return
        }
        let ioSize: Int32 = 256 << 10
        guard let ioBuf = av_malloc(Int(ioSize)) else { fail("Out of memory"); return }
        let opaque = Unmanaged.passUnretained(src).toOpaque()
        var pb: UnsafeMutablePointer<AVIOContext>? = avio_alloc_context(
            ioBuf.assumingMemoryBound(to: UInt8.self), ioSize, 0, opaque,
            { op, buf, n in
                guard let op = op, let buf = buf else { return -5 }
                return Unmanaged<HTTPSource>.fromOpaque(op).takeUnretainedValue().read(buf, n)
            },
            nil,
            { op, offset, whence in
                guard let op = op else { return -1 }
                return Unmanaged<HTTPSource>.fromOpaque(op).takeUnretainedValue().seek(offset, whence)
            })
        guard let io = pb else { av_free(ioBuf); fail("Out of memory"); return }
        defer {
            av_freep(&pb!.pointee.buffer) // FFmpeg may have swapped the buffer; free whatever it holds now
            avio_context_free(&pb)
        }
        if !src.rangesWork { io.pointee.seekable = 0 } // can only read straight through

        var ic: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard ic != nil else { fail("Out of memory"); return }
        ic!.pointee.pb = io
        ic!.pointee.flags |= 0x0080 // AVFMT_FLAG_CUSTOM_IO
        ic!.pointee.interrupt_callback = AVIOInterruptCB(callback: { opaque in
            guard let opaque = opaque else { return 0 }
            return Unmanaged<CancelFlag>.fromOpaque(opaque).takeUnretainedValue().cancelled ? 1 : 0
        }, opaque: Unmanaged.passUnretained(flag).toOpaque())

        // The name is only a hint for working out the format (".mkv" and so on)
        var err = avformat_open_input(&ic, source.lastPathComponent, nil, nil)
        guard err >= 0, let input = ic else {
            fail("Couldn't read this video for AirPlay (\(Self.describe(err))).")
            return
        }
        defer { var c: UnsafeMutablePointer<AVFormatContext>? = input; avformat_close_input(&c) }

        err = avformat_find_stream_info(input, nil)
        guard err >= 0, !flag.cancelled else {
            fail("Couldn't read this video for AirPlay (\(Self.describe(err))).")
            return
        }

        // The picture and the main soundtrack
        let vIndex = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard vIndex >= 0 else { fail("This video has no picture to send to the TV."); return }
        let aIndex = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, vIndex, nil, 0)
        let vIn = input.pointee.streams[Int(vIndex)]!
        let vName = Self.codecName(vIn.pointee.codecpar.pointee.codec_id)
        let isHEVC = vName == "hevc"
        guard vName == "h264" || isHEVC else {
            fail("The Apple TV can't play this video's picture format (\(vName.uppercased())). Use Screen Mirroring for this one.")
            return
        }
        for i in 0..<Int(input.pointee.nb_streams) where i != Int(vIndex) && i != Int(aIndex) {
            input.pointee.streams[i]!.pointee.discard = AVDISCARD_ALL
        }

        // Start from where you were on the phone
        let startUs = Int64(startTime * 1_000_000)
        var notBeforeUs = Int64.min // reading straight through: skip to where you were
        if startTime > 1 {
            if !src.rangesWork || avformat_seek_file(input, -1, Int64.min, startUs, startUs, 0) < 0 {
                notBeforeUs = startUs - 2_000_000
            }
        }

        // The output: HLS with fragmented-MP4 segments
        let playlist = dir.appendingPathComponent("index.m3u8").path
        var ocOpt: UnsafeMutablePointer<AVFormatContext>?
        err = avformat_alloc_output_context2(&ocOpt, nil, "hls", playlist)
        guard err >= 0, let oc = ocOpt else { fail("Couldn't prepare the video for AirPlay."); return }
        defer { avformat_free_context(oc) }
        oc.pointee.avoid_negative_ts = 2 // AVFMT_AVOID_NEG_TS_MAKE_ZERO

        guard let vOut = avformat_new_stream(oc, nil) else { fail("Out of memory"); return }
        avcodec_parameters_copy(vOut.pointee.codecpar, vIn.pointee.codecpar)
        // Apple wants HEVC tagged "hvc1"; everything else gets the format's default tag
        vOut.pointee.codecpar.pointee.codec_tag = isHEVC ? Self.tag("hvc1") : 0
        vOut.pointee.time_base = vIn.pointee.time_base

        // The sound: copied when the Apple TV can play it, otherwise turned into AAC
        var audio: AudioTranscoder?
        var aOut: UnsafeMutablePointer<AVStream>?
        var aIn: UnsafeMutablePointer<AVStream>?
        if aIndex >= 0 {
            let s = input.pointee.streams[Int(aIndex)]!
            aIn = s
            let copy = ["aac", "ac3", "eac3"].contains(Self.codecName(s.pointee.codecpar.pointee.codec_id))
            let transcoder = copy ? nil : AudioTranscoder(input: s)
            if copy || transcoder != nil, let o = avformat_new_stream(oc, nil) {
                if let t = transcoder {
                    guard t.attach(o) else { fail("Couldn't prepare this video's sound for AirPlay."); return }
                    audio = t
                } else {
                    avcodec_parameters_copy(o.pointee.codecpar, s.pointee.codecpar)
                    o.pointee.codecpar.pointee.codec_tag = 0
                    o.pointee.time_base = s.pointee.time_base
                }
                aOut = o
            } else {
                aIn = nil // a soundtrack that can't be converted: send the picture alone rather than nothing
            }
        }

        var hls: OpaquePointer?
        av_dict_set(&hls, "hls_time", "4", 0)
        av_dict_set(&hls, "hls_list_size", "0", 0)
        av_dict_set(&hls, "hls_playlist_type", "event", 0)
        av_dict_set(&hls, "hls_segment_type", "fmp4", 0)
        av_dict_set(&hls, "hls_fmp4_init_filename", "init.mp4", 0)
        av_dict_set(&hls, "hls_segment_filename", dir.appendingPathComponent("seg%05d.m4s").path, 0)
        av_dict_set(&hls, "hls_flags", "independent_segments+temp_file", 0)
        err = avformat_write_header(oc, &hls)
        av_dict_free(&hls)
        guard err >= 0 else {
            fail("Couldn't prepare the video for AirPlay (\(Self.describe(err))).")
            return
        }

        var pktOpt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&pktOpt) }
        guard let pkt = pktOpt else { fail("Out of memory"); return }

        let vOutIndex = vOut.pointee.index
        let aOutIndex = aOut?.pointee.index ?? -1
        var baseUs: Int64? = nil          // the first keyframe's time: the start of what the TV plays
        var lastDts = [Int32: Int64]()    // per output stream, to keep timestamps rising
        var announced = false
        var checkAt: Double = 0
        var failure: String?

        readLoop: while !flag.cancelled {
            // Don't race ahead of the TV: a film can be many gigabytes
            while !flag.cancelled && produced > playhead + ahead {
                Thread.sleep(forTimeInterval: 0.5)
            }
            if flag.cancelled { break }

            err = av_read_frame(input, pkt)
            if err == Self.EOF { break }
            if err < 0 {
                if !flag.cancelled { failure = "The video stopped coming from your provider (\(Self.describe(err)))." }
                break
            }
            defer { av_packet_unref(pkt) }
            let si = pkt.pointee.stream_index
            let inStream: UnsafeMutablePointer<AVStream>
            if si == vIndex { inStream = vIn }
            else if si == aIndex, let a = aIn { inStream = a }
            else { continue }
            let tb = inStream.pointee.time_base

            if pkt.pointee.pts == Self.noPTS { pkt.pointee.pts = pkt.pointee.dts }
            if pkt.pointee.dts == Self.noPTS { pkt.pointee.dts = pkt.pointee.pts }
            guard pkt.pointee.pts != Self.noPTS else { continue }

            // Begin on a keyframe; sound from before it is dropped
            if baseUs == nil {
                guard si == vIndex, pkt.pointee.flags & AV_PKT_FLAG_KEY != 0 else { continue }
                let us = av_rescale_q(pkt.pointee.pts, tb, Self.microseconds)
                guard us >= notBeforeUs else { continue }
                baseUs = us
                let fileStart = input.pointee.start_time != Self.noPTS ? input.pointee.start_time : 0
                startedAt = max(0, Double(us - fileStart) / 1_000_000)
            }
            let base = av_rescale_q(baseUs!, Self.microseconds, tb)

            if si == aIndex, let t = audio {
                // Sound that needs converting: decode → AAC → write
                if let e = t.feed(pkt, baseUs: baseUs!, write: { av_interleaved_write_frame(oc, $0) }), e < 0 {
                    failure = "Couldn't convert this video's sound for AirPlay (\(Self.describe(e)))."
                    break readLoop
                }
                continue
            }

            pkt.pointee.pts -= base
            pkt.pointee.dts -= base
            if si == aIndex && pkt.pointee.pts < 0 { continue } // sound from before the first picture
            let outIndex = si == vIndex ? vOutIndex : aOutIndex
            if let last = lastDts[outIndex], pkt.pointee.dts <= last {
                pkt.pointee.dts = last + 1
                if pkt.pointee.pts < pkt.pointee.dts { pkt.pointee.pts = pkt.pointee.dts }
            }
            lastDts[outIndex] = pkt.pointee.dts
            if si == vIndex {
                setProduced(Double(av_rescale_q(pkt.pointee.dts, tb, Self.microseconds)) / 1_000_000)
            }
            let outStream = si == vIndex ? vOut : aOut!
            av_packet_rescale_ts(pkt, tb, outStream.pointee.time_base)
            pkt.pointee.stream_index = outIndex
            pkt.pointee.pos = -1
            err = av_interleaved_write_frame(oc, pkt)
            if err < 0 {
                failure = "Couldn't send this video to the TV (\(Self.describe(err)))."
                break
            }

            // Tell the TV to start once a couple of segments are ready
            if !announced, produced >= checkAt {
                checkAt = produced + 1
                if segmentsReady(2) {
                    announced = true
                    ready(playURL)
                }
            }
        }

        if !flag.cancelled {
            if let t = audio { _ = t.flush(write: { av_interleaved_write_frame(oc, $0) }) }
            av_write_trailer(oc) // marks the playlist as complete
            if !announced, failure == nil {
                if segmentsReady(1) { ready(playURL) } else { failure = "This video ended before it could be sent to the TV." }
            }
        }
        if let f = failure { fail(f) }
    }

    /// The playlist lists at least `n` finished segments.
    private func segmentsReady(_ n: Int) -> Bool {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("index.m3u8"), encoding: .utf8) else { return false }
        return text.components(separatedBy: "#EXTINF").count - 1 >= n
    }

    private static func tag(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
}

/// Read from FFmpeg's interrupt callback to stop network reads straight away.
final class CancelFlag: @unchecked Sendable {
    var cancelled = false
}

// MARK: - sound conversion

/// Decodes a soundtrack the Apple TV can't play (DTS, TrueHD, FLAC…) and encodes it as AAC.
final class AudioTranscoder {
    private let input: UnsafeMutablePointer<AVStream>
    private var output: UnsafeMutablePointer<AVStream>?
    private var dec: UnsafeMutablePointer<AVCodecContext>?
    private var enc: UnsafeMutablePointer<AVCodecContext>?
    private var swr: OpaquePointer?
    private var fifo: OpaquePointer?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var outPkt: UnsafeMutablePointer<AVPacket>?
    private var nextPts: Int64 = -1 // in samples, from the start of what the TV plays
    private var rate: Int32 = 48000

    init?(input: UnsafeMutablePointer<AVStream>) {
        self.input = input
        guard let par = input.pointee.codecpar,
              let d = avcodec_find_decoder(par.pointee.codec_id),
              let e = avcodec_find_encoder_by_name("aac") else { return nil }
        dec = avcodec_alloc_context3(d)
        enc = avcodec_alloc_context3(e)
        guard let dc = dec, let ec = enc else { return nil }
        guard avcodec_parameters_to_context(dc, par) >= 0 else { return nil }
        dc.pointee.pkt_timebase = input.pointee.time_base
        guard avcodec_open2(dc, d, nil) >= 0 else { return nil }

        // AAC: stereo, or 5.1 for surround soundtracks
        let channels: Int32 = dc.pointee.ch_layout.nb_channels >= 6 ? 6 : 2
        let inRate = dc.pointee.sample_rate > 0 ? dc.pointee.sample_rate : 48000
        rate = inRate > 48000 ? 48000 : inRate
        av_channel_layout_default(&ec.pointee.ch_layout, channels)
        ec.pointee.sample_rate = rate
        ec.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        ec.pointee.bit_rate = channels == 6 ? 384_000 : 192_000
        ec.pointee.time_base = AVRational(num: 1, den: rate)
        ec.pointee.flags |= 1 << 22 // AV_CODEC_FLAG_GLOBAL_HEADER: fragmented MP4 needs it
        guard avcodec_open2(ec, e, nil) >= 0 else { return nil }
        fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, channels, 4096)
        frame = av_frame_alloc()
        outPkt = av_packet_alloc()
        guard fifo != nil, frame != nil, outPkt != nil else { return nil }
    }

    /// Describe the AAC soundtrack on the output stream.
    func attach(_ o: UnsafeMutablePointer<AVStream>) -> Bool {
        guard let ec = enc, avcodec_parameters_from_context(o.pointee.codecpar, ec) >= 0 else { return false }
        o.pointee.time_base = ec.pointee.time_base
        output = o
        return true
    }

    deinit {
        avcodec_free_context(&dec)
        avcodec_free_context(&enc)
        swr_free(&swr)
        if let f = fifo { av_audio_fifo_free(f) }
        av_frame_free(&frame)
        av_packet_free(&outPkt)
    }

    /// Decode a packet and write any AAC packets that come out. Returns an error code, or nil.
    func feed(_ pkt: UnsafeMutablePointer<AVPacket>, baseUs: Int64, write: (UnsafeMutablePointer<AVPacket>) -> Int32) -> Int32? {
        guard let dec = dec, let frame = frame else { return nil }
        var r = avcodec_send_packet(dec, pkt)
        if r < 0 && r != -EAGAIN { return nil } // a damaged packet: skip it
        while true {
            r = avcodec_receive_frame(dec, frame)
            if r == -EAGAIN || r < 0 { break }
            defer { av_frame_unref(frame) }
            if nextPts < 0 {
                // Line the sound up with the picture: start at the first frame from the keyframe on
                let ts = frame.pointee.best_effort_timestamp != Int64.min ? frame.pointee.best_effort_timestamp : frame.pointee.pts
                if ts != Int64.min {
                    let us = av_rescale_q(ts, input.pointee.time_base, AVRational(num: 1, den: 1_000_000))
                    if us < baseUs { continue }
                    nextPts = av_rescale_q(us - baseUs, AVRational(num: 1, den: 1_000_000), AVRational(num: 1, den: rate))
                } else {
                    nextPts = 0
                }
            }
            if let e = convert(frame), e < 0 { return e }
            if let e = drain(final: false, write: write), e < 0 { return e }
        }
        return nil
    }

    /// The end of the video: send what's left.
    func flush(write: (UnsafeMutablePointer<AVPacket>) -> Int32) -> Int32? {
        guard let enc = enc, nextPts >= 0 else { return nil }
        _ = drain(final: true, write: write)
        avcodec_send_frame(enc, nil)
        return receive(write: write)
    }

    /// Set the converter up for frames like this one (the decoder's own settings can differ from its frames).
    private func configure(for f: UnsafeMutablePointer<AVFrame>) -> Bool {
        guard let enc = enc else { return false }
        swr_free(&swr)
        var inLayout = AVChannelLayout()
        if f.pointee.ch_layout.order == AV_CHANNEL_ORDER_UNSPEC || f.pointee.ch_layout.nb_channels == 0 {
            av_channel_layout_default(&inLayout, max(1, f.pointee.ch_layout.nb_channels))
        } else {
            av_channel_layout_copy(&inLayout, &f.pointee.ch_layout)
        }
        defer { av_channel_layout_uninit(&inLayout) }
        var outLayout = AVChannelLayout()
        av_channel_layout_copy(&outLayout, &enc.pointee.ch_layout)
        defer { av_channel_layout_uninit(&outLayout) }
        let inRate = f.pointee.sample_rate > 0 ? f.pointee.sample_rate : rate
        guard swr_alloc_set_opts2(&swr, &outLayout, AV_SAMPLE_FMT_FLTP, rate,
                                  &inLayout, AVSampleFormat(rawValue: f.pointee.format), inRate, 0, nil) >= 0,
              swr_init(swr) >= 0 else {
            swr_free(&swr)
            return false
        }
        return true
    }

    private func convert(_ f: UnsafeMutablePointer<AVFrame>) -> Int32? {
        guard let enc = enc, let fifo = fifo else { return nil }
        if swr == nil, !configure(for: f) { return nil }
        var out: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&out) }
        guard let o = out else { return nil }
        av_channel_layout_copy(&o.pointee.ch_layout, &enc.pointee.ch_layout)
        o.pointee.sample_rate = rate
        o.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        var r = swr_convert_frame(swr, o, f)
        if r < 0 {
            // The sound's layout or rate changed part-way: set up again and retry once
            av_frame_unref(o)
            av_channel_layout_copy(&o.pointee.ch_layout, &enc.pointee.ch_layout)
            o.pointee.sample_rate = rate
            o.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            guard configure(for: f) else { return nil }
            r = swr_convert_frame(swr, o, f)
            if r < 0 { return nil } // skip a frame that won't convert
        }
        guard o.pointee.nb_samples > 0, let data = o.pointee.extended_data else { return nil }
        av_audio_fifo_write(fifo, UnsafeRawPointer(data).assumingMemoryBound(to: UnsafeMutableRawPointer?.self), o.pointee.nb_samples)
        return nil
    }

    /// Encode whole AAC frames from what's been converted.
    private func drain(final: Bool, write: (UnsafeMutablePointer<AVPacket>) -> Int32) -> Int32? {
        guard let enc = enc, let fifo = fifo else { return nil }
        let size = enc.pointee.frame_size > 0 ? enc.pointee.frame_size : 1024
        while av_audio_fifo_size(fifo) >= size || (final && av_audio_fifo_size(fifo) > 0) {
            let n = min(size, av_audio_fifo_size(fifo))
            var ef: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            defer { av_frame_free(&ef) }
            guard let e = ef else { return nil }
            e.pointee.nb_samples = n
            av_channel_layout_copy(&e.pointee.ch_layout, &enc.pointee.ch_layout)
            e.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            e.pointee.sample_rate = rate
            guard av_frame_get_buffer(e, 0) >= 0, let data = e.pointee.extended_data else { return nil }
            av_audio_fifo_read(fifo, UnsafeRawPointer(data).assumingMemoryBound(to: UnsafeMutableRawPointer?.self), n)
            e.pointee.pts = nextPts
            nextPts += Int64(n)
            let r = avcodec_send_frame(enc, e)
            if r < 0 && r != -EAGAIN { return r }
            if let err = receive(write: write), err < 0 { return err }
        }
        return nil
    }

    private func receive(write: (UnsafeMutablePointer<AVPacket>) -> Int32) -> Int32? {
        guard let enc = enc, let p = outPkt, let output = output else { return nil }
        while avcodec_receive_packet(enc, p) >= 0 {
            p.pointee.stream_index = output.pointee.index
            av_packet_rescale_ts(p, enc.pointee.time_base, output.pointee.time_base)
            let r = write(p) // takes the packet's data
            if r < 0 { return r }
        }
        return nil
    }
}

// MARK: - the web server the Apple TV reads from

/// Serves one folder's files on the phone's Wi-Fi address, under a random path only the TV is given.
final class LocalFileServer: @unchecked Sendable {
    private let root: URL
    private let token: String
    private let queue = DispatchQueue(label: "com.ymplayer.airplay.server")
    private var listener: NWListener?

    init(root: URL, token: String) {
        self.root = root
        self.token = token
    }

    /// Start listening; `ready` gets the port (or nil) once, on the main thread.
    func start(ready: @escaping (UInt16?) -> Void) {
        let answered = CancelFlag() // "cancelled" here means "already answered"
        let answer: (UInt16?) -> Void = { p in
            DispatchQueue.main.async {
                guard !answered.cancelled else { return }
                answered.cancelled = true
                ready(p)
            }
        }
        do {
            let l = try NWListener(using: .tcp, on: .any)
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.stateUpdateHandler = { st in
                switch st {
                case .ready: answer(l.port?.rawValue)
                case .failed, .cancelled: answer(nil)
                default: break
                }
            }
            listener = l
            l.start(queue: queue)
        } catch {
            answer(nil)
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        receiveRequest(c, buffer: Data())
    }

    private func receiveRequest(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self = self else { c.cancel(); return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
                self.respond(c, head: head)
            } else if error != nil || done || buf.count > 65536 {
                c.cancel()
            } else {
                self.receiveRequest(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { return send(c, status: "405 Method Not Allowed") }
        let isHead = parts[0] == "HEAD"
        let path = String(parts[1].split(separator: "?").first ?? "")
        let comps = path.split(separator: "/").map(String.init)
        guard comps.count == 2, comps[0] == token, !comps[1].contains(".."), !comps[1].hasPrefix(".") else {
            return send(c, status: "404 Not Found")
        }
        let name = comps[1]
        let file = root.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return send(c, status: "404 Not Found") }

        let type: String
        if name.hasSuffix(".m3u8") { type = "application/vnd.apple.mpegurl" }
        else if name.hasSuffix(".m4s") || name.hasSuffix(".mp4") { type = "video/mp4" }
        else { type = "application/octet-stream" }

        var status = "200 OK"
        var body = data
        var extra = ""
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }), let r = Self.byteRange(range, size: data.count) {
            status = "206 Partial Content"
            body = data.subdata(in: r)
            extra = "Content-Range: bytes \(r.lowerBound)-\(r.upperBound - 1)/\(data.count)\r\n"
        }
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\n" + extra +
            (name.hasSuffix(".m3u8") ? "Cache-Control: no-cache\r\n" : "") + "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        if !isHead { out.append(body) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    private func send(_ c: NWConnection, status: String) {
        let s = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        c.send(content: Data(s.utf8), completion: .contentProcessed { _ in c.cancel() })
    }

    /// "Range: bytes=a-b" → a..<b+1 within the file.
    private static func byteRange(_ line: String, size: Int) -> Range<Int>? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let spec = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        let ab = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard ab.count == 2, size > 0 else { return nil }
        if ab[0].isEmpty, let n = Int(ab[1]) { return max(0, size - n)..<size } // the last n bytes
        guard let a = Int(ab[0]), a < size else { return nil }
        let b = ab[1].isEmpty ? size - 1 : min(Int(ab[1]) ?? size - 1, size - 1)
        guard b >= a else { return nil }
        return a..<(b + 1)
    }

    /// The phone's address on Wi-Fi (what the TV connects to).
    static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var other: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  a.ifa_flags & UInt32(IFF_UP) != 0, a.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if name == "en0" { return ip }
            if other == nil { other = ip }
        }
        return other
    }
}

// MARK: - reading the file from the provider

/// Reads the provider's file with iOS's own networking (URLSession: redirects, HTTPS and the user agent
/// handled the same way as the rest of the app) and hands the bytes to FFmpeg, seeking with range requests.
final class HTTPSource: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let userAgent: String
    private var session: URLSession!
    private let cond = NSCondition()

    // All below guarded by `cond`
    private var buffer = Data()          // bytes of the file from `bufferStart`
    private var bufferStart: Int64 = 0
    private var readPos: Int64 = 0
    private var skip: Int64 = 0          // a server that ignores ranges: bytes to throw away
    private var task: URLSessionDataTask?
    private var generation = 0
    private var responded = false
    private var finished = false
    private var failure: String?
    private var cancelled = false
    private var suspended = false
    private(set) var size: Int64 = -1
    private(set) var rangesWork = false

    private let maxBuffered = 24 << 20   // stop downloading this far ahead of FFmpeg
    private let keepBehind = 2 << 20     // keep a little already-read data for short backward seeks

    init(url: URL, userAgent: String) {
        self.url = url
        self.userAgent = userAgent
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
    }

    /// Connect and wait for the server's answer. Returns an error message, or nil once it's sending the file.
    func open() -> String? {
        cond.lock()
        startTask(at: 0)
        let deadline = Date().addingTimeInterval(30)
        while !responded && !cancelled && failure == nil {
            if !cond.wait(until: deadline) { break }
        }
        let f = failure ?? (responded ? nil : (cancelled ? "Cancelled" : "Your provider didn't answer"))
        cond.unlock()
        return f
    }

    func cancel() {
        cond.lock()
        cancelled = true
        task?.cancel()
        cond.broadcast()
        cond.unlock()
        session.invalidateAndCancel()
    }

    /// Called with `cond` held.
    private func startTask(at offset: Int64) {
        task?.cancel()
        generation += 1
        buffer = Data()
        bufferStart = offset
        skip = 0
        responded = false
        finished = false
        failure = nil
        suspended = false
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        let t = session.dataTask(with: req)
        t.taskDescription = String(generation)
        task = t
        t.resume()
    }

    // MARK: URLSession

    /// The server's answer to the current request. Called with `cond` held.
    private func handleResponse(_ t: URLSessionTask) {
        guard !responded, failure == nil else { return }
        let http = t.response as? HTTPURLResponse
        let code = http?.statusCode ?? 200
        if code >= 400 {
            failure = "Your provider refused the video (HTTP \(code))"
            t.cancel()
            return
        }
        responded = true
        if code == 206, let cr = http?.value(forHTTPHeaderField: "Content-Range"),
           let total = cr.split(separator: "/").last.flatMap({ Int64($0) }) {
            rangesWork = true
            size = total
        } else {
            // A whole-file answer: if we asked for a later part, throw away the bytes before it
            skip = bufferStart
            if let len = t.response?.expectedContentLength, len > 0 { size = len }
            if bufferStart == 0, http?.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes" { rangesWork = true }
        }
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        cond.lock()
        defer { cond.broadcast(); cond.unlock() }
        guard dataTask.taskDescription == String(generation) else { return }
        handleResponse(dataTask)
        guard failure == nil else { return }
        var d = data
        if skip > 0 {
            let n = Int(min(skip, Int64(d.count)))
            skip -= Int64(n)
            d = d.subdata(in: d.startIndex + n ..< d.endIndex)
        }
        buffer.append(d)
        if Int64(buffer.count) - (readPos - bufferStart) > Int64(maxBuffered), !suspended {
            suspended = true
            dataTask.suspend()
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        cond.lock()
        defer { cond.broadcast(); cond.unlock() }
        guard task.taskDescription == String(generation) else { return }
        if error == nil { handleResponse(task) }
        finished = true
        if let e = error as NSError?, e.code != NSURLErrorCancelled, failure == nil {
            failure = e.localizedDescription
        }
    }

    // MARK: FFmpeg's side

    private static let EXIT: Int32 = -1_414_092_869 // AVERROR_EXIT
    private static let EOF: Int32 = -541_478_725    // AVERROR_EOF
    private static let IO: Int32 = -EIO

    /// Copy up to `n` bytes to `out`; waits for the download. Runs on the remux thread.
    func read(_ out: UnsafeMutablePointer<UInt8>, _ n: Int32) -> Int32 {
        cond.lock()
        defer { cond.unlock() }
        var retries = 0
        while true {
            if cancelled { return Self.EXIT }
            let end = bufferStart + Int64(buffer.count)
            if readPos >= bufferStart && readPos < end {
                let off = Int(readPos - bufferStart)
                let k = min(Int(n), buffer.count - off)
                buffer.withUnsafeBytes { raw in
                    out.update(from: raw.baseAddress!.advanced(by: off).assumingMemoryBound(to: UInt8.self), count: k)
                }
                readPos += Int64(k)
                // Let go of what's been read, keeping a little for short backward seeks
                let used = Int(readPos - bufferStart)
                if used > keepBehind * 2 {
                    let drop = used - keepBehind
                    buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + drop)
                    buffer = Data(buffer) // re-base indices at 0
                    bufferStart += Int64(drop)
                }
                if suspended, Int64(buffer.count) - (readPos - bufferStart) < Int64(maxBuffered / 2) {
                    suspended = false
                    task?.resume()
                }
                return Int32(k)
            }
            if size >= 0 && readPos >= size { return Self.EOF }
            if finished {
                // The download ended early or dropped: pick up where we are
                if size < 0 && failure == nil && readPos >= end { return Self.EOF }
                retries += 1
                if retries > 4 { return Self.IO }
                startTask(at: readPos)
                continue
            }
            if !cond.wait(until: Date().addingTimeInterval(25)) {
                retries += 1
                if retries > 4 { return Self.IO }
                startTask(at: readPos) // stalled: ask again
            }
        }
    }

    /// FFmpeg moves around the file (an MKV's index is often at the end).
    func seek(_ offset: Int64, _ whence: Int32) -> Int64 {
        cond.lock()
        defer { cond.unlock() }
        if whence & 0x10000 != 0 { return size } // AVSEEK_SIZE
        let target: Int64
        switch whence & 0xFF {
        case SEEK_SET: target = offset
        case SEEK_CUR: target = readPos + offset
        case SEEK_END:
            guard size >= 0 else { return -1 }
            target = size + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        let end = bufferStart + Int64(buffer.count)
        if target >= bufferStart && target <= end + (1 << 20) && !finished {
            readPos = target // in what we have, or just ahead of the download
        } else if target >= bufferStart && target < end {
            readPos = target
        } else {
            guard rangesWork || target == 0 else { return -1 }
            readPos = target
            startTask(at: target)
        }
        return target
    }
}
