import AVFoundation

/// Lecture en boucle d'un échantillon rendu hors-ligne (Signalsmith) :
/// pitch/stretch haute qualité, volume temps réel, région A/B,
/// et transitions sans clic (fondus courts + bouclage à fondu enchaîné).
final class LoopPlayer: PlaybackEngine {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    private(set) var source: AudioSource?
    private var processed: AVAudioPCMBuffer?
    private var format: AVAudioFormat?

    private(set) var rate: Float = 1
    private(set) var transpose: Float = 0
    var bypass = false            // désactive pitch/stretch (joue l'original)
    private var effRate: Float { bypass ? 1 : rate }
    private var effSemi: Float { bypass ? 0 : transpose }
    var volume: Float { get { node.volume } set { node.volume = max(0, min(1, newValue)) } }

    private(set) var loopEnabled = true
    private(set) var loopA: Double = 0
    private(set) var loopB: Double = 1

    private(set) var isPlaying = false
    var onStateChange: (() -> Void)?
    var onReprocessed: (() -> Void)?

    private var generation = 0
    private var bufferStartFrame = 0
    private var subLen = 1
    private var offsetInSub = 0
    private var pausedGlobal: Double = 0

    private let renderQueue = DispatchQueue(label: "audiolook.render", qos: .userInitiated)
    private var renderToken = 0

    // durées des fondus
    private var fadeFrames: Int { max(64, Int(0.006 * sampleRate)) }   // ~6 ms (bords de buffer)
    private var xfadeFrames: Int { max(256, Int(0.025 * sampleRate)) } // ~25 ms (bouclage)

    var sampleRate: Double { source?.sampleRate ?? 44_100 }
    var processedLength: Int { Int(processed?.frameLength ?? 0) }
    var duration: TimeInterval { Double(processedLength) / sampleRate }
    var regionDuration: TimeInterval { duration * (loopB - loopA) }

    // MARK: Chargement

    func load(source src: AudioSource) {
        finishLoad(src)
    }

    private func finishLoad(_ src: AudioSource) {
        generation += 1
        node.stop()
        self.source = src
        loopA = 0; loopB = 1; pausedGlobal = 0   // la région A/B se réinitialise, pas les traitements
        format = AVAudioFormat(standardFormatWithSampleRate: src.sampleRate,
                               channels: AVAudioChannelCount(src.channels))
        processed = SampleProcessor.render(src, from: 0, to: src.frameCount, rate: effRate, semitones: effSemi)
        if let fmt = format {
            if node.engine == nil { engine.attach(node) }
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
        }
        engine.mainMixerNode.outputVolume = 1   // sécurité : jamais muet
        engine.prepare()
        play()
    }

    // MARK: Réglages

    func setRate(_ r: Float) { rate = max(0.5, min(2.0, r)) }
    func setTranspose(_ s: Float) { transpose = max(-24, min(24, s)) }

    func reprocess() {
        guard let src = source else { return }
        renderToken += 1
        let token = renderToken
        let r = effRate, t = effSemi
        let wasPlaying = isPlaying
        let g = currentGlobal
        renderQueue.async { [weak self] in
            let buf = SampleProcessor.render(src, from: 0, to: src.frameCount, rate: r, semitones: t)
            DispatchQueue.main.async {
                guard let self, token == self.renderToken, let buf else { return }
                self.processed = buf
                self.pausedGlobal = g
                if wasPlaying { self.play(fromGlobal: g) }
                self.onReprocessed?()
            }
        }
    }

    // MARK: Boucle A/B

    func setLoopRegion(a: Double, b: Double) {
        let lo = max(0, min(a, b)), hi = min(1, max(a, b))
        guard hi - lo > 0.001 else { return }
        loopA = lo; loopB = hi
        var g = currentGlobal
        if g < loopA || g > loopB { g = loopA }
        if isPlaying { play(fromGlobal: g) } else { pausedGlobal = g }
    }

    func setLoop(_ enabled: Bool) {
        guard enabled != loopEnabled else { return }
        loopEnabled = enabled
        let g = currentGlobal
        if isPlaying { play(fromGlobal: g) } else { pausedGlobal = g }
    }

    // MARK: Position

    var currentGlobal: Double {
        guard isPlaying, processed != nil, processedLength > 0,
              let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt)
        else { return pausedGlobal }
        let played = Int(Double(max(pt.sampleTime, 0)) * sampleRate / pt.sampleRate)
        let posFromA = (offsetInSub + played) % max(1, subLen)
        return Double(bufferStartFrame + posFromA) / Double(processedLength)
    }
    var progress: Double { currentGlobal }
    var currentTime: TimeInterval { max(0, currentGlobal - loopA) * duration }

    // MARK: Transport (avec fondus)

    func play(fromGlobal g: Double? = nil) {
        guard processed != nil, processedLength > 0 else { return }
        startSchedule(min(max(g ?? pausedGlobal, loopA), loopB))
    }

    private func startSchedule(_ gg: Double) {
        guard let processed else { return }
        let L = processedLength
        let aF = Int((loopA * Double(L)).rounded())
        let bF = max(aF + 1, Int((loopB * Double(L)).rounded()))
        let N = bF - aF

        generation += 1
        node.stop()
        if !engine.isRunning { do { try engine.start() } catch { return } }
        engine.mainMixerNode.outputVolume = 1

        let xf = min(xfadeFrames, N / 4)
        if loopEnabled && N > xf * 2 + 16 {
            // un seul buffer bouclé (l'attaque du début est préservée, voir makeLoopBody)
            if let body0 = makeLoopBody(processed, aF: aF, bF: bF, xf: xf) {
                let bodyLen = Int(body0.frameLength)
                let offset = min(max(Int(((gg - loopA) * Double(L)).rounded()), 0), bodyLen - 1)
                let body = offset > 0 ? (rotate(body0, by: offset) ?? body0) : body0
                node.scheduleBuffer(body, at: nil, options: .loops, completionCallbackType: .dataConsumed) { _ in }
                subLen = bodyLen; bufferStartFrame = aF; offsetInSub = offset
            }
        } else {
            // lecture simple (boucle off ou région trop courte)
            let offset = min(max(Int(((gg - loopA) * Double(L)).rounded()), 0), N - 1)
            let gen = generation
            if let head = makeSub(processed, from: aF + offset, to: bF, fadeIn: true, fadeOut: true) {
                let type: AVAudioPlayerNodeCompletionCallbackType = loopEnabled ? .dataConsumed : .dataPlayedBack
                node.scheduleBuffer(head, at: nil, options: loopEnabled ? .loops : [], completionCallbackType: type) { [weak self] _ in
                    if !self!.loopEnabled { DispatchQueue.main.async { self?.headFinished(gen) } }
                }
            }
            subLen = N; bufferStartFrame = aF; offsetInSub = offset
        }
        node.play()
        isPlaying = true
    }

    private func headFinished(_ gen: Int) {
        guard gen == generation, isPlaying, !loopEnabled else { return }
        node.stop(); isPlaying = false; pausedGlobal = loopA; onStateChange?()
    }

    func pause() {
        guard isPlaying else { return }
        pausedGlobal = currentGlobal
        generation += 1
        node.stop(); isPlaying = false; onStateChange?()
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func seek(toGlobal g: Double) {
        let gg = min(max(g, 0), 1)
        if isPlaying { play(fromGlobal: gg) } else { pausedGlobal = gg }
    }

    func stop() {
        generation += 1
        node.stop(); engine.stop(); isPlaying = false
    }

    // MARK: Fabrication de buffers

    private func rotate(_ buf: AVAudioPCMBuffer, by off: Int) -> AVAudioPCMBuffer? {
        let n = Int(buf.frameLength)
        guard n > 0, off % n != 0,
              let out = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: AVAudioFrameCount(n)),
              let s = buf.floatChannelData, let d = out.floatChannelData else { return buf }
        let ch = Int(buf.format.channelCount)
        let o = ((off % n) + n) % n
        for c in 0..<ch {
            d[c].update(from: s[c] + o, count: n - o)
            (d[c] + (n - o)).update(from: s[c], count: o)
        }
        out.frameLength = AVAudioFrameCount(n)
        return out
    }

    private func makeSub(_ buf: AVAudioPCMBuffer, from a: Int, to b: Int,
                         fadeIn: Bool, fadeOut: Bool) -> AVAudioPCMBuffer? {
        let L = Int(buf.frameLength)
        let s = max(0, min(a, L)), e = max(s + 1, min(b, L))
        let n = e - s
        guard n > 0, let sub = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: AVAudioFrameCount(n)),
              let src = buf.floatChannelData, let dst = sub.floatChannelData else { return nil }
        let ch = Int(buf.format.channelCount)
        let f = min(fadeFrames, n / 2)
        for c in 0..<ch {
            dst[c].update(from: src[c] + s, count: n)
            if fadeIn { for i in 0..<f { dst[c][i] *= Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(f))) } }
            if fadeOut { for i in 0..<f { dst[c][n - 1 - i] *= Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(f))) } }
        }
        sub.frameLength = AVAudioFrameCount(n)
        return sub
    }

    /// Buffer de boucle en préservant l'attaque du début (le kick, etc.).
    /// Stratégie par ordre de priorité :
    ///  1. raccord fin→début déjà quasi continu (vraie boucle) → aucun fondu, tête 100 % intacte ;
    ///  2. audio disponible avant la région (A>0) → la queue fond vers ce « pré-roll » → tête intacte ;
    ///  3. la région démarre quasi au silence → la queue fond vers 0, l'attaque repart de zéro naturellement ;
    ///  4. sinon (démarrage non nul, pas de pré-roll) → fondu enchaîné tête/queue classique (anti-clic).
    private func makeLoopBody(_ buf: AVAudioPCMBuffer, aF: Int, bF: Int, xf: Int) -> AVAudioPCMBuffer? {
        let N = bF - aF
        guard N > xf * 2, let src = buf.floatChannelData else { return nil }
        let ch = Int(buf.format.channelCount)

        // mesures : discontinuité au raccord, et niveau au tout début
        var seam: Float = 0, headLevel: Float = 0
        let probe = min(xf, 64)
        for c in 0..<ch {
            let s = src[c] + aF
            seam += abs(s[0] - s[N - 1])
            for i in 0..<probe { headLevel += abs(s[i]) }
        }
        seam /= Float(ch)
        headLevel /= Float(max(1, probe * ch))

        let seamSmooth = seam < 0.03            // boucle déjà propre → pas besoin de fondu
        let havePreroll = aF >= xf
        let silentHead = headLevel < 0.03

        if seamSmooth {
            // longueur N exacte, tout intact
            guard let out = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: AVAudioFrameCount(N)),
                  let dst = out.floatChannelData else { return nil }
            for c in 0..<ch { dst[c].update(from: src[c] + aF, count: N) }
            out.frameLength = AVAudioFrameCount(N)
            return out
        }

        if havePreroll || silentHead {
            // longueur N : tête (attaque) intacte, seule la queue est traitée
            guard let out = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: AVAudioFrameCount(N)),
                  let dst = out.floatChannelData else { return nil }
            for c in 0..<ch {
                let s = src[c]
                let d = dst[c]
                for i in 0..<(N - xf) { d[i] = s[aF + i] }          // tête + corps intacts
                for i in 0..<xf {
                    let t = (Double(i) + 0.5) / Double(xf)
                    let wOut = Float(cos(0.5 * Double.pi * t))       // la vraie queue s'efface
                    let tail = s[aF + N - xf + i] * wOut
                    // matière entrante : pré-roll (juste avant A) si dispo, sinon rien (silence)
                    let inc = havePreroll ? s[aF - xf + i] * Float(sin(0.5 * Double.pi * t)) : 0
                    d[N - xf + i] = tail + inc
                }
            }
            out.frameLength = AVAudioFrameCount(N)
            return out
        }

        // repli anti-clic : fondu enchaîné tête/queue (longueur N-xf) — atténue un peu l'attaque
        let loopLen = N - xf
        guard let out = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: AVAudioFrameCount(loopLen)),
              let dst = out.floatChannelData else { return nil }
        for c in 0..<ch {
            let s = src[c] + aF
            let d = dst[c]
            for i in xf..<loopLen { d[i] = s[i] }
            for i in 0..<xf {
                let t = (Double(i) + 0.5) / Double(xf)
                let wIn = Float(sin(0.5 * Double.pi * t))
                let wOut = Float(cos(0.5 * Double.pi * t))
                d[i] = s[i] * wIn + s[i + loopLen] * wOut
            }
        }
        out.frameLength = AVAudioFrameCount(loopLen)
        return out
    }

    // MARK: Export

    /// Rend la portion [a, b] (fractions 0…1) du fichier source, traitements appliqués.
    func renderRegionForExport(a: Double, b: Double) -> AVAudioPCMBuffer? {
        guard let src = source else { return nil }
        let n = src.frameCount
        let lo = max(0, min(a, b)), hi = min(1, max(a, b))
        let af = Int((lo * Double(n)).rounded())
        let bf = max(af + 1, Int((hi * Double(n)).rounded()))
        return SampleProcessor.render(src, from: af, to: bf, rate: effRate, semitones: effSemi)
    }
}
