import Cocoa
import AVFoundation

final class PlayerViewController: NSViewController, NSWindowDelegate {
    private let waveform = WaveformView()
    private let titleLabel = NSTextField(labelWithString: "Aucun fichier")
    private let infoLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "0:00.0 / 0:00.0")
    private let playButton = NSButton()
    private let loopButton = NSButton()
    private let fullButton = NSButton()

    private let volSlider = NSSlider()
    private let pitchSlider = NSSlider()
    private let volValue = NSTextField()
    private let pitchValue = NSTextField()

    // Tempo (remplace la vitesse %)
    private let srcBPMField = NSTextField()      // BPM détecté / source (éditable)
    private let tgtSlider = NSSlider()           // BPM cible
    private let tgtField = NSTextField()
    private var sourceBPM: Double = 120
    private var targetBPM: Double = 120
    private var sourceDuration: Double = 0
    private var tempoInitialized = false

    // Grille
    private let gridToggle = NSButton(checkboxWithTitle: "Aimanter", target: nil, action: nil)
    private let gridPopup = NSPopUpButton()
    private let beatsField = NSTextField()

    // Déplacement de la boucle (curseur) : glisse toute la région A/B sans changer sa longueur
    private let loopPosSlider = NSSlider()
    private let loopPosField = NSTextField()

    // Opacité
    private let opSlider = NSSlider()
    private let opValue = NSTextField(labelWithString: "100 %")

    private let dragChip = SampleDragView()
    private let regionToggle = NSButton(checkboxWithTitle: "Région A/B", target: nil, action: nil)
    private let bypassToggle = NSButton(checkboxWithTitle: "Désactiver le traitement (pitch / tempo)", target: nil, action: nil)
    private let renderButton = NSButton()

    private let player = LoopPlayer()
    private let analyzer = WaveformAnalyzer()
    private var timer: Timer?
    private var reprocessTimer: Timer?
    private var currentURL: URL?
    private var siblings: [URL] = []
    private var index = 0

    private let gridDivs: [Double] = [0.25, 0.5, 1.0, 4.0]   // 1/16, 1/8, 1/4, mesure

    private func sym(_ n: String) -> NSImage { NSImage(systemSymbolName: n, accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 1, height: 1)) }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 560)); root.wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold); titleLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); infoLabel.textColor = .secondaryLabelColor
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium); timeLabel.textColor = .secondaryLabelColor

        configure(playButton, "play.fill", "Lecture / pause", #selector(togglePlay))
        configure(loopButton, "repeat", "Boucle", #selector(toggleLoop)); loopButton.setButtonType(.toggle); loopButton.state = .on
        fullButton.title = "Boucle entière"; fullButton.bezelStyle = .rounded; fullButton.controlSize = .small
        fullButton.target = self; fullButton.action = #selector(resetLoop); fullButton.font = .systemFont(ofSize: 11)

        waveform.onSeek = { [weak self] f in self?.player.seek(toGlobal: f); self?.refresh() }
        waveform.onLoopChange = { [weak self] a, b in self?.player.setLoopRegion(a: a, b: b); self?.refresh() }

        let header = NSStackView(views: [titleLabel, infoLabel]); header.orientation = .vertical; header.alignment = .leading; header.spacing = 2
        let transport = NSStackView(views: [playButton, loopButton, fullButton, NSView(), timeLabel]); transport.orientation = .horizontal; transport.spacing = 10

        volSlider.minValue = 0; volSlider.maxValue = 1; volSlider.doubleValue = 1; volSlider.target = self; volSlider.action = #selector(volChanged)
        pitchSlider.minValue = -24; pitchSlider.maxValue = 24; pitchSlider.doubleValue = 0; pitchSlider.target = self; pitchSlider.action = #selector(pitchChanged)
        pitchSlider.numberOfTickMarks = 49; pitchSlider.allowsTickMarkValuesOnly = true
        tgtSlider.minValue = 40; tgtSlider.maxValue = 220; tgtSlider.doubleValue = 120; tgtSlider.target = self; tgtSlider.action = #selector(tgtSliderChanged)
        for sl in [volSlider, pitchSlider, tgtSlider] {
            sl.controlSize = .small
            sl.setContentHuggingPriority(.required, for: .horizontal)
            sl.widthAnchor.constraint(equalToConstant: 150).isActive = true
        }

        volValue.target = self; volValue.action = #selector(volFieldEdited)
        pitchValue.target = self; pitchValue.action = #selector(pitchFieldEdited)
        srcBPMField.target = self; srcBPMField.action = #selector(srcBPMEdited)
        tgtField.target = self; tgtField.action = #selector(tgtFieldEdited)
        beatsField.target = self; beatsField.action = #selector(beatsEdited)
        for v in [volValue, pitchValue, srcBPMField, tgtField, beatsField] {
            v.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); v.alignment = .right
            v.isEditable = true; v.isBordered = true; v.bezelStyle = .roundedBezel; v.focusRingType = .none
            v.setContentHuggingPriority(.required, for: .horizontal)
        }
        for v in [volValue, pitchValue, tgtField] { v.widthAnchor.constraint(equalToConstant: 64).isActive = true }
        srcBPMField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        beatsField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let arrow = NSTextField(labelWithString: "→"); arrow.textColor = .secondaryLabelColor
        let tempoRow = NSStackView(views: [icon("metronome.fill"), label("BPM"), srcBPMField, arrow, tgtSlider, tgtField, resetBtn(#selector(resetTempo))])
        tempoRow.orientation = .horizontal; tempoRow.spacing = 8

        let controls = NSStackView(views: [
            rowFixed(icon("speaker.wave.2.fill"), volSlider, volValue, resetBtn(#selector(resetVol))),
            tempoRow,
            rowFixed(icon("tuningfork"), pitchSlider, pitchValue, resetBtn(#selector(resetPitch))),
        ]); controls.orientation = .vertical; controls.spacing = 8; controls.alignment = .leading

        // Grille
        gridToggle.target = self; gridToggle.action = #selector(gridChanged); gridToggle.font = .systemFont(ofSize: 11)
        gridPopup.addItems(withTitles: ["1/16", "1/8", "1/4", "Mesure"]); gridPopup.selectItem(at: 2)
        gridPopup.controlSize = .small; gridPopup.font = .systemFont(ofSize: 11); gridPopup.target = self; gridPopup.action = #selector(gridChanged)
        let beatsLabel = label("boucle ="); let beatsUnit = label("temps")
        let gridRow = NSStackView(views: [icon("grid"), gridToggle, gridPopup, NSView(), beatsLabel, beatsField, beatsUnit])
        gridRow.orientation = .horizontal; gridRow.spacing = 8

        // Déplacer la boucle : un curseur qui fait glisser A et B ensemble
        loopPosSlider.minValue = 0; loopPosSlider.maxValue = 1; loopPosSlider.doubleValue = 0
        loopPosSlider.controlSize = .small; loopPosSlider.target = self; loopPosSlider.action = #selector(loopPosChanged)
        loopPosSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        loopPosField.target = self; loopPosField.action = #selector(loopPosFieldEdited)
        loopPosField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); loopPosField.alignment = .right
        loopPosField.isEditable = true; loopPosField.isBordered = true; loopPosField.bezelStyle = .roundedBezel; loopPosField.focusRingType = .none
        loopPosField.setContentHuggingPriority(.required, for: .horizontal)
        loopPosField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let loopRow = NSStackView(views: [icon("arrow.left.and.right"), label("Position"), loopPosSlider, loopPosField])
        loopRow.orientation = .horizontal; loopRow.spacing = 8

        dragChip.provideURL = { [weak self] in self?.exportURL() }
        dragChip.translatesAutoresizingMaskIntoConstraints = false
        regionToggle.font = .systemFont(ofSize: 11)
        renderButton.title = "Rendre…"; renderButton.image = sym("square.and.arrow.down"); renderButton.imagePosition = .imageLeading
        renderButton.bezelStyle = .rounded; renderButton.controlSize = .small; renderButton.target = self; renderButton.action = #selector(renderReveal)
        let actions = NSStackView(views: [dragChip, NSView(), regionToggle, renderButton])
        actions.orientation = .horizontal; actions.spacing = 10

        bypassToggle.target = self; bypassToggle.action = #selector(toggleBypass); bypassToggle.font = .systemFont(ofSize: 11)
        let bypassRow = NSStackView(views: [bypassToggle]); bypassRow.orientation = .horizontal

        // Opacité
        opSlider.minValue = 0.35; opSlider.maxValue = 1; opSlider.doubleValue = 1
        opSlider.controlSize = .small; opSlider.target = self; opSlider.action = #selector(opChanged)
        opSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        opValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); opValue.textColor = .secondaryLabelColor
        opValue.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let opRow = NSStackView(views: [icon("circle.lefthalf.filled"), opSlider, opValue]); opRow.orientation = .horizontal; opRow.spacing = 8

        let stack = NSStackView(views: [header, waveform, transport, controls, gridRow, loopRow, bypassRow, opRow, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        waveform.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            waveform.widthAnchor.constraint(equalTo: stack.widthAnchor),
            transport.widthAnchor.constraint(equalTo: stack.widthAnchor),
            gridRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            loopRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            waveform.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        waveform.setContentHuggingPriority(.defaultLow, for: .vertical)
        view = root
    }

    // Helpers UI
    private func icon(_ s: String) -> NSImageView {
        let v = NSImageView(image: sym(s)); v.contentTintColor = .secondaryLabelColor
        v.widthAnchor.constraint(equalToConstant: 16).isActive = true; return v
    }
    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor; return l
    }
    private func resetBtn(_ action: Selector) -> NSButton {
        let r = NSButton(title: "", image: sym("arrow.counterclockwise"), target: self, action: action)
        r.isBordered = false; r.imagePosition = .imageOnly; r.contentTintColor = .tertiaryLabelColor
        r.widthAnchor.constraint(equalToConstant: 20).isActive = true; return r
    }
    private func rowFixed(_ icon: NSView, _ slider: NSSlider, _ value: NSTextField, _ reset: NSButton) -> NSView {
        let st = NSStackView(views: [icon, slider, value, reset]); st.orientation = .horizontal; st.spacing = 8; return st
    }
    private func configure(_ b: NSButton, _ symbol: String, _ label: String, _ action: Selector) {
        b.bezelStyle = .regularSquare; b.isBordered = false; b.imagePosition = .imageOnly; b.image = sym(symbol)
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold); b.contentTintColor = .controlAccentColor
        b.target = self; b.action = action
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true; b.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    // MARK: Chargement
    func open(url: URL) {
        let exts: Set<String> = ["wav","aif","aiff","aifc","caf","mp3","m4a","aac","flac","ogg","opus"]
        let dir = url.deletingLastPathComponent()
        siblings = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } ?? [url]
        index = siblings.firstIndex(of: url) ?? 0
        load(siblings[index])
    }

    private func load(_ url: URL) {
        analyzer.cancel(); player.stop()
        waveform.peaks = []; waveform.rms = []; waveform.progress = 0; waveform.loopA = 0; waveform.loopB = 1
        currentURL = url
        titleLabel.stringValue = "Chargement…"; infoLabel.stringValue = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let src = SampleProcessor.read(url: url) else {
                DispatchQueue.main.async { self?.titleLabel.stringValue = "Lecture impossible" }; return
            }
            let bpm = BPMDetector.detect(src)
            DispatchQueue.main.async {
                guard let self else { return }
                self.sourceDuration = Double(src.frameCount) / src.sampleRate
                self.sourceBPM = bpm
                if !self.tempoInitialized { self.targetBPM = bpm; self.tempoInitialized = true }
                // applique les traitements courants AVANT le rendu
                self.player.bypass = (self.bypassToggle.state == .on)
                self.player.setRate(Float(self.rateFromBPM()))
                self.player.setTranspose(Float(self.pitchSlider.doubleValue.rounded()))
                self.player.load(source: src)
                self.player.volume = Float(self.volSlider.doubleValue)
                self.player.onReprocessed = { [weak self] in self?.refresh() }
                self.player.onStateChange = { [weak self] in self?.refresh() }
                self.titleLabel.stringValue = url.lastPathComponent
                self.infoLabel.stringValue = self.describe(url, src)
                self.analyzer.analyze(url: url) { [weak self] r in self?.waveform.peaks = r.peaks; self?.waveform.rms = r.rms }
                self.updateGrid(); self.startTimer(); self.refresh()
            }
        }
    }

    private func navigate(_ d: Int) { guard !siblings.isEmpty else { return }; index = (index + d + siblings.count) % siblings.count; load(siblings[index]) }
    func suspend() { player.pause(); refresh() }

    // MARK: Tempo
    private func rateFromBPM() -> Double {
        guard sourceBPM > 1 else { return 1 }
        return targetBPM / sourceBPM
    }
    private func applyTempo() {
        player.setRate(Float(rateFromBPM()))
        updateGrid(); updateValues(); scheduleReprocess()
    }
    @objc private func tgtSliderChanged() { targetBPM = tgtSlider.doubleValue.rounded(); applyTempo() }
    @objc private func tgtFieldEdited() {
        if let n = intIn(tgtField.stringValue) { targetBPM = Double(min(max(n, 40), 220)); tgtSlider.doubleValue = targetBPM; applyTempo() } else { updateValues() }
        focusWave()
    }
    @objc private func srcBPMEdited() {
        if let n = intIn(srcBPMField.stringValue), n > 20 { sourceBPM = Double(min(max(n, 30), 300)); applyTempo() } else { updateValues() }
        focusWave()
    }
    @objc private func beatsEdited() {
        if let n = intIn(beatsField.stringValue), n > 0, sourceDuration > 0 {
            sourceBPM = (Double(n) * 60.0 / sourceDuration).rounded()
            applyTempo()
        } else { updateValues() }
        focusWave()
    }
    @objc private func resetTempo() { targetBPM = sourceBPM; tgtSlider.doubleValue = targetBPM; applyTempo() }

    // MARK: Grille
    @objc private func gridChanged() { updateGrid() }
    private func updateGrid() {
        let i = max(0, min(gridPopup.indexOfSelectedItem, gridDivs.count - 1))
        let beatSec = sourceBPM > 1 ? 60.0 / sourceBPM : 0
        waveform.gridSpacing = sourceDuration > 0 ? (beatSec * gridDivs[i]) / sourceDuration : 0
        waveform.gridEnabled = gridToggle.state == .on
    }

    // MARK: Déplacement de la boucle (curseur)
    private func snapFrac(_ f: Double) -> Double {
        guard gridToggle.state == .on, waveform.gridSpacing > 0.0005 else { return f }
        let k = (f / waveform.gridSpacing).rounded()
        return min(max(k * waveform.gridSpacing, 0), 1)
    }
    /// Glisse la région A/B à une nouvelle position de départ, en conservant sa longueur.
    private func moveLoop(toStart s: Double) {
        let len = player.loopB - player.loopA
        var a = snapFrac(min(max(s, 0), max(0, 1 - len)))
        a = min(max(a, 0), max(0, 1 - len))
        let b = min(1, a + len)
        player.setLoopRegion(a: a, b: b)
        waveform.loopA = a; waveform.loopB = b
        refresh()
    }
    @objc private func loopPosChanged() { moveLoop(toStart: loopPosSlider.doubleValue) }
    @objc private func loopPosFieldEdited() {
        if let s = doubleIn(loopPosField.stringValue), player.duration > 0 { moveLoop(toStart: s / player.duration) }
        else { updateValues() }
        focusWave()
    }

    // MARK: Transport / divers
    @objc private func togglePlay() { player.togglePlay(); refresh() }
    @objc private func toggleLoop() { player.setLoop(loopButton.state == .on); refresh() }
    @objc private func resetLoop() { player.setLoopRegion(a: 0, b: 1); waveform.loopA = 0; waveform.loopB = 1; refresh() }
    @objc private func toggleBypass() {
        let on = bypassToggle.state == .on
        player.bypass = on
        for v in [srcBPMField, tgtField, beatsField] { v.isEnabled = !on }
        tgtSlider.isEnabled = !on; pitchSlider.isEnabled = !on; pitchValue.isEnabled = !on
        player.reprocess(); updateValues()
    }

    @objc private func volChanged() { player.volume = Float(volSlider.doubleValue); updateValues() }
    @objc private func pitchChanged() { player.setTranspose(Float(pitchSlider.doubleValue.rounded())); updateValues(); scheduleReprocess() }
    @objc private func resetVol() { volSlider.doubleValue = 1; volChanged() }
    @objc private func resetPitch() { pitchSlider.doubleValue = 0; pitchChanged() }

    private func intIn(_ s: String) -> Int? { Int(s.filter { "0123456789+-".contains($0) }) }
    private func doubleIn(_ s: String) -> Double? { Double(s.filter { "0123456789.,".contains($0) }.replacingOccurrences(of: ",", with: ".")) }
    private func focusWave() { view.window?.makeFirstResponder(waveform) }
    @objc private func volFieldEdited() {
        if let n = intIn(volValue.stringValue) { volSlider.doubleValue = min(max(Double(n)/100, 0), 1); volChanged() } else { updateValues() }; focusWave()
    }
    @objc private func pitchFieldEdited() {
        if let n = intIn(pitchValue.stringValue) { pitchSlider.doubleValue = Double(min(max(n, -24), 24)); pitchChanged() } else { updateValues() }; focusWave()
    }
    @objc private func opChanged() {
        let a = opSlider.doubleValue; view.window?.alphaValue = CGFloat(a); opValue.stringValue = "\(Int((a*100).rounded())) %"
    }

    private func scheduleReprocess() {
        reprocessTimer?.invalidate()
        reprocessTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in self?.player.reprocess() }
    }

    // Arrête la lecture quand on ferme la fenêtre (bouton rouge ou Échap).
    func windowWillClose(_ notification: Notification) { player.pause(); refresh() }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 49: togglePlay()
        case 123: navigate(-1)
        case 124: navigate(1)
        case 53: view.window?.close()
        default:
            if e.charactersIgnoringModifiers?.lowercased() == "l" { loopButton.state = loopButton.state == .on ? .off : .on; toggleLoop() }
            else { super.keyDown(with: e) }
        }
    }

    // MARK: Export / Logic
    private func exportURL() -> URL? {
        guard let buf = player.renderRegionForExport(regionOnly: regionToggle.state == .on),
              let base = currentURL?.deletingPathExtension().lastPathComponent else { return nil }
        var name = base
        if bypassToggle.state == .off {
            if Int(targetBPM) != Int(sourceBPM) { name += "_\(Int(targetBPM))bpm" }
            let st = Int(pitchSlider.doubleValue.rounded()); if st != 0 { name += String(format: "_%+dst", st) }
        }
        if regionToggle.state == .on { name += "_loop" }
        return LogicImporter.exportTemp(buf, name: name)
    }
    @objc private func renderReveal() {
        guard let url = exportURL() else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([url]); flash("Rendu : \(url.lastPathComponent)")
    }

    // MARK: UI refresh
    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0/30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    private func tick() { waveform.progress = player.progress; timeLabel.stringValue = timeText() }
    private func refresh() {
        waveform.progress = player.progress; waveform.loopA = player.loopA; waveform.loopB = player.loopB
        timeLabel.stringValue = timeText()
        playButton.image = sym(player.isPlaying ? "pause.fill" : "play.fill")
        loopButton.contentTintColor = player.loopEnabled ? .controlAccentColor : .tertiaryLabelColor
        updateValues()
    }
    private var flashToken = 0
    private func flash(_ msg: String) {
        flashToken += 1; let t = flashToken
        let saved = currentURL.map { describe($0, player.source) } ?? ""
        infoLabel.stringValue = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, t == self.flashToken else { return }; self.infoLabel.stringValue = saved
        }
    }
    private func updateValues() {
        volValue.stringValue = "\(Int((volSlider.doubleValue*100).rounded())) %"
        let st = Int(pitchSlider.doubleValue.rounded()); pitchValue.stringValue = st > 0 ? "+\(st) st" : "\(st) st"
        srcBPMField.stringValue = "\(Int(sourceBPM))"
        tgtField.stringValue = "\(Int(targetBPM))"
        if sourceDuration > 0 { beatsField.stringValue = "\(Int((sourceBPM * sourceDuration / 60).rounded()))" }
        loopPosSlider.doubleValue = player.loopA
        loopPosField.stringValue = String(format: "%.2fs", player.loopA * player.duration)
    }
    private func timeText() -> String { "\(fmt(player.currentTime)) / \(fmt(player.regionDuration))" }
    private func fmt(_ t: TimeInterval) -> String { guard t.isFinite else { return "0:00.0" }; let d = Int((t*10).rounded(.down)); return String(format: "%d:%02d.%d", d/600, (d/10)%60, d%10) }
    private func describe(_ url: URL, _ src: AudioSource?) -> String {
        let r = (src?.sampleRate ?? 44100)/1000
        let rate = r == r.rounded() ? String(format: "%.0f kHz", r) : String(format: "%.1f kHz", r)
        let ch = (src?.channels ?? 2) == 1 ? "Mono" : "Stéréo"
        var parts = [url.pathExtension.uppercased(), rate, ch, fmt(player.duration), "≈\(Int(sourceBPM)) BPM"]
        if siblings.count > 1 { parts.append("\(index+1)/\(siblings.count)") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    deinit { timer?.invalidate(); reprocessTimer?.invalidate(); analyzer.cancel(); player.stop() }
}
