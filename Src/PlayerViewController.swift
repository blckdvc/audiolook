import Cocoa
import AVFoundation

final class PlayerViewController: NSViewController {
    private let waveform = WaveformView()
    private let titleLabel = NSTextField(labelWithString: "Aucun fichier")
    private let infoLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "0:00.0 / 0:00.0")
    private let playButton = NSButton()
    private let loopButton = NSButton()
    private let fullButton = NSButton()

    private let volSlider = NSSlider(), stretchSlider = NSSlider(), pitchSlider = NSSlider()
    private let volValue = NSTextField()
    private let stretchValue = NSTextField()
    private let pitchValue = NSTextField()
    private let opSlider = NSSlider()
    private let opValue = NSTextField(labelWithString: "100 %")

    private let dragChip = SampleDragView()
    private let regionToggle = NSButton(checkboxWithTitle: "Région A/B", target: nil, action: nil)
    private let bypassToggle = NSButton(checkboxWithTitle: "Désactiver le traitement (pitch / vitesse)", target: nil, action: nil)
    private let renderButton = NSButton()
    private let logicButton = NSButton()

    private let player = LoopPlayer()
    private let analyzer = WaveformAnalyzer()
    private var timer: Timer?
    private var reprocessTimer: Timer?
    private var currentURL: URL?
    private var siblings: [URL] = []
    private var index = 0

    private func sym(_ n: String) -> NSImage { NSImage(systemSymbolName: n, accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 1, height: 1)) }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 520)); root.wantsLayer = true
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
        stretchSlider.minValue = 0.5; stretchSlider.maxValue = 2.0; stretchSlider.doubleValue = 1.0; stretchSlider.target = self; stretchSlider.action = #selector(stretchChanged)
        pitchSlider.minValue = -24; pitchSlider.maxValue = 24; pitchSlider.doubleValue = 0; pitchSlider.target = self; pitchSlider.action = #selector(pitchChanged)
        pitchSlider.numberOfTickMarks = 49; pitchSlider.allowsTickMarkValuesOnly = true
        for sl in [volSlider, stretchSlider, pitchSlider] {
            sl.controlSize = .small
            sl.setContentHuggingPriority(.required, for: .horizontal)
            sl.widthAnchor.constraint(equalToConstant: 170).isActive = true
        }
        volValue.target = self; volValue.action = #selector(volFieldEdited)
        stretchValue.target = self; stretchValue.action = #selector(stretchFieldEdited)
        pitchValue.target = self; pitchValue.action = #selector(pitchFieldEdited)
        for v in [volValue, stretchValue, pitchValue] {
            v.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); v.alignment = .right
            v.isEditable = true; v.isBordered = true; v.bezelStyle = .roundedBezel; v.focusRingType = .none
            v.setContentHuggingPriority(.required, for: .horizontal); v.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        let controls = NSStackView(views: [
            row("Volume", "speaker.wave.2.fill", volSlider, volValue, #selector(resetVol)),
            row("Vitesse", "metronome.fill", stretchSlider, stretchValue, #selector(resetStretch)),
            row("Transposition", "tuningfork", pitchSlider, pitchValue, #selector(resetPitch)),
        ]); controls.orientation = .vertical; controls.spacing = 8; controls.alignment = .leading

        // Opacité de la fenêtre
        opSlider.minValue = 0.35; opSlider.maxValue = 1; opSlider.doubleValue = 1
        opSlider.controlSize = .small; opSlider.target = self; opSlider.action = #selector(opChanged)
        opSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        opValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); opValue.textColor = .secondaryLabelColor
        opValue.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let opIcon = NSImageView(image: sym("circle.lefthalf.filled")); opIcon.contentTintColor = .secondaryLabelColor
        opIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let opRow = NSStackView(views: [opIcon, opSlider, opValue]); opRow.orientation = .horizontal; opRow.spacing = 8

        dragChip.provideURL = { [weak self] in self?.exportURL() }
        dragChip.translatesAutoresizingMaskIntoConstraints = false
        regionToggle.target = self; regionToggle.action = #selector(noop); regionToggle.font = .systemFont(ofSize: 11)
        renderButton.title = "Rendre…"; renderButton.image = sym("square.and.arrow.down"); renderButton.imagePosition = .imageLeading
        renderButton.bezelStyle = .rounded; renderButton.controlSize = .small; renderButton.target = self; renderButton.action = #selector(renderReveal)
        logicButton.title = "Importer dans Logic"; logicButton.image = sym("music.note"); logicButton.imagePosition = .imageLeading
        logicButton.bezelStyle = .rounded; logicButton.controlSize = .small; logicButton.target = self; logicButton.action = #selector(importLogic)

        let actions = NSStackView(views: [dragChip, NSView(), regionToggle, renderButton, logicButton])
        actions.orientation = .horizontal; actions.spacing = 10

        bypassToggle.target = self; bypassToggle.action = #selector(toggleBypass); bypassToggle.font = .systemFont(ofSize: 11)
        let bypassRow = NSStackView(views: [bypassToggle]); bypassRow.orientation = .horizontal

        let stack = NSStackView(views: [header, waveform, transport, controls, bypassRow, opRow, actions])
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
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bypassRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            waveform.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        waveform.setContentHuggingPriority(.defaultLow, for: .vertical)
        view = root
    }

    private func row(_ name: String, _ symbol: String, _ slider: NSSlider, _ value: NSTextField, _ reset: Selector) -> NSView {
        let icon = NSImageView(image: sym(symbol)); icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let r = NSButton(title: "", image: sym("arrow.counterclockwise"), target: self, action: reset)
        r.isBordered = false; r.imagePosition = .imageOnly; r.contentTintColor = .tertiaryLabelColor
        r.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let st = NSStackView(views: [icon, slider, value, r]); st.orientation = .horizontal; st.spacing = 8
        return st
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
            DispatchQueue.main.async {
                guard let self else { return }
                self.player.load(source: src)
                self.player.volume = 1
                self.player.onReprocessed = { [weak self] in self?.refresh() }
                self.player.onStateChange = { [weak self] in self?.refresh() }
                self.titleLabel.stringValue = url.lastPathComponent
                self.infoLabel.stringValue = self.describe(url, src)
                self.analyzer.analyze(url: url) { [weak self] r in self?.waveform.peaks = r.peaks; self?.waveform.rms = r.rms }
                self.startTimer(); self.refresh()
            }
        }
    }

    private func navigate(_ d: Int) { guard !siblings.isEmpty else { return }; index = (index + d + siblings.count) % siblings.count; load(siblings[index]) }

    /// Arrête la lecture (utilisé par le suivi de sélection quand on quitte le fichier).
    func suspend() { player.pause(); refresh() }

    // MARK: Actions transport
    @objc private func togglePlay() { player.togglePlay(); refresh() }
    @objc private func toggleLoop() { player.setLoop(loopButton.state == .on); refresh() }
    @objc private func resetLoop() { player.setLoopRegion(a: 0, b: 1); waveform.loopA = 0; waveform.loopB = 1; refresh() }
    @objc private func noop() {}
    @objc private func toggleBypass() {
        let on = bypassToggle.state == .on
        player.bypass = on
        stretchSlider.isEnabled = !on
        pitchSlider.isEnabled = !on
        player.reprocess()
        updateValues()
    }

    @objc private func volChanged() { player.volume = Float(volSlider.doubleValue); updateValues() }
    @objc private func stretchChanged() { player.setRate(Float(stretchSlider.doubleValue)); updateValues(); scheduleReprocess() }
    @objc private func pitchChanged() { player.setTranspose(Float(pitchSlider.doubleValue.rounded())); updateValues(); scheduleReprocess() }
    @objc private func resetVol() { volSlider.doubleValue = 1; volChanged() }
    @objc private func resetStretch() { stretchSlider.doubleValue = 1; stretchChanged() }
    @objc private func resetPitch() { pitchSlider.doubleValue = 0; pitchChanged() }

    private func intIn(_ s: String) -> Int? {
        let f = s.filter { "0123456789+-".contains($0) }
        return Int(f)
    }
    @objc private func volFieldEdited() {
        if let n = intIn(volValue.stringValue) { volSlider.doubleValue = min(max(Double(n)/100, 0), 1); volChanged() } else { updateValues() }
        view.window?.makeFirstResponder(waveform)
    }
    @objc private func stretchFieldEdited() {
        if let n = intIn(stretchValue.stringValue) { stretchSlider.doubleValue = min(max(Double(n)/100, 0.5), 2.0); stretchChanged() } else { updateValues() }
        view.window?.makeFirstResponder(waveform)
    }
    @objc private func pitchFieldEdited() {
        if let n = intIn(pitchValue.stringValue) { pitchSlider.doubleValue = Double(min(max(n, -24), 24)); pitchChanged() } else { updateValues() }
        view.window?.makeFirstResponder(waveform)
    }
    @objc private func opChanged() {
        let a = opSlider.doubleValue
        view.window?.alphaValue = CGFloat(a)
        opValue.stringValue = "\(Int((a*100).rounded())) %"
    }

    private func scheduleReprocess() {
        reprocessTimer?.invalidate()
        reprocessTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in self?.player.reprocess() }
    }

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
        let r = Int((stretchSlider.doubleValue * 100).rounded()), st = Int(pitchSlider.doubleValue.rounded())
        if r != 100 { name += "_\(r)pct" }
        if st != 0 { name += String(format: "_%+dst", st) }
        if regionToggle.state == .on { name += "_loop" }
        return LogicImporter.exportTemp(buf, name: name)
    }
    @objc private func renderReveal() {
        guard let url = exportURL() else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        flash("Rendu : \(url.lastPathComponent)")
    }
    @objc private func importLogic() {
        guard let url = exportURL() else { NSSound.beep(); return }
        let res = LogicImporter.importIntoLogic(url)
        flash(res.message)
        if !res.ok {
            let a = NSAlert(); a.messageText = "Import Logic"; a.informativeText = res.message + "\n\nTu peux aussi glisser la pastille directement dans Logic."; a.runModal()
        }
    }

    // MARK: UI
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
        stretchValue.stringValue = "\(Int((stretchSlider.doubleValue*100).rounded())) %"
        let st = Int(pitchSlider.doubleValue.rounded()); pitchValue.stringValue = st > 0 ? "+\(st) st" : "\(st) st"
    }
    private func timeText() -> String { "\(fmt(player.currentTime)) / \(fmt(player.regionDuration))" }
    private func fmt(_ t: TimeInterval) -> String { guard t.isFinite else { return "0:00.0" }; let d = Int((t*10).rounded(.down)); return String(format: "%d:%02d.%d", d/600, (d/10)%60, d%10) }
    private func describe(_ url: URL, _ src: AudioSource?) -> String {
        let r = (src?.sampleRate ?? 44100)/1000
        let rate = r == r.rounded() ? String(format: "%.0f kHz", r) : String(format: "%.1f kHz", r)
        let ch = (src?.channels ?? 2) == 1 ? "Mono" : "Stéréo"
        var parts = [url.pathExtension.uppercased(), rate, ch, fmt(player.duration)]
        if siblings.count > 1 { parts.append("\(index+1)/\(siblings.count)") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    deinit { timer?.invalidate(); reprocessTimer?.invalidate(); analyzer.cancel(); player.stop() }
}
