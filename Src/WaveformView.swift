import Cocoa

/// Forme d'onde : pics + RMS, partie jouée en accent, tête de lecture,
/// région de boucle A/B (poignées glissables), clic pour se positionner,
/// glisser le corps pour exporter le WAV, et zoom (molette / pinch trackpad).
final class WaveformView: NSView, NSDraggingSource {
    var peaks: [Float] = [] { didSet { zoom = 1; viewStart = 0; needsDisplay = true } }
    var rms: [Float] = [] { didSet { needsDisplay = true } }
    var progress: Double = 0 { didSet { if oldValue != progress { needsDisplay = true } } }
    var loopA: Double = 0 { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var loopB: Double = 1 { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var gridEnabled = false { didSet { needsDisplay = true } }
    var gridSpacing: Double = 0 { didSet { needsDisplay = true } }   // fraction 0..1 entre deux lignes

    var onSeek: ((Double) -> Void)?
    var onLoopChange: ((Double, Double) -> Void)?
    var provideURL: (() -> URL?)?                   // fournit le WAV traité à exporter au glisser

    // Zoom : fenêtre visible = [viewStart, viewStart + span] en fractions du fichier.
    private var zoom: Double = 1                    // 1 = tout le fichier ; >1 = zoomé
    private var viewStart: Double = 0
    private var span: Double { 1.0 / zoom }
    private func fx(_ frac: Double) -> CGFloat { CGFloat((frac - viewStart) / span) * bounds.width }
    private func xf(_ x: CGFloat) -> Double { viewStart + Double(x / max(bounds.width, 1)) * span }
    private func clampStart(_ s: Double) -> Double { min(max(s, 0), max(0, 1 - span)) }

    private enum Drag { case none, seek, handleA, handleB, region }
    private var drag: Drag = .none
    private let handleHit: CGFloat = 13         // zone de préhension des poignées A/B
    private let moveBandH: CGFloat = 16            // bande du haut (entre A et B) pour déplacer la boucle
    private let exportThreshold: CGFloat = 6       // au-delà, un glisser sur le corps = export
    private var dragStartX: CGFloat = 0
    private var dragStartA: Double = 0
    private var dragStartB: Double = 0
    private var pressOrigin: NSPoint = .zero

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Zoom (molette souris / pinch trackpad / défilement deux doigts)

    override func scrollWheel(with e: NSEvent) {
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        let precise = e.hasPreciseScrollingDeltas
        // Panoramique : Shift + molette (souris) ou deux doigts horizontaux (trackpad)
        if e.modifierFlags.contains(.shift) || (precise && abs(dx) > abs(dy)) {
            let delta = abs(dx) >= abs(dy) ? dx : dy
            if precise {
                viewStart = clampStart(viewStart - Double(delta / max(bounds.width, 1)) * span)
            } else {
                viewStart = clampStart(viewStart + (delta > 0 ? -1.0 : 1.0) * span * 0.15)
            }
            needsDisplay = true; window?.invalidateCursorRects(for: self)
            return
        }
        // Zoom : molette (souris) ou deux doigts verticaux (trackpad), autour du curseur
        guard dy != 0 else { return }
        let raw = precise ? 1 + Double(dy) * 0.005 : (dy > 0 ? 1.2 : 1 / 1.2)
        zoomBy(factor: min(max(raw, 0.5), 2), at: convert(e.locationInWindow, from: nil).x)
    }
    override func magnify(with e: NSEvent) {
        zoomBy(factor: 1 + Double(e.magnification), at: convert(e.locationInWindow, from: nil).x)
    }
    private func zoomBy(factor: Double, at x: CGFloat) {
        let anchor = xf(x)                                   // fraction sous le curseur, conservée
        zoom = min(max(zoom * factor, 1), 400)
        viewStart = clampStart(anchor - Double(x / max(bounds.width, 1)) * span)
        needsDisplay = true; window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let bg = NSBezierPath(roundedRect: b, xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(0.05).setFill(); bg.fill(); bg.addClip()

        let midY = b.midY, half = b.height / 2 - 8
        let xA = fx(loopA), xB = fx(loopB)
        let cxA = min(max(xA, 0), b.width), cxB = min(max(xB, 0), b.width)

        // zones hors boucle assombries (bornées à la fenêtre visible)
        NSColor.black.withAlphaComponent(0.28).setFill()
        if cxA > 0 { ctx.fill(CGRect(x: 0, y: 0, width: cxA, height: b.height)) }
        if cxB < b.width { ctx.fill(CGRect(x: cxB, y: 0, width: b.width - cxB, height: b.height)) }

        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        ctx.fill(CGRect(x: b.minX, y: midY - 0.5, width: b.width, height: 1))

        if gridEnabled && gridSpacing > 0.0005 {
            var idx = max(1, Int((viewStart / gridSpacing).rounded(.down)))
            var g = Double(idx) * gridSpacing
            while g < 1.0 {
                let x = fx(g)
                if x > b.width { break }
                if x >= 0 {
                    let strong = (idx % 4 == 0)   // repère plus marqué toutes les 4 subdivisions
                    NSColor.labelColor.withAlphaComponent(strong ? 0.30 : 0.14).setFill()
                    ctx.fill(CGRect(x: x, y: 0, width: strong ? 1 : 0.5, height: b.height))
                }
                idx += 1; g = Double(idx) * gridSpacing
            }
        }

        if !peaks.isEmpty {
            let scale = window?.backingScaleFactor ?? 2
            let step = 1 / scale
            let columns = max(1, Int(b.width / step))
            let playedX = fx(progress)
            let accent = NSColor.controlAccentColor
            let idle = NSColor(white: 0.62, alpha: 1)
            let count = Double(peaks.count)
            for col in 0..<columns {
                let x = CGFloat(col) * step
                let f0 = xf(x), f1 = xf(x + step)
                if f1 < 0 || f0 > 1 { continue }
                let lo = max(0, Int(f0 * count))
                if lo >= peaks.count { continue }
                let hi = min(peaks.count, max(lo + 1, Int(f1 * count)))
                var p: Float = 0, r: Float = 0
                for i in lo..<hi { p = max(p, peaks[i]); if i < rms.count { r = max(r, rms[i]) } }
                let inLoop = x >= cxA && x <= cxB
                let base = (x < playedX) ? accent : idle
                let ph = max(CGFloat(min(p, 1)) * half, 0.5)
                base.withAlphaComponent(inLoop ? 0.45 : 0.3).setFill()
                ctx.fill(CGRect(x: x, y: midY - ph, width: step, height: ph * 2))
                let rh = CGFloat(min(r, 1)) * half
                if rh > 0 { base.withAlphaComponent(inLoop ? 1 : 0.55).setFill(); ctx.fill(CGRect(x: x, y: midY - rh, width: step, height: rh * 2)) }
            }
        }

        // poignées A/B (si visibles)
        let accent = NSColor.controlAccentColor
        for x in [xA, xB] where x >= -4 && x <= b.width + 4 {
            accent.setFill()
            ctx.fill(CGRect(x: x - 1, y: 0, width: 2, height: b.height))
            NSBezierPath(roundedRect: CGRect(x: x - 4, y: 0, width: 8, height: 10), xRadius: 2, yRadius: 2).fill()
        }

        // barre de déplacement de la boucle (segment visible entre A et B)
        if cxB - cxA > 3 {
            accent.setFill()
            NSBezierPath(roundedRect: CGRect(x: cxA, y: 0, width: cxB - cxA, height: 5), xRadius: 2, yRadius: 2).fill()
            let cx = (cxA + cxB) / 2                 // petits points de « grip » au centre
            NSColor.black.withAlphaComponent(0.35).setFill()
            for k in -1...1 { ctx.fill(CGRect(x: cx + CGFloat(k) * 4 - 0.75, y: 1.5, width: 1.5, height: 2)) }
        }

        // tête de lecture
        let playedX = fx(progress)
        if playedX >= 0 && playedX <= b.width {
            NSColor.labelColor.setFill()
            ctx.fill(CGRect(x: min(max(playedX, 0), b.width - 1.5), y: b.minY, width: 1.5, height: b.height))
        }

        // indicateur de zoom (discret, en haut à droite)
        if zoom > 1.01 {
            let s = String(format: "×%.0f", zoom)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor]
            let sz = (s as NSString).size(withAttributes: attrs)
            (s as NSString).draw(at: NSPoint(x: b.width - sz.width - 6, y: 4), withAttributes: attrs)
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let xA = fx(loopA), xB = fx(loopB)
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
        let dx = Double((p.x - dragStartX) / max(bounds.width, 1)) * span
        var a = snap(dragStartA + dx)
        a = min(max(a, 0), max(0, 1 - len))
        loopA = a; loopB = min(1, a + len)
        onLoopChange?(loopA, loopB)
    }

    override func resetCursorRects() {
        let xA = fx(loopA), xB = fx(loopB)
        addCursorRect(CGRect(x: xA - handleHit, y: 0, width: handleHit * 2, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: xB - handleHit, y: 0, width: handleHit * 2, height: bounds.height), cursor: .resizeLeftRight)
        let innerX = xA + handleHit, innerW = (xB - handleHit) - (xA + handleHit)
        if innerW > 2 { addCursorRect(CGRect(x: innerX, y: 0, width: innerW, height: moveBandH), cursor: .openHand) }
    }

    private func seek(_ p: NSPoint) {
        let f = min(max(xf(p.x), 0), 1)
        progress = f; onSeek?(f)
    }
    private func snap(_ f: Double) -> Double {
        guard gridEnabled, gridSpacing > 0.0005 else { return f }
        let k = (f / gridSpacing).rounded()
        return min(max(k * gridSpacing, 0), 1)
    }
    private func updateHandles(_ p: NSPoint) {
        let f = snap(min(max(xf(p.x), 0), 1))
        if drag == .handleA { loopA = min(f, loopB - 0.001) }
        else { loopB = max(f, loopA + 0.001) }
        onLoopChange?(loopA, loopB)
    }
}
