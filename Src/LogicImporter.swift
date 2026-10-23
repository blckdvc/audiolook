import Cocoa
import AVFoundation

enum LogicImporter {

    /// Écrit le buffer dans un WAV temporaire nommé à partir du titre.
    static func exportTemp(_ buffer: AVAudioPCMBuffer, name: String) -> URL? {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LoopLook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safe).appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: url)
        do { try SampleProcessor.writeWAV(buffer, to: url); return url }
        catch { NSLog("export error \(error)"); return nil }
    }

    /// Import automatique dans le DAW actuellement au premier plan (Logic, Digital Performer, Live…).
    /// Repère dans la barre de menus de l'app une commande « Import…Audio » (toutes langues :
    /// `contains` est insensible à la casse), la déclenche puis saisit le chemin dans le sélecteur.
    /// Nécessite l'autorisation d'accessibilité.
    @discardableResult
    static func importIntoActiveDAW(_ url: URL) -> (ok: Bool, message: String) {
        guard let app = (NSApp.delegate as? AppDelegate)?.lastDAWApp, let rawName = app.localizedName else {
            return (false, "Aucun DAW actif détecté. Passe d'abord dans ton DAW (Logic, Digital Performer…), puis reviens cliquer sur Importer — ou glisse la pastille directement dedans.")
        }
        let name = esc(rawName)
        let path = esc(url.path)
        let bundleID = app.bundleIdentifier ?? ""
        let activate = bundleID.isEmpty ? "tell application \"\(name)\" to activate"
                                        : "tell application id \"\(esc(bundleID))\" to activate"

        // On DÉCOUVRE d'abord les noms (menu / item / sous-item), puis on clique par chemin nommé :
        // cliquer une référence d'item capturée pendant l'itération échoue en -1719 (sous-menu non
        // « réalisé »). Un clic par chemin nommé réalise le menu à la volée et reste fiable.
        let script = """
        set thePath to "\(path)"
        set topName to ""
        set impName to ""
        set childName to ""
        \(activate)
        delay 0.6
        tell application "System Events"
            tell process "\(name)"
                -- Passe 1 : import lié à l'audio (direct, ou via un sous-menu « Import » → « …Audio… »)
                repeat with mbi in menu bar items of menu bar 1
                    set tn to ""
                    try
                        set tn to name of mbi
                    end try
                    if tn is not "" and tn is not missing value then
                        try
                            repeat with mi in menu items of menu 1 of mbi
                                set nn to ""
                                try
                                    set nn to name of mi
                                end try
                                if nn is not "" and nn is not missing value and nn contains "Import" then
                                    if nn contains "Audio" then
                                        set topName to tn
                                        set impName to nn
                                        set childName to ""
                                        exit repeat
                                    else
                                        set hasSub to false
                                        try
                                            if exists menu 1 of mi then set hasSub to true
                                        end try
                                        if hasSub then
                                            try
                                                repeat with sm in menu items of menu 1 of mi
                                                    set sn to ""
                                                    try
                                                        set sn to name of sm
                                                    end try
                                                    if sn is not "" and sn is not missing value and sn contains "Audio" then
                                                        set topName to tn
                                                        set impName to nn
                                                        set childName to sn
                                                        exit repeat
                                                    end if
                                                end repeat
                                            end try
                                        end if
                                    end if
                                end if
                                if impName is not "" then exit repeat
                            end repeat
                        end try
                    end if
                    if impName is not "" then exit repeat
                end repeat
                -- Passe 2 : à défaut, une commande « Import… » directe (feuille, sans sous-menu)
                if impName is "" then
                    repeat with mbi in menu bar items of menu bar 1
                        set tn to ""
                        try
                            set tn to name of mbi
                        end try
                        if tn is not "" and tn is not missing value then
                            try
                                repeat with mi in menu items of menu 1 of mbi
                                    set nn to ""
                                    try
                                        set nn to name of mi
                                    end try
                                    if nn is not "" and nn is not missing value and nn contains "Import" then
                                        set hasSub to false
                                        try
                                            if exists menu 1 of mi then set hasSub to true
                                        end try
                                        if not hasSub then
                                            set topName to tn
                                            set impName to nn
                                            set childName to ""
                                            exit repeat
                                        end if
                                    end if
                                end repeat
                            end try
                        end if
                        if impName is not "" then exit repeat
                    end repeat
                end if
                if impName is "" then return "menu_introuvable"
                -- Clic par chemin nommé (réalise le menu, pas de référence périmée)
                try
                    if childName is "" then
                        click menu item impName of menu 1 of menu bar item topName of menu bar 1
                    else
                        click menu item childName of menu 1 of menu item impName of menu 1 of menu bar item topName of menu bar 1
                    end if
                on error errMsg number errNum
                    return "clic_echec:" & errNum
                end try
                -- Sélecteur de fichier : on saisit le chemin
                delay 0.8
                keystroke "g" using {command down, shift down}
                delay 0.4
                keystroke thePath
                delay 0.3
                keystroke return
                delay 0.5
                keystroke return
                delay 0.6
                try
                    click button "Importer" of window 1
                on error
                    try
                        click button "Ouvrir" of window 1
                    on error
                        try
                            click button "Import" of window 1
                        on error
                            try
                                click button "Open" of window 1
                            on error
                                keystroke return
                            end try
                        end try
                    end try
                end try
                return "ok"
            end tell
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err {
            let code = (err["NSAppleScriptErrorNumber"] as? Int) ?? 0
            if code == -1743 { return (false, "Autorisation d'accessibilité requise (Réglages Système › Confidentialité et sécurité › Accessibilité → coche LoopLook).") }
            return (false, "Échec du script d'import dans \(rawName) (\(code)).")
        }
        let s = result?.stringValue ?? ""
        if s == "ok" { return (true, "Import lancé dans \(rawName).") }
        if s == "menu_introuvable" { return (false, "Pas de commande d'import audio trouvée dans le menu de \(rawName). Glisse plutôt la pastille directement dans l'app.") }
        if s.hasPrefix("clic_echec:") { return (false, "Commande d'import trouvée dans \(rawName) mais le clic a échoué (\(s.dropFirst(11))). Glisse plutôt la pastille directement dans l'app.") }
        return (false, "Réponse inattendue : \(s)")
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Petite pastille source d'un glisser-déposer : fournit à la volée le WAV traité.
final class SampleDragView: NSView, NSDraggingSource {
    var provideURL: (() -> URL?)?
    var label: String = "Glisser vers un DAW / Finder"

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
