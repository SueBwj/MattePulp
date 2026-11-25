import AppKit

/// One-time first-launch language entry. Presented by the controller only when no
/// settings file existed at launch, a determinable new-install boundary: follow system,
/// Simplified Chinese and English are three native radio choices, the window
/// re-localizes as the selection changes, confirming persists the choice immediately
/// (follow system persists settings without a language key, so the entry never returns),
/// and canceling or closing writes nothing. The menu bar language submenu stays the
/// in-app way to switch later.
@MainActor
final class LanguagePickerWindow: NSWindowController, NSWindowDelegate {
  /// Interface language the app would use with no saved choice (the system language).
  private let systemLanguage: AppLanguage
  /// Language the entry currently displays; follows the radio selection.
  private var display: AppLanguage
  private let intro = NSTextField(wrappingLabelWithString: "")
  private let followSystem = NSButton()
  private let simplifiedChinese = NSButton()
  private let english = NSButton()
  private let note = NSTextField(wrappingLabelWithString: "")
  private let message = NSTextField(wrappingLabelWithString: "")
  private let ok = NSButton()
  private let cancel = NSButton()
  private var stack: NSStackView!
  /// Persists the selection; nil means follow system. Returns false to keep the window
  /// open with an inline retry message.
  var onChoose: ((AppLanguage?) -> Bool)?
  /// Notified once when the window closes for any reason.
  var onClose: (() -> Void)?

  init(following systemLanguage: AppLanguage) {
    self.systemLanguage = systemLanguage
    display = systemLanguage
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    for (button, label) in [
      (followSystem, "跟随系统"), (simplifiedChinese, "简体中文"), (english, "English"),
    ] {
      button.setButtonType(.radio)
      button.title = label
      button.target = self
      button.action = #selector(pick(_:))
    }
    followSystem.state = .on
    note.textColor = .secondaryLabelColor
    message.textColor = .systemRed
    cancel.keyEquivalent = "\u{1b}"
    cancel.target = self
    cancel.action = #selector(cancelSelection)
    // Return makes OK the window's default button. AppKit keeps the "\r" equivalent only
    // while the window is key and otherwise routes Return through defaultButtonCell.
    ok.keyEquivalent = "\r"
    ok.target = self
    ok.action = #selector(confirm)
    refreshText()
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let buttons = NSStackView(views: [spacer, cancel, ok])
    buttons.spacing = 8
    let stack = NSStackView(views: [
      intro, followSystem, simplifiedChinese, english, note, message, buttons,
    ])
    self.stack = stack
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.setCustomSpacing(14, after: english)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let content = window.contentView!
    content.addSubview(stack)
    // The bottom pin yields to the content size so intermediate states never stretch
    // the stack; settle() sizes the window to the exact natural height instead.
    let bottom = stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
    bottom.priority = .defaultLow
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
      bottom,
      buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
      note.widthAnchor.constraint(equalTo: stack.widthAnchor),
      intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
      message.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    settle()
    window.initialFirstResponder = followSystem
  }

  required init?(coder: NSCoder) { nil }

  private func localized(_ zh: String, _ en: String) -> String { display == .zhHans ? zh : en }

  private var titleText: String { localized("选择语言", "Choose Language") }

  /// The selected choice; nil means follow system.
  var selection: AppLanguage? {
    if simplifiedChinese.state == .on { return .zhHans }
    if english.state == .on { return .en }
    return nil
  }

  private func refreshText() {
    window?.title = titleText
    intro.stringValue = localized(
      "首次启动：选择柔纸的界面语言。", "First launch: choose the interface language for MattePulp.")
    followSystem.title = localized("跟随系统", "Follow system")
    note.stringValue = localized(
      "以后可随时在菜单栏「语言」菜单中更改。", "Change it anytime from the Language menu in the menu bar.")
    ok.title = localized("确定", "OK")
    cancel.title = localized("取消", "Cancel")
  }

  /// Lays out the entry, then sizes the window to the natural content height. Laying out
  /// first lets the wrapping labels wrap, so the measured height is exact for either
  /// language and for the inline retry message.
  private func settle() {
    window?.contentView?.layoutSubtreeIfNeeded()
    fit()
    window?.contentView?.layoutSubtreeIfNeeded()
  }

  private func fit() {
    if let window {
      window.setContentSize(NSSize(width: 360, height: stack.fittingSize.height + 34))
    }
  }

  @objc private func pick(_ sender: NSButton) {
    for button in [followSystem, simplifiedChinese, english] {
      button.state = button === sender ? .on : .off
    }
    display =
      sender === simplifiedChinese
      ? .zhHans : (sender === english ? .en : systemLanguage)
    refreshText()
    settle()
  }

  @objc private func confirm() {
    if let onChoose, !onChoose(selection) {
      message.stringValue = localized("保存失败。请重试。", "Could not save. Try again.")
      settle()
      return
    }
    close()
  }

  @objc private func cancelSelection() { close() }

  func windowWillClose(_ notification: Notification) { onClose?() }
}
