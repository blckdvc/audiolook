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
