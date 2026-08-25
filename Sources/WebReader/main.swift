import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Regular activation policy even when run outside a bundle (`swift run WebReader`), so the
// window and menu bar appear.
app.setActivationPolicy(.regular)
app.run()
