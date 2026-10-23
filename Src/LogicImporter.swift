import Cocoa
import AVFoundation

enum LogicImporter {

    /// Écrit le buffer dans un WAV temporaire nommé à partir du titre.
    static func exportTemp(_ buffer: AVAudioPCMBuffer, name: String) -> URL? {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audiolook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safe).appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: url)
        do { try SampleProcessor.writeWAV(buffer, to: url); return url }
        catch { NSLog("export error \(error)"); return nil }
    }
}

/// Petite pastille source d'un glisser-déposer : fournit à la volée le WAV traité.
/// C'est la méthode recommandée pour déposer la boucle dans un DAW : on la lâche
/// exactement à l'endroit voulu dans l'arrangement (position de la tête de lecture comprise).
final class SampleDragView: NSView, NSDraggingSource {
    var provideURL: (() -> URL?)?
    var label: String = Lang.t("Drag to a DAW / Finder", "Glisser vers un DAW / Finder")

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true; setup() }

    private let text = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    private func setup() {
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        icon.image = NSImage(systemSymbolName: "square.and.arrow.up.on.square", accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        text.font = .systemFont(ofSize: 11, weight: .medium)
        text.stringValue = label
        let s = NSStackView(views: [icon, text]); s.orientation = .horizontal; s.spacing = 6
        s.translatesAutoresizingMaskIntoConstraints = false
        s.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor),
            s.trailingAnchor.constraint(equalTo: trailingAnchor),
            s.topAnchor.constraint(equalTo: topAnchor),
            s.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateColors()
    }
    override func viewDidChangeEffectiveAppearance() { updateColors() }
    private func updateColors() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor
        text.stringValue = label
    }

    // Tout le bouton est zone de glisser (sinon l'icône et le texte captent le clic).
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func mouseDown(with e: NSEvent) {
        guard let url = provideURL?() else { NSSound.beep(); return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let img = bitmapSnapshot()
        item.setDraggingFrame(bounds, contents: img)
        beginDraggingSession(with: [item], event: e, source: self)
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }

    private func bitmapSnapshot() -> NSImage {
        let img = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            img.addRepresentation(rep)
        }
        return img
    }
}
