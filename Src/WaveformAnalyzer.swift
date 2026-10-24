import AVFoundation

/// Calcule l'enveloppe min/max (+ RMS) de la forme d'onde par morceaux, en
/// arrière-plan, avec publication progressive. Résolution élevée (jusqu'à ~1 point
/// par échantillon pour les fichiers courts) pour rester net au zoom.
final class WaveformAnalyzer {
    struct Result { var maxv: [Float]; var minv: [Float]; var rms: [Float] }
    private var cancelled = false
    private let queue = DispatchQueue(label: "audiolook.waveform", qos: .userInitiated)

    func cancel() { cancelled = true }

    func analyze(url: URL, update: @escaping (Result) -> Void) {
        cancelled = false
        queue.async { [weak self] in self?.run(url: url, update: update) }
    }

    private func run(url: URL, update: @escaping (Result) -> Void) {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return }
        let length = file.length
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }

        // ~1 point par échantillon pour les fichiers courts, borné pour la mémoire.
        let bins = max(1, min(Int(length), 500_000))
        var maxv = [Float](repeating: 0, count: bins)
        var minv = [Float](repeating: 0, count: bins)
        var sumSquares = [Double](repeating: 0, count: bins)
        var counts = [Int](repeating: 0, count: bins)
        let framesPerBin = Double(length) / Double(bins)
        var position: AVAudioFramePosition = 0
        var since = 0

        func publish() {
            var rms = [Float](repeating: 0, count: bins)
            for i in 0..<bins where counts[i] > 0 {
                rms[i] = Float((sumSquares[i] / Double(counts[i])).squareRoot())
            }
            let r = Result(maxv: maxv, minv: minv, rms: rms)
            DispatchQueue.main.async { update(r) }
        }

        while position < length, !cancelled {
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            for f in 0..<n {
                let bin = min(Int(Double(position + AVAudioFramePosition(f)) / framesPerBin), bins - 1)
                var m: Float = 0
                for c in 0..<channels { m += data[c][f] }
                m /= Float(channels)
                if m > maxv[bin] { maxv[bin] = m }
                if m < minv[bin] { minv[bin] = m }
                sumSquares[bin] += Double(m * m); counts[bin] += 1
            }
            position += AVAudioFramePosition(n)
            since += 1
            if since >= 8 { since = 0; publish() }
        }
        if !cancelled { publish() }
    }
}
