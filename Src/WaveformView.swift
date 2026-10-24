import Cocoa

/// Forme d'onde : pics + RMS, partie jouée en accent, tête de lecture,
/// région de boucle A/B (poignées glissables), clic pour se positionner,
/// et glisser le corps de la forme d'onde pour exporter le WAV vers un DAW / le Finder.
final class WaveformView: NSView, NSDraggingSource {
    var peaks: [Float] = [] { didSet { needsDisplay = true } }
    var rms: [Float] = [] { didSet { needsDisplay = true } }
    var progress: Double = 0 { didSet { if oldValue != progress { needsDisplay = true } } }
    var loopA: Double = 0 { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var loopB: Double = 1 { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var gridEnabled = false { didSet { needsDisplay = true } }
    var gridSpacing: Double = 0 { didSet { needsDisplay = true } }   // fraction 0..1 entre deux lignes

    var onSeek: ((Double) -> Void)?
    var onLoopChange: ((Double, Double) -> Void)?
    var provideURL: (() -> URL?)?                   // fournit le WAV traité à exporter au glisser

    private enum Drag { case none, seek, handleA, handleB, region }
    private var drag: Drag = .none
    private let handleHit: CGFloat = 10
    private let moveBandH: CGFloat = 16            // bande du haut (entre A et B) pour déplacer la boucle
    private let exportThreshold: CGFloat = 6       // au-delà, un glisser sur le corps = export
    private var dragStartX: CGFloat = 0
    private var dragStartA: Double = 0
    private var dragStartB: Double = 0
    private var pressOrigin: NSPoint = .zero

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

        // barre de déplacement de la boucle : une ligne en haut, entre A et B, qu'on attrape pour glisser
        if xB - xA > 3 {
            accent.setFill()
            NSBezierPath(roundedRect: CGRect(x: xA, y: 0, width: xB - xA, height: 5), xRadius: 2, yRadius: 2).fill()
            let cx = (xA + xB) / 2                 // petits points de « grip » au centre
            NSColor.black.withAlphaComponent(0.35).setFill()
            for k in -1...1 { ctx.fill(CGRect(x: cx + CGFloat(k) * 4 - 0.75, y: 1.5, width: 1.5, height: 2)) }
        }

        // tête de lecture
        let playedX = b.width * CGFloat(progress)
        NSColor.labelColor.setFill()
        ctx.fill(CGRect(x: min(max(playedX, 0), b.width - 1.5), y: b.minY, width: 1.5, height: b.height))
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let xA = bounds.width * CGFloat(loopA), xB = bounds.width * CGFloat(loopB)
        if abs(p.x - xA) <= handleHit { drag = .handleA; updateHandles(p) }
        else if abs(p.x - xB) <= handleHit { drag = .handleB; updateHandles(p) }
        else if p.y <= moveBandH && p.x > xA && p.x < xB {    // bande du haut → déplacer toute la boucle
            drag = .region; dragStartX = p.x; dragStartA = loopA; dragStartB = loopB
            NSCursor.closedHand.set()
        }
        // corps : on ne positionne pas tout de suite. Clic simple = se positionner,
        // glisser au-delà du seuil = exporter le WAV (drag-and-drop).
        else { drag = .seek; pressOrigin = p }
    }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch drag {
        case .seek:
            if hypot(p.x - pressOrigin.x, p.y - pressOrigin.y) > exportThreshold {
                drag = .none; beginExportDrag(with: e)
            }
        case .handleA, .handleB: updateHandles(p)
        case .region: moveRegion(p)
        case .none: break
        }
    }
    override func mouseUp(with e: NSEvent) {
        if drag == .seek { seek(convert(e.locationInWindow, from: nil)) }   // simple clic → se positionner
        drag = .none; window?.invalidateCursorRects(for: self)
    }

    // MARK: Export par glisser

    private func beginExportDrag(with e: NSEvent) {
        guard let url = provideURL?() else { NSSound.beep(); return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let img = dragBadge(url.lastPathComponent)
        let p = convert(e.locationInWindow, from: nil)
        let frame = NSRect(x: p.x - 14, y: p.y - img.size.height / 2,
                           width: img.size.width, height: img.size.height)
        item.setDraggingFrame(frame, contents: img)
        beginDraggingSession(with: [item], event: e, source: self)
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }

    /// Petite pastille affichée sous le curseur pendant le glisser (icône + nom du fichier).
    private func dragBadge(_ name: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let text = name as NSString
        let tsize = text.size(withAttributes: [.font: font])
        let pad: CGFloat = 8, iconW: CGFloat = 14, gap: CGFloat = 5, h: CGFloat = 24
        let w = min(pad + iconW + gap + ceil(tsize.width) + pad, 280)
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        NSColor.controlAccentColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: 6, yRadius: 6).fill()
        let conf = NSImage.SymbolConfiguration(paletteColors: [.white])
        if let sym = NSImage(systemSymbolName: "square.and.arrow.up.on.square", accessibilityDescription: nil)?
            .withSymbolConfiguration(conf) {
            sym.draw(in: NSRect(x: pad, y: (h - iconW) / 2, width: iconW, height: iconW))
        }
        text.draw(at: NSPoint(x: pad + iconW + gap, y: (h - tsize.height) / 2),
                  withAttributes: [.font: font, .foregroundColor: NSColor.white])
        img.unlockFocus()
        return img
    }

    /// Glisse toute la région A/B (longueur conservée), librement ou aimantée à la grille.
    private func moveRegion(_ p: NSPoint) {
        let len = dragStartB - dragStartA
        let dx = Double((p.x - dragStartX) / bounds.width)
        var a = snap(dragStartA + dx)
        a = min(max(a, 0), max(0, 1 - len))
        loopA = a; loopB = min(1, a + len)
        onLoopChange?(loopA, loopB)
    }

    override func resetCursorRects() {
        let w = bounds.width
        let xA = w * CGFloat(loopA), xB = w * CGFloat(loopB)
        addCursorRect(CGRect(x: xA - handleHit, y: 0, width: handleHit * 2, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: xB - handleHit, y: 0, width: handleHit * 2, height: bounds.height), cursor: .resizeLeftRight)
        let innerX = xA + handleHit, innerW = (xB - handleHit) - (xA + handleHit)
        if innerW > 2 { addCursorRect(CGRect(x: innerX, y: 0, width: innerW, height: moveBandH), cursor: .openHand) }
    }

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
