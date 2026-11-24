import AppKit

@MainActor
final class ForegroundFixtureDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let window = NSWindow(
      contentRect: NSRect(x: 150, y: 150, width: 500, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "MattePulp synthetic foreground fixture"
    window.backgroundColor = .white
    window.makeKeyAndOrderFront(nil)
    self.window = window
    NSApp.activate(ignoringOtherApps: true)
    // A failed parent test cannot leave this task-owned fixture running indefinitely.
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { NSApp.terminate(nil) }
  }
}

@main
struct ForegroundFixture {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = ForegroundFixtureDelegate()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
  }
}
