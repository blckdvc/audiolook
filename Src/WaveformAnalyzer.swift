import AVFoundation

/// Calcule la forme d'onde (pic + RMS par colonne) par morceaux, en arrière-plan,
/// avec publication progressive.
final class WaveformAnalyzer {
    struct Result { var peaks: [Float]; var rms: [Float] }
    private var cancelled = false
    private let queue = DispatchQueue(label: "audiolook.waveform", qos: .userInitiated)

    func cancel() { cancelled = true }

    func analyze(url: URL, bins: Int = 1600, update: @escaping (Result) -> Void) {
        cancelled = false
        queue.async { [weak self] in self?.run(url: url, bins: bins, update: update) }
    }

    private func run(url: URL, bins binsHint: Int, update: @escaping (Result) -> Void) {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return }
        let length = file.length
        // Résolution adaptée à la durée : ~1 point tous les 64 échantillons, pour un
        // zoom net, bornée pour la mémoire (≈ 2,3 Mo de pics/RMS au maximum).
        let bins = min(max(Int(length / 64), binsHint), 300_000)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }

        var peaks = [Float](repeating: 0, count: bins)
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
            let r = Result(peaks: peaks, rms: rms)
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
                var peak: Float = 0, sq: Float = 0
                for c in 0..<channels { let v = data[c][f]; peak = max(peak, abs(v)); sq += v * v }
                if peak > peaks[bin] { peaks[bin] = peak }
                sumSquares[bin] += Double(sq / Float(channels)); counts[bin] += 1
            }
            position += AVAudioFramePosition(n)
            since += 1
            if since >= 8 { since = 0; publish() }
        }
        if !cancelled { publish() }
    }
}
