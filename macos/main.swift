import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var controller: AppController?
  var smokeTest = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      let directory: URL
      if arguments.count == 2, arguments[0] == "--smoke-test" {
        smokeTest = true
        directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
      } else if arguments.isEmpty {
        directory = try FileManager.default.url(
          for: .applicationSupportDirectory,
          in: .userDomainMask, appropriateFor: nil, create: true
        )
        .appendingPathComponent("Sue-Paper", isDirectory: true)
      } else {
        fputs("Usage: MattePulp (Sue-Paper) [--smoke-test TEMPORARY_SETTINGS_DIRECTORY]\n", stderr)
        exit(2)
      }
      guard let resources = Bundle.main.resourceURL else { exit(1) }
      let controller = try AppController(settingsDirectory: directory, resources: resources)
      self.controller = controller
      try controller.start()
      if smokeTest {
        guard !controller.overlays.isEmpty, controller.statusItem?.button != nil else { exit(1) }
        print("SMOKE: native menu bar and \(controller.overlays.count) display overlay(s) started")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { controller.quit() }
      }
    } catch StartupError.alreadyRunning {
      NSApp.terminate(nil)
    } catch {
      controller?.shutdown()
      fputs(
        "MattePulp could not start (\((error as NSError).code)). Check app resources and settings storage.\n",
        stderr)
      exit(1)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    controller?.shutdown()
    if smokeTest { print("SMOKE: overlays, menu bar item, observers, timer and lock released") }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
