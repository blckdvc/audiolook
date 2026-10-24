import Foundation

/// Estimation de tempo (BPM) par enveloppe d'attaques + autocorrélation.
/// Résultat indicatif (corrigeable à la main dans l'app).
enum BPMDetector {
    static func detect(_ src: AudioSource) -> Double {
        let sr = src.sampleRate
        let ch = max(1, src.channels)
        let n = src.frameCount
        guard n > Int(sr / 2) else { return 120 }

        // enveloppe RMS ~200 Hz (mono)
        let hop = max(1, Int(sr / 200.0))
        var env: [Float] = []; env.reserveCapacity(n / hop + 1)
        var i = 0
        while i < n {
            let end = min(i + hop, n)
            var e: Float = 0
            for j in i..<end {
                var s: Float = 0
                for c in 0..<ch { s += src.frames[c][j] }
                s /= Float(ch); e += s * s
            }
            env.append((e / Float(max(1, end - i))).squareRoot())
            i += hop
        }
        guard env.count > 8 else { return 120 }

        // flux d'attaque (différence positive), centré
        var flux = [Float](repeating: 0, count: env.count)
        for k in 1..<env.count { flux[k] = max(0, env[k] - env[k - 1]) }
        let mean = flux.reduce(0, +) / Float(flux.count)
        for k in 0..<flux.count { flux[k] = max(0, flux[k] - mean) }

        // autocorrélation sur 70..180 BPM
        let envRate = sr / Double(hop)
        let minBPM = 70.0, maxBPM = 180.0
        let minLag = max(1, Int((60.0 / maxBPM) * envRate))
        let maxLag = min(flux.count - 1, Int((60.0 / minBPM) * envRate))
        guard maxLag > minLag else { return 120 }
        var corr = [Float](repeating: 0, count: maxLag + 1)
        var bestLag = minLag; var best: Float = -1
        for lag in minLag...maxLag {
            var sum: Float = 0; var k = 0
            while k + lag < flux.count { sum += flux[k] * flux[k + lag]; k += 1 }
            corr[lag] = sum
            // légère préférence pour les lags courts (évite les sous-harmoniques)
            let w = sum / Float(lag).squareRoot()
            if w > best { best = w; bestLag = lag }
        }
        // Raffinement sub-lag (interpolation parabolique) : le lag entier quantifie
        // le tempo (≈ ±1 BPM), l'interpolation redonne un lag fractionnaire précis.
        var lag = Double(bestLag)
        if bestLag > minLag, bestLag < maxLag {
            let y0 = corr[bestLag - 1], y1 = corr[bestLag], y2 = corr[bestLag + 1]
            let denom = y0 - 2 * y1 + y2
            if denom != 0 {
                let delta = 0.5 * Double(y0 - y2) / Double(denom)
                if delta > -1, delta < 1 { lag += delta }
            }
        }
        var bpm = 60.0 * envRate / lag
        while bpm < 80 { bpm *= 2 }
        while bpm > 160 { bpm /= 2 }
        return (bpm).rounded()
    }
}
