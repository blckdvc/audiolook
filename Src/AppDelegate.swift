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

    private let audioExts: Set<String> = ["wav","aif","aiff","aifc","caf","mp3","m4a","aac","flac","ogg","opus","mid","midi"]

    func applicationDidFinishLaunching(_ note: Notification) {
        setupStatusItem()
        registerHotKey()
        startPolling()
    }

    // MARK: Barre de menus

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "audiolook")
        let menu = NSMenu()
        menu.addItem(withTitle: Lang.t("Open Finder selection", "Ouvrir la sélection du Finder"), action: #selector(openFinderSelection), keyEquivalent: "")
        let follow = NSMenuItem(title: Lang.t("Follow Finder selection", "Suivre la sélection du Finder"), action: #selector(toggleFollow), keyEquivalent: "")
        follow.state = followSelection ? .on : .off
        menu.addItem(follow); followItem = follow
        menu.addItem(.separator())
        menu.addItem(withTitle: Lang.t("About", "À propos"), action: #selector(about), keyEquivalent: "")
        // Pas de raccourci : l'app est un agent (LSUIElement) sans menu principal, ⌘Q n'est pas actif.
        menu.addItem(withTitle: Lang.t("Quit", "Quitter"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
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
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let a = NSAlert()
        a.messageText = "audiolook \(v)"
        a.informativeText = Lang.t(
            "Loop player: waveform, A/B loop, tempo (BPM), transposition and magnetic grid (Signalsmith engine).\n\nSelect an audio file in the Finder to load it automatically.\n\nby blckdvc\n\nFree & open-source — if you feel like it, buy me a few tokens:",
            "Lecteur de boucles : forme d'onde, boucle A/B, tempo (BPM), transposition et grille magnétique (moteur Signalsmith).\n\nSélectionne un fichier audio dans le Finder pour le charger automatiquement.\n\npar blckdvc\n\nLibre et open-source — si le cœur t'en dit, offre-moi quelques tokens :")
        // Badge « buy me tokens » cliquable → PayPal
        if let img = NSImage(named: "buy-me-tokens") {
            let maxW: CGFloat = 300
            let s = min(1, maxW / max(img.size.width, 1))
            let btn = NSButton(frame: NSRect(x: 0, y: 0, width: img.size.width * s, height: img.size.height * s))
            btn.image = img
            btn.imageScaling = .scaleProportionallyUpOrDown
            btn.imagePosition = .imageOnly
            btn.isBordered = false
            btn.target = self; btn.action = #selector(openDonate)
            btn.toolTip = "paypal.me/lbenh"
            a.accessoryView = btn
        }
        a.runModal()
    }
    @objc private func openDonate() {
        if let url = URL(string: "https://paypal.me/lbenh") { NSWorkspace.shared.open(url) }
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
            w.title = "audiolook"
            w.isMovableByWindowBackground = true        // on déplace par le fond (la forme d'onde ne bouge pas la fenêtre)
            w.setContentSize(NSSize(width: 600, height: 470))   // taille par défaut (disposition 2 colonnes)
            w.contentMinSize = NSSize(width: 560, height: 380)
            w.center()
            // Mémorise taille + position d'un lancement à l'autre et restaure le dernier cadre.
            if !w.setFrameUsingName("audiolookMain") { w.center() }
            w.setFrameAutosaveName("audiolookMain")
            // Si le cadre restauré est hors des écrans connectés (ex. ancien 2e écran débranché),
            // on recentre pour ne pas ouvrir la fenêtre hors de vue.
            let visible = NSScreen.screens.contains { scr in
                let i = scr.visibleFrame.intersection(w.frame)
                return i.width > 120 && i.height > 120
            }
            if !visible { w.center() }
            w.level = .floating
            w.delegate = c                              // arrête la lecture à la fermeture (windowWillClose)
            let wc = NSWindowController(window: w)
            windowController = wc; vc = c; controller = wc
        }
        lastLoadedPath = url.path
        if follow {
            // le Finder garde le focus clavier (navigation aux flèches) ; le player
            // suit en arrière-plan. La barre d'espace agit après un clic dans le player.
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
            // recharge sur un nouveau fichier audio ; ne pas recharger pendant qu'on agit dans audiolook
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
