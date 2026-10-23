import Cocoa

/// Forme d'onde : pics + RMS, partie jouée en accent, tête de lecture,
/// région de boucle A/B (poignées glissables), clic pour se positionner.
final class WaveformView: NSView {
    var peaks: [Float] = [] { didSet { needsDisplay = true } }
    var rms: [Float] = [] { didSet { needsDisplay = true } }
    var progress: Double = 0 { didSet { if oldValue != progress { needsDisplay = true } } }
    var loopA: Double = 0 { didSet { needsDisplay = true } }
    var loopB: Double = 1 { didSet { needsDisplay = true } }
    var gridEnabled = false { didSet { needsDisplay = true } }
    var gridSpacing: Double = 0 { didSet { needsDisplay = true } }   // fraction 0..1 entre deux lignes

    var onSeek: ((Double) -> Void)?
    var onLoopChange: ((Double, Double) -> Void)?

    private enum Drag { case none, seek, handleA, handleB }
    private var drag: Drag = .none
    private let handleHit: CGFloat = 10

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let bg = NSBezierPath(roundedRect: b, xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(0.05).setFill(); bg.fill(); bg.addClip()

        let midY = b.midY, half = b.height / 2 - 8
        let xA = b.width * CGFloat(loopA), xB = b.width * CGFloat(loopB)

        // zones hors boucle assombries
        NSColor.black.withAlphaComponent(0.28).setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: xA, height: b.height))
        ctx.fill(CGRect(x: xB, y: 0, width: b.width - xB, height: b.height))

        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        ctx.fill(CGRect(x: b.minX, y: midY - 0.5, width: b.width, height: 1))

        if gridEnabled && gridSpacing > 0.0005 {
            var g = gridSpacing
            var idx = 1
            while g < 1.0 {
                let x = b.width * CGFloat(g)
                let strong = (idx % 4 == 0)   // repère plus marqué toutes les 4 subdivisions
                NSColor.labelColor.withAlphaComponent(strong ? 0.30 : 0.14).setFill()
                ctx.fill(CGRect(x: x, y: 0, width: strong ? 1 : 0.5, height: b.height))
                g += gridSpacing; idx += 1
            }
        }

        if !peaks.isEmpty {
            let scale = window?.backingScaleFactor ?? 2
            let step = 1 / scale
            let columns = max(1, Int(b.width / step))
            let playedX = b.width * CGFloat(progress)
            let accent = NSColor.controlAccentColor
            let idle = NSColor(white: 0.62, alpha: 1)
            for col in 0..<columns {
                let x = CGFloat(col) * step
                let lo = Int(Double(col) / Double(columns) * Double(peaks.count))
                let hi = max(lo + 1, Int(Double(col + 1) / Double(columns) * Double(peaks.count)))
                var p: Float = 0, r: Float = 0
                for i in lo..<min(hi, peaks.count) { p = max(p, peaks[i]); if i < rms.count { r = max(r, rms[i]) } }
                let inLoop = x >= xA && x <= xB
                let base = (x < playedX) ? accent : idle
                let ph = max(CGFloat(min(p, 1)) * half, 0.5)
                base.withAlphaComponent(inLoop ? 0.45 : 0.3).setFill()
                ctx.fill(CGRect(x: x, y: midY - ph, width: step, height: ph * 2))
                let rh = CGFloat(min(r, 1)) * half
                if rh > 0 { base.withAlphaComponent(inLoop ? 1 : 0.55).setFill(); ctx.fill(CGRect(x: x, y: midY - rh, width: step, height: rh * 2)) }
            }
        }

        // poignées A/B
        let accent = NSColor.controlAccentColor
        for x in [xA, xB] {
            accent.setFill()
            ctx.fill(CGRect(x: x - 1, y: 0, width: 2, height: b.height))
            let r = CGRect(x: x - 4, y: 0, width: 8, height: 10)
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }

        // tête de lecture
        let playedX = b.width * CGFloat(progress)
        NSColor.labelColor.setFill()
        ctx.fill(CGRect(x: min(max(playedX, 0), b.width - 1.5), y: b.minY, width: 1.5, height: b.height))
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let xA = bounds.width * CGFloat(loopA), xB = bounds.width * CGFloat(loopB)
        if abs(p.x - xA) <= handleHit { drag = .handleA }
        else if abs(p.x - xB) <= handleHit { drag = .handleB }
        else { drag = .seek; seek(p) }
        if drag == .handleA || drag == .handleB { updateHandles(p) }
    }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch drag {
        case .seek: seek(p)
        case .handleA, .handleB: updateHandles(p)
        case .none: break
        }
    }
    override func mouseUp(with e: NSEvent) { drag = .none }

    private func seek(_ p: NSPoint) {
        let f = Double(min(max(p.x / bounds.width, 0), 1))
        progress = f; onSeek?(f)
    }
    private func snap(_ f: Double) -> Double {
        guard gridEnabled, gridSpacing > 0.0005 else { return f }
        let k = (f / gridSpacing).rounded()
        return min(max(k * gridSpacing, 0), 1)
    }
    private func updateHandles(_ p: NSPoint) {
        let f = snap(Double(min(max(p.x / bounds.width, 0), 1)))
        if drag == .handleA { loopA = min(f, loopB - 0.001) }
        else { loopB = max(f, loopA + 0.001) }
        onLoopChange?(loopA, loopB)
    }
}
