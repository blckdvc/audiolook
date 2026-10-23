import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // agent : vit dans la barre de menus, pas dans le Dock
app.run()
