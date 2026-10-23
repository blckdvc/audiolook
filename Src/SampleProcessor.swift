import AVFoundation

/// Échantillon source chargé en mémoire (float planaire).
struct AudioSource {
    var frames: [[Float]]      // [canal][frame]
    var sampleRate: Double
    var channels: Int
    var frameCount: Int { frames.first?.count ?? 0 }
}

enum SampleProcessor {

    static func read(url: URL) -> AudioSource? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let n = AVAudioFrameCount(file.length)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
        do { try file.read(into: buf) } catch { return nil }
        let ch = Int(fmt.channelCount)
        guard let data = buf.floatChannelData else { return nil }
        let len = Int(buf.frameLength)
        var frames = [[Float]](repeating: [], count: ch)
        for c in 0..<ch { frames[c] = Array(UnsafeBufferPointer(start: data[c], count: len)) }
        return AudioSource(frames: frames, sampleRate: fmt.sampleRate, channels: ch)
    }

    /// Rend [startFrame, endFrame) de `src` à la vitesse `rate` (1.5 = plus rapide) et transposition `semitones`.
    /// Haute qualité (Signalsmith, hors-ligne). Retourne un buffer Float32 non entrelacé, même SR.
    static func render(_ src: AudioSource, from startFrame: Int, to endFrame: Int,
                       rate: Float, semitones: Float) -> AVAudioPCMBuffer? {
        let ch = src.channels
        let s = max(0, min(startFrame, src.frameCount))
        let e = max(s, min(endFrame, src.frameCount))
        let inN = e - s
        guard inN > 0, ch > 0,
              let fmt = AVAudioFormat(standardFormatWithSampleRate: src.sampleRate,
                                      channels: AVAudioChannelCount(ch)) else { return nil }

        let passthrough = abs(rate - 1) < 1e-4 && abs(semitones) < 1e-4
        if passthrough {
            guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(inN)) else { return nil }
            out.frameLength = AVAudioFrameCount(inN)
            let od = out.floatChannelData!
            for c in 0..<ch {
                src.frames[c].withUnsafeBufferPointer { p in od[c].update(from: p.baseAddress! + s, count: inN) }
            }
            return out
        }

        let stretchRatio = 1.0 / Double(max(0.01, rate))
        let cap = Int((Double(inN) * stretchRatio).rounded()) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(cap)) else { return nil }
        let od = out.floatChannelData!

        // copies contiguës de la sous-plage d'entrée
        var inBufs: [UnsafeMutablePointer<Float>] = []
        inBufs.reserveCapacity(ch)
        for c in 0..<ch {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: inN)
            src.frames[c].withUnsafeBufferPointer { p.update(from: $0.baseAddress! + s, count: inN) }
            inBufs.append(p)
        }
        defer { inBufs.forEach { $0.deallocate() } }

        let inPtrs: [UnsafePointer<Float>?] = inBufs.map { UnsafePointer($0) }
        let outPtrs: [UnsafeMutablePointer<Float>?] = (0..<ch).map { od[$0] }
        var produced: Int32 = 0
        _ = inPtrs.withUnsafeBufferPointer { ip in
            outPtrs.withUnsafeBufferPointer { op in
                sl_render(ip.baseAddress, Int32(ch), Int32(inN), src.sampleRate,
                          stretchRatio, semitones, op.baseAddress, Int32(cap), &produced)
            }
        }
        out.frameLength = AVAudioFrameCount(max(0, Int(produced)))
        return out
    }

    /// Écrit un buffer en WAV 24 bits à l'URL donnée.
    static func writeWAV(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: buffer.format.channelCount,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
