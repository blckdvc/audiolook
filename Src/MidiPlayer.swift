import AVFoundation
import AudioToolbox

// MARK: - Surface commune aux moteurs de lecture (audio & MIDI)

/// Interface de transport partagée par LoopPlayer (audio) et MidiPlayer (MIDI),
/// pour que PlayerViewController pilote l'un ou l'autre de façon uniforme.
protocol PlaybackEngine: AnyObject {
    var isPlaying: Bool { get }
    var loopEnabled: Bool { get }
    var loopA: Double { get }
    var loopB: Double { get }
    var progress: Double { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var regionDuration: TimeInterval { get }
    var volume: Float { get set }
    var bypass: Bool { get set }
    var onStateChange: (() -> Void)? { get set }
    func play(fromGlobal: Double?)
    func pause()
    func togglePlay()
    func seek(toGlobal: Double)
    func setLoop(_ enabled: Bool)
    func setLoopRegion(a: Double, b: Double)
    func setRate(_ r: Float)
    func setTranspose(_ s: Float)
    func reprocess()
    func stop()
}

// MARK: - Note MIDI (temps en beats)

struct MidiNote {
    var pitch: Int      // 0…127
    var start: Double   // en beats
    var dur: Double     // en beats
    var vel: Int
    var chan: Int
}

// MARK: - Lecture/écriture de fichiers Standard MIDI (SMF) via MusicSequence

enum MidiFile {

    /// Charge un .mid : liste de notes (en beats), tempo d'origine, longueur en beats, et octets bruts.
    static func load(url: URL) -> (notes: [MidiNote], tempoBPM: Double, beats: Double, data: Data)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var seqOpt: MusicSequence?
        guard NewMusicSequence(&seqOpt) == noErr, let seq = seqOpt else { return nil }
        defer { DisposeMusicSequence(seq) }
        guard MusicSequenceFileLoadData(seq, data as CFData,
                                        .anyType, MusicSequenceLoadFlags(rawValue: 0)) == noErr
        else { return nil }

        var notes: [MidiNote] = []
        var maxBeat = 0.0
        var trackCount: UInt32 = 0
        MusicSequenceGetTrackCount(seq, &trackCount)
        for ti in 0..<trackCount {
            var trackOpt: MusicTrack?
            guard MusicSequenceGetIndTrack(seq, ti, &trackOpt) == noErr, let track = trackOpt else { continue }
            forEachEvent(track) { ts, type, dataPtr, _ in
                if type == kMusicEventType_MIDINoteMessage, let dp = dataPtr {
                    let m = dp.load(as: MIDINoteMessage.self)
                    let start = Double(ts), dur = Double(m.duration)
                    notes.append(MidiNote(pitch: Int(m.note), start: start, dur: dur,
                                          vel: Int(m.velocity), chan: Int(m.channel)))
                    maxBeat = max(maxBeat, start + dur)
                }
            }
        }

        var tempoBPM = 120.0
        var tempoTrackOpt: MusicTrack?
        if MusicSequenceGetTempoTrack(seq, &tempoTrackOpt) == noErr, let tt = tempoTrackOpt {
            forEachEvent(tt) { _, type, dataPtr, _ in
                if type == kMusicEventType_ExtendedTempo, let dp = dataPtr, tempoBPM == 120.0 {
                    tempoBPM = dp.load(as: ExtendedTempoEvent.self).bpm
                }
            }
        }

        return (notes, tempoBPM, max(maxBeat, 0.0001), data)
    }

    /// Reconstruit un SMF : notes transposées de `semitones`, éventuellement limitées à `region`
    /// (fractions 0…1 de `totalBeats`, timestamps recalés à 0). On préserve les messages de canal
    /// (changements d'instrument, CC, pitch-bend). Tempo : copié tel quel si `tempoBPM` est nil,
    /// sinon un unique événement de tempo à 0.
    static func transformedData(base: Data, semitones: Int, region: (a: Double, b: Double)?,
                                totalBeats: Double, tempoBPM: Double?, channelVolume: Int? = nil) -> Data? {
        var srcOpt: MusicSequence?
        guard NewMusicSequence(&srcOpt) == noErr, let src = srcOpt else { return nil }
        defer { DisposeMusicSequence(src) }
        guard MusicSequenceFileLoadData(src, base as CFData,
                                        .anyType, MusicSequenceLoadFlags(rawValue: 0)) == noErr
        else { return nil }

        var dstOpt: MusicSequence?
        guard NewMusicSequence(&dstOpt) == noErr, let dst = dstOpt else { return nil }
        defer { DisposeMusicSequence(dst) }

        let aB = region.map { $0.a * totalBeats } ?? 0
        let bB = region.map { $0.b * totalBeats } ?? Double.greatestFiniteMagnitude
        let shift = aB

        // Tempo
        var dstTempoOpt: MusicTrack?
        MusicSequenceGetTempoTrack(dst, &dstTempoOpt)
        if let tempoBPM, let dstTempo = dstTempoOpt {
            MusicTrackNewExtendedTempoEvent(dstTempo, 0, tempoBPM)
        } else if let dstTempo = dstTempoOpt {
            var srcTempoOpt: MusicTrack?
            if MusicSequenceGetTempoTrack(src, &srcTempoOpt) == noErr, let srcTempo = srcTempoOpt {
                forEachEvent(srcTempo) { ts, type, dp, _ in
                    guard let dp else { return }
                    if type == kMusicEventType_ExtendedTempo {
                        MusicTrackNewExtendedTempoEvent(dstTempo, max(0, ts - shift), dp.load(as: ExtendedTempoEvent.self).bpm)
                    }
                }
            }
        }

        // Pistes
        var trackCount: UInt32 = 0
        MusicSequenceGetTrackCount(src, &trackCount)
        for ti in 0..<trackCount {
            var srcTrackOpt: MusicTrack?
            guard MusicSequenceGetIndTrack(src, ti, &srcTrackOpt) == noErr, let srcTrack = srcTrackOpt else { continue }
            var dstTrackOpt: MusicTrack?
            guard MusicSequenceNewTrack(dst, &dstTrackOpt) == noErr, let dstTrack = dstTrackOpt else { continue }

            forEachEvent(srcTrack) { ts, type, dp, _ in
                guard let dp else { return }
                switch type {
                case kMusicEventType_MIDINoteMessage:
                    guard region == nil || (ts >= aB && ts < bB) else { return }
                    var m = dp.load(as: MIDINoteMessage.self)
                    let p = Int(m.note) + semitones
                    guard p >= 0 && p <= 127 else { return }
                    m.note = UInt8(p)
                    if region != nil { m.duration = Float32(min(Double(m.duration), bB - ts)) }
                    var mm = m
                    MusicTrackNewMIDINoteEvent(dstTrack, max(0, ts - shift), &mm)
                case kMusicEventType_MIDIChannelMessage:
                    guard ts <= bB else { return }
                    var c = dp.load(as: MIDIChannelMessage.self)
                    MusicTrackNewMIDIChannelEvent(dstTrack, max(0, ts - shift), &c)
                default:
                    break
                }
            }
        }

        // Volume : contrôleur « Channel Volume » (CC7) à t=0 sur les 16 canaux (niveau, sans toucher au timbre).
        if let cv = channelVolume {
            var tOpt: MusicTrack?
            if MusicSequenceNewTrack(dst, &tOpt) == noErr, let t = tOpt {
                let v = UInt8(max(0, min(127, cv)))
                for ch in 0..<16 {
                    var m = MIDIChannelMessage(status: UInt8(0xB0 + ch), data1: 7, data2: v, reserved: 0)
                    MusicTrackNewMIDIChannelEvent(t, 0, &m)
                }
            }
        }

        var outData: Unmanaged<CFData>?
        guard MusicSequenceFileCreateData(dst, .midiType, MusicSequenceFileFlags(rawValue: 0),
                                          0, &outData) == noErr, let cf = outData else { return nil }
        return cf.takeRetainedValue() as Data
    }

    private static func forEachEvent(_ track: MusicTrack,
                                     _ body: (MusicTimeStamp, MusicEventType, UnsafeRawPointer?, UInt32) -> Void) {
        var iterOpt: MusicEventIterator?
        guard NewMusicEventIterator(track, &iterOpt) == noErr, let iter = iterOpt else { return }
        defer { DisposeMusicEventIterator(iter) }
        var has: DarwinBoolean = false
        MusicEventIteratorHasCurrentEvent(iter, &has)
        while has.boolValue {
            var ts: MusicTimeStamp = 0
            var type: MusicEventType = 0
            var dataPtr: UnsafeRawPointer?
            var size: UInt32 = 0
            MusicEventIteratorGetEventInfo(iter, &ts, &type, &dataPtr, &size)
            body(ts, type, dataPtr, size)
            MusicEventIteratorNextEvent(iter)
            MusicEventIteratorHasCurrentEvent(iter, &has)
        }
    }
}

// MARK: - Moteur de lecture MIDI (General MIDI via la banque DLS d'Apple)

final class MidiPlayer: PlaybackEngine {
    private var player: AVMIDIPlayer?
    private var baseData: Data?
    private(set) var rawNotes: [MidiNote] = []
    private(set) var totalBeats: Double = 1
    private(set) var sourceBPM: Double = 120

    private(set) var isPlaying = false
    private(set) var loopEnabled = true
    private(set) var loopA: Double = 0
    private(set) var loopB: Double = 1
    private(set) var duration: TimeInterval = 0

    private var rate: Float = 1
    private var transpose: Int = 0
    var bypass = false
    var onStateChange: (() -> Void)?

    private var pausedGlobal: Double = 0
    private var wrapTimer: Timer?
    private var volTimer: Timer?

    // Banque General MIDI intégrée à macOS.
    private let soundBank: URL? = {
        let p = "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"
        return FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
    }()

    // Volume : l'AVMIDIPlayer n'a pas de volume maître, on régénère la séquence avec un
    // contrôleur « Channel Volume » (CC7). Débattu pour rester fluide pendant le glissement.
    private var vol: Float = 1
    var volume: Float {
        get { vol }
        set {
            let v = max(0, min(1, newValue))
            guard abs(v - vol) > 0.001 else { return }
            vol = v
            volTimer?.invalidate()
            volTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in self?.rebuild(keepPosition: true) }
        }
    }

    var progress: Double {
        if let p = player, duration > 0, isPlaying { return min(max(p.currentPosition / duration, 0), 1) }
        return pausedGlobal
    }
    var currentTime: TimeInterval { max(0, progress - loopA) * duration }
    var regionDuration: TimeInterval { duration * (loopB - loopA) }

    // MARK: Chargement

    @discardableResult
    func load(url: URL) -> Bool {
        stop()
        guard let f = MidiFile.load(url: url) else { onStateChange?(); return false }
        baseData = f.data; rawNotes = f.notes; totalBeats = f.beats; sourceBPM = f.tempoBPM
        loopA = 0; loopB = 1; pausedGlobal = 0
        rebuild(keepPosition: false)
        guard player != nil, duration > 0 else { return false }
        play(fromGlobal: 0)
        return true
    }

    /// (Re)construit l'AVMIDIPlayer avec la transposition / le bypass courants.
    private func rebuild(keepPosition: Bool) {
        guard let baseData else { return }
        let wasPlaying = isPlaying
        let g = keepPosition ? progress : 0
        let semis = bypass ? 0 : transpose
        let cv = Int((vol * 127).rounded())
        let data = MidiFile.transformedData(base: baseData, semitones: semis, region: nil,
                                            totalBeats: totalBeats, tempoBPM: nil, channelVolume: cv) ?? baseData
        player?.stop()
        guard let p = try? AVMIDIPlayer(data: data, soundBankURL: soundBank) else { return }
        p.prepareToPlay()
        p.rate = bypass ? 1 : rate
        player = p
        duration = p.duration
        p.currentPosition = min(max(g, loopA), loopB) * duration
        if wasPlaying && keepPosition { p.play(nil); isPlaying = true; startWrapTimer() }
    }

    // MARK: Réglages

    func setRate(_ r: Float) {
        rate = max(0.5, min(2.0, r))
        if let p = player, !bypass { p.rate = rate }
    }
    func setTranspose(_ s: Float) { transpose = Int(max(-24, min(24, s)).rounded()) }

    /// Appelé (débattu) après un changement de pitch, ou au basculement du bypass : régénère la séquence.
    func reprocess() { rebuild(keepPosition: true) }

    // MARK: Boucle A/B

    func setLoopRegion(a: Double, b: Double) {
        let lo = max(0, min(a, b)), hi = min(1, max(a, b))
        guard hi - lo > 0.001 else { return }
        loopA = lo; loopB = hi
        var g = progress
        if g < loopA || g > loopB { g = loopA }
        if isPlaying { seekSeconds(g) } else { pausedGlobal = g }
    }
    func setLoop(_ enabled: Bool) { loopEnabled = enabled }

    // MARK: Transport

    func play(fromGlobal g: Double? = nil) {
        guard let p = player, duration > 0 else { return }
        let start = min(max(g ?? pausedGlobal, loopA), loopB)
        p.currentPosition = start * duration
        p.rate = bypass ? 1 : rate
        p.play(nil)
        isPlaying = true
        startWrapTimer()
        onStateChange?()
    }
    func pause() {
        guard isPlaying, let p = player else { return }
        pausedGlobal = progress
        p.stop()
        isPlaying = false
        stopWrapTimer()
        onStateChange?()
    }
    func togglePlay() { isPlaying ? pause() : play() }

    func seek(toGlobal g: Double) {
        let gg = min(max(g, 0), 1)
        if isPlaying { seekSeconds(gg) } else { pausedGlobal = gg }
    }
    private func seekSeconds(_ g: Double) { player?.currentPosition = min(max(g, 0), 1) * duration }

    func stop() {
        stopWrapTimer()
        volTimer?.invalidate(); volTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
    }

    // MARK: Bouclage manuel (AVMIDIPlayer ne boucle pas)

    private func startWrapTimer() {
        stopWrapTimer()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.wrapTick() }
        RunLoop.main.add(t, forMode: .common)
        wrapTimer = t
    }
    private func stopWrapTimer() { wrapTimer?.invalidate(); wrapTimer = nil }

    private func wrapTick() {
        guard isPlaying, let p = player, duration > 0 else { return }
        let pos = p.currentPosition
        let bSec = loopB * duration
        let aSec = loopA * duration
        let ended = !p.isPlaying || pos >= bSec - 0.005
        guard ended else { return }
        if loopEnabled {
            p.currentPosition = aSec
            if !p.isPlaying { p.play(nil) }
        } else {
            p.stop(); isPlaying = false; pausedGlobal = loopA; stopWrapTimer(); onStateChange?()
        }
    }

    // MARK: Export

    /// Écrit la région [a, b] (transposée, au tempo cible) dans un .mid temporaire.
    func exportRegion(a: Double, b: Double, targetBPM: Double, name: String) -> URL? {
        guard let baseData else { return nil }
        let full = a <= 0.0005 && b >= 0.9995
        let region: (a: Double, b: Double)? = full ? nil : (a, b)
        let semis = bypass ? 0 : transpose
        let tempo = bypass ? sourceBPM : targetBPM
        guard let data = MidiFile.transformedData(base: baseData, semitones: semis, region: region,
                                                  totalBeats: totalBeats, tempoBPM: tempo) else { return nil }
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audiolook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safe).appendingPathExtension("mid")
        try? FileManager.default.removeItem(at: url)
        do { try data.write(to: url); return url } catch { return nil }
    }
}
