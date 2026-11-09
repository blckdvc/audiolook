import Cocoa

/// Mise à jour automatique à partir des GitHub Releases de blckdvc/audiolook.
///
/// - Vérifie `releases/latest` au lancement puis une fois par 24 h (désactivable).
/// - Télécharge le DMG de la release, vérifie l'empreinte SHA-256 si un fichier
///   `audiolook.dmg.sha256` est publié, monte le DMG, contrôle l'app (même identifiant,
///   version plus récente, signature intacte), puis remplace le bundle et relance.
/// - Pas de Sparkle : l'app est compilée avec swiftc et signée ad hoc.
@MainActor
final class Updater {
    static let shared = Updater()

    struct Release {
        let version: String
        let notes: String
        let pageURL: URL?
        let dmgURL: URL
        let sha256URL: URL?
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    private let repo = "blckdvc/audiolook"
    private let defaults = UserDefaults.standard
    private let autoKey = "autoCheckUpdates"
    private let lastCheckKey = "lastUpdateCheck"
    private let skipKey = "skippedUpdateVersion"
    private let interval: TimeInterval = 24 * 3600

    private var timer: Timer?
    private var checking = false
    private var busy = false                 // téléchargement / installation en cours
    private var progressPanel: NSPanel?
    private var progressBar: NSProgressIndicator?
    private var progressLabel: NSTextField?
    private var progressObservation: NSKeyValueObservation?

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    private var userAgent: String { "audiolook/\(currentVersion) (+https://github.com/\(repo))" }

    /// Vérification automatique (activée par défaut).
    var automaticChecks: Bool {
        get { defaults.object(forKey: autoKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: autoKey); schedule() }
    }

    func start() {
        schedule()
        // première vérification peu après le lancement (sans gêner le démarrage)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkIfDue() }
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard automaticChecks else { return }
        // toutes les heures, on regarde si 24 h se sont écoulées depuis la dernière vérification
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkIfDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func checkIfDue() {
        guard automaticChecks else { return }
        let last = defaults.double(forKey: lastCheckKey)
        if Date().timeIntervalSince1970 - last >= interval { check(userInitiated: false) }
    }

    // MARK: Vérification

    func check(userInitiated: Bool) {
        guard !checking, !busy else {
            if userInitiated { NSSound.beep() }
            return
        }
        checking = true
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let errText = err?.localizedDescription
            DispatchQueue.main.async {
                self?.handle(data: status == 200 ? data : nil, status: status, error: errText, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handle(data: Data?, status: Int, error: String?, userInitiated: Bool) {
        checking = false
        guard let data, let rel = Updater.parse(data) else {
            if userInitiated {
                let detail = error ?? (status == 0
                    ? Lang.t("No answer from GitHub.", "Pas de réponse de GitHub.")
                    : Lang.t("GitHub answered with HTTP \(status).", "GitHub a répondu HTTP \(status)."))
                info(Lang.t("Couldn't check for updates", "Impossible de vérifier les mises à jour"),
                     detail + "\n\n" + Lang.t("Try again later.", "Réessaie plus tard."))
            }
            return
        }
        defaults.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        guard Updater.isNewer(rel.version, than: currentVersion) else {
            if userInitiated {
                info(Lang.t("You're up to date", "Tu es à jour"),
                     Lang.t("audiolook \(currentVersion) is the latest version.",
                            "audiolook \(currentVersion) est la dernière version."))
            }
            return
        }
        // une version « ignorée » n'est plus proposée automatiquement (mais reste visible via le menu)
        if !userInitiated && defaults.string(forKey: skipKey) == rel.version { return }
        offer(rel)
    }

    nonisolated static func parse(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        func name(_ a: [String: Any]) -> String { (a["name"] as? String ?? "").lowercased() }
        func link(_ a: [String: Any]) -> URL? { (a["browser_download_url"] as? String).flatMap { URL(string: $0) } }
        guard let dmgAsset = assets.first(where: { name($0) == "audiolook.dmg" })
                ?? assets.first(where: { name($0).hasSuffix(".dmg") }),
              let dmg = link(dmgAsset) else { return nil }
        let shaName = name(dmgAsset) + ".sha256"
        let sha = assets.first(where: { name($0) == shaName }).flatMap { link($0) }
        let version = (tag.hasPrefix("v") || tag.hasPrefix("V")) ? String(tag.dropFirst()) : tag
        return Release(version: version,
                       notes: obj["body"] as? String ?? "",
                       pageURL: (obj["html_url"] as? String).flatMap { URL(string: $0) },
                       dmgURL: dmg,
                       sha256URL: sha)
    }

    /// Compare deux versions « 1.2.10 » / « 1.3 » numériquement, composant par composant.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { !("0"..."9").contains($0) }).map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: Proposition

    private func offer(_ rel: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = Lang.t("audiolook \(rel.version) is available", "audiolook \(rel.version) est disponible")
        a.informativeText = Lang.t("You have version \(currentVersion). Install it now? audiolook will relaunch.",
                                   "Tu as la version \(currentVersion). L'installer maintenant ? audiolook va se relancer.")
        let notes = rel.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { a.accessoryView = notesView(notes) }
        a.addButton(withTitle: Lang.t("Install and Relaunch", "Installer et relancer"))
        a.addButton(withTitle: Lang.t("Later", "Plus tard"))
        a.addButton(withTitle: Lang.t("Skip This Version", "Ignorer cette version"))
        switch a.runModal() {
        case .alertFirstButtonReturn: download(rel)
        case .alertThirdButtonReturn: defaults.set(rel.version, forKey: skipKey)
        default: break
        }
    }

    /// Notes de version dans une petite zone défilante (le texte peut être long).
    private func notesView(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 160))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.autoresizingMask = [.width]
        tv.string = text
        scroll.documentView = tv
        return scroll
    }

    // MARK: Téléchargement

    private var installURL: URL { Bundle.main.bundleURL }

    /// L'app peut-elle se remplacer elle-même ? (pas depuis le DMG, ni « translocalisée », dossier inscriptible)
    private func canReplaceInPlace() -> Bool {
        let p = installURL.path
        if p.contains("/AppTranslocation/") || p.hasPrefix("/Volumes/") { return false }
        return FileManager.default.isWritableFile(atPath: installURL.deletingLastPathComponent().path)
    }

    private func download(_ rel: Release) {
        guard canReplaceInPlace() else { manualFallback(rel); return }
        busy = true
        showProgress(Lang.t("Downloading audiolook \(rel.version)…", "Téléchargement d'audiolook \(rel.version)…"))
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiolook-update-\(UUID().uuidString)", isDirectory: true)
        var req = URLRequest(url: rel.dmgURL)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 60
        let task = URLSession.shared.downloadTask(with: req) { [weak self] tmp, resp, err in
            // le fichier temporaire disparaît au retour du handler : on le déplace tout de suite
            var dmg: URL?
            var problem = err?.localizedDescription
            if problem == nil, let tmp {
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    problem = "HTTP \(http.statusCode)"
                } else {
                    do {
                        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                        let dst = work.appendingPathComponent("audiolook.dmg")
                        try FileManager.default.moveItem(at: tmp, to: dst)
                        dmg = dst
                    } catch { problem = error.localizedDescription }
                }
            }
            let result = dmg, message = problem
            DispatchQueue.main.async {
                guard let self else { return }
                self.progressObservation = nil
                if let result { self.install(rel, dmg: result, work: work) }
                else {
                    try? FileManager.default.removeItem(at: work)
                    self.fail(message ?? Lang.t("Download failed.", "Le téléchargement a échoué."))
                }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            DispatchQueue.main.async {
                guard let bar = self?.progressBar else { return }
                bar.isIndeterminate = false
                bar.doubleValue = f
            }
        }
        task.resume()
    }

    // MARK: Installation

    private func install(_ rel: Release, dmg: URL, work: URL) {
        progressLabel?.stringValue = Lang.t("Verifying and installing…", "Vérification et installation…")
        progressBar?.isIndeterminate = true
        progressBar?.startAnimation(nil)
        let current = currentVersion
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Updater.stage(rel, dmg: dmg, work: work, currentVersion: current, bundleID: bundleID) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let app):
                    self.relaunch(with: app, work: work)
                case .failure(let e):
                    try? FileManager.default.removeItem(at: work)
                    self.fail(e.localizedDescription)
                }
            }
        }
    }

    /// Vérifie le DMG, en extrait l'app dans `work` et la contrôle. Hors thread principal.
    nonisolated private static func stage(_ rel: Release, dmg: URL, work: URL,
                                          currentVersion: String, bundleID: String) throws -> URL {
        // 1) Empreinte SHA-256, si la release la publie
        if let shaURL = rel.sha256URL {
            let txt = String(decoding: try Data(contentsOf: shaURL), as: UTF8.self)
            guard let expected = txt.split(whereSeparator: { $0 == " " || $0.isNewline }).first
                    .map({ String($0).lowercased() }), expected.count == 64 else {
                throw UpdateError(Lang.t("The checksum file is unreadable.", "Le fichier d'empreinte est illisible."))
            }
            let out = try run("/usr/bin/shasum", ["-a", "256", dmg.path])
            let actual = out.split(separator: " ").first.map { String($0).lowercased() }
            guard actual == expected else {
                throw UpdateError(Lang.t("The download is corrupted (SHA-256 mismatch).",
                                         "Le téléchargement est corrompu (empreinte SHA-256 différente)."))
            }
        }

        // 2) Monte le DMG en lecture seule, sans l'afficher dans le Finder, et copie l'app
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let appName = try FileManager.default.contentsOfDirectory(atPath: mount.path)
                .first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError(Lang.t("No app found in the downloaded disk image.", "Aucune app trouvée dans l'image disque téléchargée."))
        }
        let staged = work.appendingPathComponent("audiolook.app", isDirectory: true)
        try run("/usr/bin/ditto", [mount.appendingPathComponent(appName).path, staged.path])

        // 3) Contrôles : même app, version plus récente, signature intacte
        guard let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")),
              (info["CFBundleIdentifier"] as? String) == bundleID else {
            throw UpdateError(Lang.t("The downloaded app isn't audiolook.", "L'app téléchargée n'est pas audiolook."))
        }
        let newVersion = info["CFBundleShortVersionString"] as? String ?? ""
        guard isNewer(newVersion, than: currentVersion) else {
            throw UpdateError(Lang.t("The downloaded app (\(newVersion)) isn't newer than this one.",
                                     "L'app téléchargée (\(newVersion)) n'est pas plus récente que celle-ci."))
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        try? run("/usr/bin/xattr", ["-cr", staged.path])
        return staged
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            let tail = out.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError("\((tool as NSString).lastPathComponent): \(tail.isEmpty ? "exit \(p.terminationStatus)" : tail)")
        }
        return out
    }

    /// Lance un petit script détaché qui attend la fermeture d'audiolook, remplace le bundle
    /// (avec retour arrière en cas d'échec) et relance la nouvelle version.
    private func relaunch(with app: URL, work: URL) {
        let script = """
        #!/bin/bash
        PID="$1"; NEW="$2"; DEST="$3"; WORK="$4"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
        BAK="$DEST.update-old"
        rm -rf "$BAK"
        if ! mv "$DEST" "$BAK"; then open "$DEST"; rm -rf "$WORK"; exit 1; fi
        if ditto "$NEW" "$DEST"; then
          rm -rf "$BAK"
        else
          rm -rf "$DEST"; mv "$BAK" "$DEST"
        fi
        xattr -cr "$DEST" 2>/dev/null
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" 2>/dev/null
        open "$DEST"
        rm -rf "$WORK"
        """
        let scriptURL = work.appendingPathComponent("install.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [scriptURL.path,
                           String(ProcessInfo.processInfo.processIdentifier),
                           app.path, installURL.path, work.path]
            try p.run()
        } catch {
            try? FileManager.default.removeItem(at: work)
            fail(error.localizedDescription)
            return
        }
        hideProgress()
        NSApp.terminate(nil)
    }

    // MARK: Interface

    private func fail(_ message: String) {
        busy = false
        hideProgress()
        info(Lang.t("Update failed", "La mise à jour a échoué"), message)
    }

    private func manualFallback(_ rel: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = Lang.t("Can't update automatically", "Mise à jour automatique impossible")
        a.informativeText = Lang.t(
            "audiolook can't replace itself where it is (move it to your Applications folder first). You can download the new version manually.",
            "audiolook ne peut pas se remplacer là où il est (déplace-le d'abord dans le dossier Applications). Tu peux télécharger la nouvelle version manuellement.")
        a.addButton(withTitle: Lang.t("Open Download Page", "Ouvrir la page de téléchargement"))
        a.addButton(withTitle: Lang.t("Cancel", "Annuler"))
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(rel.pageURL ?? rel.dmgURL) }
    }

    private func info(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private func showProgress(_ text: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "audiolook"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 20, y: 52, width: 320, height: 20)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 22, width: 320, height: 20))
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(bar)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        progressPanel = panel; progressBar = bar; progressLabel = label
    }

    private func hideProgress() {
        progressPanel?.orderOut(nil)
        progressPanel = nil; progressBar = nil; progressLabel = nil
    }
}
