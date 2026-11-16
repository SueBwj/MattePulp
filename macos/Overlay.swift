import AppKit

struct Texture: Decodable {
  let id: String
  let name: String
}

struct TextureStore {
  let directory: URL
  let catalog: [Texture]

  init(directory: URL) throws {
    self.directory = directory
    catalog = try JSONDecoder().decode(
      [Texture].self,
      from: Data(contentsOf: directory.appendingPathComponent("catalog.json")))
    guard catalog.map(\.id) == Settings.textures else {
      throw NSError(
        domain: "SuePaper", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Invalid texture catalog"])
    }
  }

  func image(texture: String, intensity: Int) throws -> CGImage {
    guard Settings.textures.contains(texture), Settings.intensities.contains(intensity) else {
      throw NSError(domain: "SuePaper", code: 2)
    }
    let data = try Data(
      contentsOf: directory.appendingPathComponent("\(texture)-\(intensity).bgra"))
    guard data.count == 512 * 512 * 4,
      let provider = CGDataProvider(data: data as CFData),
      let image = CGImage(
        width: 512, height: 512, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: 512 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
          .union(.byteOrder32Little),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else {
      throw NSError(
        domain: "SuePaper", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Invalid texture pixels"])
    }
    return image
  }
}

@MainActor
final class TextureView: NSView {
  var image: CGImage { didSet { needsDisplay = true } }

  init(frame: NSRect, image: CGImage) {
    self.image = image
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
  override var isOpaque: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func viewDidChangeBackingProperties() { needsDisplay = true }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let scale = convertToBacking(NSRect(x: 0, y: 0, width: 1, height: 1)).width
    Self.draw(image, in: context, bounds: bounds, scale: scale)
  }

  static func draw(_ image: CGImage, in context: CGContext, bounds: CGRect, scale: CGFloat) {
    context.saveGState()
    context.clear(bounds)
    context.interpolationQuality = .none
    // A source pixel stays one backing pixel on Retina and mixed-DPI displays.
    let side = CGFloat(image.width) / max(scale, 1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side), byTiling: true)
    context.restoreGState()
  }
}

@MainActor
final class Overlay: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(screen: NSScreen, image: CGImage) {
    super.init(
      contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    isFloatingPanel = true
    isExcludedFromWindowsMenu = true
    animationBehavior = .none
    level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    if #available(macOS 13.0, *) { collectionBehavior.insert(.canJoinAllApplications) }
    contentView = TextureView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image)
    setFrame(screen.frame, display: false)
  }
}
