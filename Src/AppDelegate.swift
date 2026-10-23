import Cocoa
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NSWindowController?
    private var vc: PlayerViewController?
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?

    private var followSelection = true
    private var pollTimer: Timer?
    private var lastLoadedPath: String?
    private var followItem: NSMenuItem?

    private let audioExts: Set<String> = ["wav","aif","aiff","aifc","caf","mp3","m4a","aac","flac","ogg","opus"]

    func applicationDidFinishLaunching(_ note: Notification) {
        setupStatusItem()
        registerHotKey()
        startPolling()
    }

    // MARK: Barre de menus

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "LoopLook")
        let menu = NSMenu()
        menu.addItem(withTitle: "Ouvrir la sélection du Finder  (⌥Espace)", action: #selector(openFinderSelection), keyEquivalent: "")
        let follow = NSMenuItem(title: "Suivre la sélection du Finder", action: #selector(toggleFollow), keyEquivalent: "")
        follow.state = followSelection ? .on : .off
        menu.addItem(follow); followItem = follow
        menu.addItem(.separator())
        menu.addItem(withTitle: "À propos", action: #selector(about), keyEquivalent: "")
        menu.addItem(withTitle: "Quitter LoopLook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in menu.items { i.target = self }
        menu.items.last?.target = NSApp
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleFollow() {
        followSelection.toggle()
        followItem?.state = followSelection ? .on : .off
    }

    @objc private func about() {
        let a = NSAlert()
        a.messageText = "LoopLook"
        a.informativeText = "Lecteur de boucles : forme d'onde, boucle A/B, volume, vitesse et transposition (Signalsmith).\n\nSuivre la sélection du Finder : le player charge automatiquement le fichier audio sélectionné.\n⌥Espace : ouvrir la sélection · Espace : lecture/pause · L : boucle · ←/→ : fichier précédent/suivant · Échap : fermer"
        a.runModal()
    }

    // MARK: Ouverture

    @objc func openFinderSelection() {
        guard let path = finderSelectionPOSIXPath(), !path.isEmpty else { NSSound.beep(); return }
        open(url: URL(fileURLWithPath: path), follow: false)
    }

    func open(url: URL, follow: Bool) {
        let controller: NSWindowController
        if let wc = windowController { controller = wc }
        else {
            let c = PlayerViewController()
            let w = NSWindow(contentViewController: c)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titleVisibility = .hidden                 // barre de titre masquée
            w.titlebarAppearsTransparent = true
            w.title = "LoopLook"
            w.isMovableByWindowBackground = true        // on déplace par le fond (la forme d'onde ne bouge pas la fenêtre)
            w.setContentSize(NSSize(width: 580, height: 560))
            w.center()
            w.level = .floating
            w.delegate = c                              // arrête la lecture à la fermeture (windowWillClose)
            let wc = NSWindowController(window: w)
            windowController = wc; vc = c; controller = wc
        }
        lastLoadedPath = url.path
        if follow {
            // ne vole pas le focus : le Finder reste actif, le player suit
            controller.window?.orderFront(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        vc?.open(url: url)
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        if let u = urls.first { open(url: u, follow: false) }
    }

    // MARK: Suivi de la sélection

    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollSelection() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func pollSelection() {
        guard followSelection else { return }
        let path = finderSelectionPOSIXPath() ?? ""
        let isAudio = !path.isEmpty && audioExts.contains((path as NSString).pathExtension.lowercased())
        if isAudio {
            // recharge sur un nouveau fichier audio ; ne pas recharger pendant qu'on agit dans LoopLook
            if path != lastLoadedPath && !NSApp.isActive { open(url: URL(fileURLWithPath: path), follow: true) }
        } else {
            // sélection quittée (vide / dossier / non-audio) → stop + masque, comme Quick Look
            stopFollowing()
        }
    }

    private func stopFollowing() {
        guard lastLoadedPath != nil || (windowController?.window?.isVisible ?? false) else { return }
        vc?.suspend()
        windowController?.window?.orderOut(nil)
        lastLoadedPath = nil
    }

    // MARK: Sélection Finder (AppleScript)

    private func finderSelectionPOSIXPath() -> String? {
        let src = """
        tell application "Finder"
            set sel to selection
            if sel is {} then return ""
            return POSIX path of (item 1 of sel as alias)
        end tell
        """
        var err: NSDictionary?
        let out = NSAppleScript(source: src)?.executeAndReturnError(&err)
        return out?.stringValue
    }

    // MARK: Raccourci global ⌥Espace

    private func registerHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C4C4B31), id: 1)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.openFinderSelection() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
