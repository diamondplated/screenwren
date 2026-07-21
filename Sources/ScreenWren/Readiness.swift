import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ServiceManagement

enum ScreenCapturePermissionPhase: Equatable {
    case allowed
    case needsPermission
    case openSettings
    case needsRelaunch
}

func screenCapturePermissionPhase(
    isAllowed: Bool,
    wasRequested: Bool,
    requestGranted: Bool
) -> ScreenCapturePermissionPhase {
    if isAllowed { return .allowed }
    if requestGranted { return .needsRelaunch }
    return wasRequested ? .openSettings : .needsPermission
}

enum ShortcutCommand: String, CaseIterable, Codable {
    case capture
    case copyText
    case repeatCapture
    case frontWindow
    case freeze

    var identifier: UInt32 {
        switch self {
        case .capture: 1
        case .copyText: 2
        case .repeatCapture: 3
        case .frontWindow: 4
        case .freeze: 5
        }
    }

    var title: String {
        switch self {
        case .capture: "Capture Region or Window"
        case .copyText: "Copy Text from Region"
        case .repeatCapture: "Repeat Last Capture"
        case .frontWindow: "Capture Front Window"
        case .freeze: "Freeze Screen & Select"
        }
    }

    var defaultShortcut: Shortcut? {
        switch self {
        case .capture:
            Shortcut(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(controlKey), keyEquivalent: "p", keyLabel: "P")
        case .copyText:
            Shortcut(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: UInt32(cmdKey | shiftKey | optionKey), keyEquivalent: "2", keyLabel: "2")
        case .repeatCapture:
            Shortcut(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: UInt32(cmdKey | shiftKey | controlKey), keyEquivalent: "2", keyLabel: "2")
        case .frontWindow, .freeze:
            nil
        }
    }
}

struct Shortcut: Codable, Equatable, Hashable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyEquivalent: String
    let keyLabel: String

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    var displayName: String {
        var result = ""
        let flags = modifierFlags
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + keyLabel
    }

    var hasRequiredModifier: Bool {
        !modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    static func from(event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

        guard let key = shortcutKey(for: event) else { return nil }
        return Shortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: carbon,
            keyEquivalent: key.equivalent,
            keyLabel: key.label
        )
    }
}

func conflictingShortcutCommands(
    _ values: [ShortcutCommand: Shortcut?]
) -> Set<ShortcutCommand> {
    var commandsByShortcut: [Shortcut: [ShortcutCommand]] = [:]
    for (command, optionalShortcut) in values {
        guard let shortcut = optionalShortcut else { continue }
        commandsByShortcut[shortcut, default: []].append(command)
    }
    return Set(commandsByShortcut.values.filter { $0.count > 1 }.flatMap { $0 })
}

private func shortcutKey(for event: NSEvent) -> (equivalent: String, label: String)? {
    switch Int(event.keyCode) {
    case kVK_Return: return ("\r", "↩")
    case kVK_Tab: return ("\t", "⇥")
    case kVK_Space: return (" ", "Space")
    case kVK_Delete: return nil
    case kVK_ForwardDelete: return nil
    case kVK_LeftArrow: return (String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), "←")
    case kVK_RightArrow: return (String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), "→")
    case kVK_UpArrow: return (String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), "↑")
    case kVK_DownArrow: return (String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), "↓")
    default:
        guard let characters = event.charactersIgnoringModifiers,
              let character = characters.first,
              !character.isWhitespace,
              !character.isNewline else { return nil }
        let equivalent = String(character).lowercased()
        return (equivalent, String(character).uppercased())
    }
}

final class ShortcutStore {
    private let defaults: UserDefaults
    private let prefix = "shortcuts.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func shortcut(for command: ShortcutCommand) -> Shortcut? {
        let key = prefix + command.rawValue
        guard defaults.object(forKey: key + ".configured") != nil else {
            return command.defaultShortcut
        }
        guard defaults.bool(forKey: key + ".enabled"),
              let data = defaults.data(forKey: key + ".value") else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    func set(_ shortcut: Shortcut?, for command: ShortcutCommand) {
        let key = prefix + command.rawValue
        defaults.set(true, forKey: key + ".configured")
        defaults.set(shortcut != nil, forKey: key + ".enabled")
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: key + ".value")
        } else {
            defaults.removeObject(forKey: key + ".value")
        }
    }

    func restoreDefaults() {
        for command in ShortcutCommand.allCases {
            let key = prefix + command.rawValue
            defaults.removeObject(forKey: key + ".configured")
            defaults.removeObject(forKey: key + ".enabled")
            defaults.removeObject(forKey: key + ".value")
        }
    }
}

@MainActor
final class ShortcutManager {
    typealias Action = @MainActor @Sendable () -> Void

    private let store: ShortcutStore
    private let actions: [ShortcutCommand: Action]
    private var registrations: [ShortcutCommand: HotKey] = [:]
    private(set) var failures: [ShortcutCommand: String] = [:]
    var onChange: (() -> Void)?

    init(store: ShortcutStore = ShortcutStore(), actions: [ShortcutCommand: Action]) {
        self.store = store
        self.actions = actions
    }

    func registerAll() {
        registrations.removeAll()
        failures.removeAll()
        let values = Dictionary(uniqueKeysWithValues: ShortcutCommand.allCases.map { ($0, store.shortcut(for: $0)) })
        let conflicts = conflictingShortcutCommands(values)

        for command in ShortcutCommand.allCases {
            guard let shortcut = values[command] ?? nil else { continue }
            guard !conflicts.contains(command) else {
                failures[command] = "Duplicates another ScreenWren shortcut"
                continue
            }
            guard let action = actions[command],
                  let registration = HotKey(
                    identifier: command.identifier,
                    keyCode: shortcut.keyCode,
                    modifiers: shortcut.carbonModifiers,
                    action: action
                  ) else {
                failures[command] = "Already used by macOS or another app"
                continue
            }
            registrations[command] = registration
        }
        onChange?()
    }

    func shortcut(for command: ShortcutCommand) -> Shortcut? {
        store.shortcut(for: command)
    }

    func update(_ command: ShortcutCommand, to shortcut: Shortcut?) -> String? {
        if let shortcut, !shortcut.hasRequiredModifier {
            return "Include Command, Control, or Option."
        }
        if let shortcut,
           ShortcutCommand.allCases.contains(where: { $0 != command && store.shortcut(for: $0) == shortcut }) {
            return "That shortcut is already assigned in ScreenWren."
        }

        let previousShortcut = store.shortcut(for: command)
        registrations[command] = nil

        if let shortcut {
            guard let action = actions[command],
                  let registration = HotKey(
                    identifier: command.identifier,
                    keyCode: shortcut.keyCode,
                    modifiers: shortcut.carbonModifiers,
                    action: action
                  ) else {
                if let previousShortcut, let action = actions[command],
                   let restored = HotKey(
                        identifier: command.identifier,
                        keyCode: previousShortcut.keyCode,
                        modifiers: previousShortcut.carbonModifiers,
                        action: action
                   ) {
                    registrations[command] = restored
                    failures.removeValue(forKey: command)
                    onChange?()
                    return "macOS or another app did not make that shortcut available. Your previous shortcut is still active."
                }
                failures[command] = "Configured shortcut is unavailable"
                onChange?()
                return "That shortcut is unavailable, and the previous shortcut could not be restored. Choose another shortcut."
            }
            registrations[command] = registration
        }

        store.set(shortcut, for: command)
        failures.removeValue(forKey: command)
        onChange?()
        return nil
    }

    func restoreDefaults() {
        store.restoreDefaults()
        registerAll()
    }
}

@MainActor
final class LaunchAtLoginController {
    private let service = SMAppService.loginItem(identifier: "io.github.diamondplated.ScreenWren.LoginItem")

    var isEnabled: Bool { service.status == .enabled }

    var statusText: String {
        switch service.status {
        case .enabled: "On"
        case .notRegistered: "Off"
        case .requiresApproval: "Needs approval in System Settings"
        case .notFound: "Off"
        @unknown default: "Unknown"
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}

@MainActor
final class ShortcutRecorderField: NSTextField {
    var shortcut: Shortcut? { didSet { updateText() } }
    var onRecord: ((Shortcut?) -> String?)?
    var onMessage: ((String) -> Void)?

    init(shortcut: Shortcut?) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = true
        drawsBackground = true
        alignment = .center
        font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        focusRingType = .exterior
        toolTip = "Click, then type a shortcut. Delete clears it; Escape cancels."
        setAccessibilityRole(.textField)
        updateText()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        stringValue = "Type shortcut…"
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { stringValue = "Type shortcut…" }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        updateText()
        return result
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            window?.makeFirstResponder(nil)
        case kVK_Delete, kVK_ForwardDelete:
            if let message = onRecord?(nil) {
                onMessage?(message)
            } else {
                shortcut = nil
                onMessage?("Shortcut cleared. The menu command still works.")
                window?.makeFirstResponder(nil)
            }
        default:
            guard let proposed = Shortcut.from(event: event), proposed.hasRequiredModifier else {
                NSSound.beep()
                onMessage?("Include Command, Control, or Option.")
                return
            }
            if let message = onRecord?(proposed) {
                NSSound.beep()
                onMessage?(message)
            } else {
                shortcut = proposed
                onMessage?("Shortcut updated to \(proposed.displayName).")
                window?.makeFirstResponder(nil)
            }
        }
    }

    private func updateText() {
        stringValue = shortcut?.displayName ?? "None"
        setAccessibilityValue(stringValue)
    }
}

@MainActor
final class ReadinessWindowController: NSWindowController, NSWindowDelegate {
    private let shortcutManager: ShortcutManager
    private let launchAtLogin: LaunchAtLoginController
    private let permissionStatus = NSTextField(labelWithString: "")
    private let permissionIcon = NSImageView()
    private let permissionButton = NSButton()
    private let shortcutSummary = NSTextField(labelWithString: "")
    private let launchSwitch = NSSwitch()
    private let launchStatus = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton()
    private let secondaryButton = NSButton()
    private var permissionWasRequested = false
    private var permissionRequestGranted = false
    private var dismissed = false

    var onTryCapture: (() -> Void)?
    var onDismiss: (() -> Void)?

    init(shortcutManager: ShortcutManager, launchAtLogin: LaunchAtLoginController) {
        self.shortcutManager = shortcutManager
        self.launchAtLogin = launchAtLogin
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 620, height: 690),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScreenWren Readiness"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = makeContentController()
        window.setContentSize(NSSize(width: 620, height: 690))
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        dismissed = false
        refresh()
        showWindow(nil)
        window?.center()
        NSApp.activate()
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        finishDismissal()
    }

    @objc private func requestOrOpenPermission() {
        switch permissionPhase {
        case .allowed, .openSettings:
            openScreenCaptureSettings()
        case .needsPermission:
            permissionWasRequested = true
            permissionRequestGranted = CGRequestScreenCaptureAccess()
            refresh()
        case .needsRelaunch:
            relaunch()
        }
    }

    @objc private func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try launchAtLogin.setEnabled(launchSwitch.state == .on)
            messageLabel.stringValue = launchAtLogin.isEnabled
                ? "ScreenWren will be ready after you sign in."
                : "Launch at login is off."
        } catch {
            NSSound.beep()
            messageLabel.stringValue = error.localizedDescription
        }
        refresh()
    }

    @objc private func restoreShortcuts() {
        shortcutManager.restoreDefaults()
        rebuildShortcutRows()
        refresh()
        messageLabel.stringValue = "Default shortcuts restored."
    }

    @objc private func dismissWindow() {
        window?.close()
    }

    @objc private func primaryAction() {
        switch permissionPhase {
        case .needsRelaunch:
            relaunch()
            return
        case .needsPermission, .openSettings:
            requestOrOpenPermission()
            return
        case .allowed:
            break
        }
        finishDismissal()
        window?.orderOut(nil)
        onTryCapture?()
    }

    private var permissionPhase: ScreenCapturePermissionPhase {
        screenCapturePermissionPhase(
            isAllowed: CGPreflightScreenCaptureAccess(),
            wasRequested: permissionWasRequested,
            requestGranted: permissionRequestGranted
        )
    }

    private func relaunch() {
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/ScreenWrenLoginItem.app/Contents/MacOS/ScreenWrenLoginItem")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            NSSound.beep()
            messageLabel.stringValue = "Quit and reopen ScreenWren to finish permission setup."
            return
        }
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = ["--relaunch", String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            NSSound.beep()
            messageLabel.stringValue = "Quit and reopen ScreenWren to finish permission setup."
        }
    }

    @objc private func refresh() {
        let phase = permissionPhase
        let allowed = phase == .allowed
        let symbol = allowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        permissionIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: allowed ? "Allowed" : "Required")
        permissionIcon.contentTintColor = allowed ? .systemGreen : .systemOrange
        permissionStatus.stringValue = switch phase {
        case .allowed: "Allowed"
        case .needsPermission: "Required for screenshots"
        case .openSettings: "Open System Settings to allow"
        case .needsRelaunch: "Relaunch required"
        }
        permissionStatus.textColor = allowed ? .systemGreen : .systemOrange
        permissionButton.title = switch phase {
        case .allowed: "Open Settings"
        case .needsPermission: "Allow Screen Capture"
        case .openSettings: "Open System Settings"
        case .needsRelaunch: "Quit & Reopen ScreenWren"
        }

        let active = ShortcutCommand.allCases.filter { shortcutManager.shortcut(for: $0) != nil }.count
        if shortcutManager.failures.isEmpty {
            shortcutSummary.stringValue = "\(active) of \(ShortcutCommand.allCases.count) shortcuts active"
            shortcutSummary.textColor = .secondaryLabelColor
        } else {
            shortcutSummary.stringValue = "\(shortcutManager.failures.count) shortcut\(shortcutManager.failures.count == 1 ? "" : "s") unavailable"
            shortcutSummary.textColor = .systemOrange
        }

        launchSwitch.state = launchAtLogin.isEnabled ? .on : .off
        launchStatus.stringValue = launchAtLogin.statusText
        primaryButton.title = switch phase {
        case .allowed: "Start Capture"
        case .needsPermission: "Allow Screen Capture"
        case .openSettings: "Open System Settings"
        case .needsRelaunch: "Quit & Reopen ScreenWren"
        }
        secondaryButton.title = allowed ? "Done" : "Not Now"
    }

    private func makeContentController() -> NSViewController {
        let controller = NSViewController()
        let content = NSView()
        controller.view = content

        let icon = NSImageView(image: NSImage(systemSymbolName: "viewfinder.circle.fill", accessibilityDescription: "ScreenWren") ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 38, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = label("Make ScreenWren ready", size: 26, weight: .bold)
        let subtitle = label(
            "ScreenWren needs one macOS permission. Global shortcuts are optional because the menu always works.",
            size: 13,
            color: .secondaryLabelColor
        )
        subtitle.maximumNumberOfLines = 2
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 5

        let hero = NSStackView(views: [icon, heading])
        hero.orientation = .horizontal
        hero.alignment = .centerY
        hero.spacing = 14
        icon.widthAnchor.constraint(equalToConstant: 46).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 46).isActive = true

        permissionIcon.translatesAutoresizingMaskIntoConstraints = false
        permissionIcon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        permissionIcon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        permissionStatus.font = .systemFont(ofSize: 12, weight: .semibold)
        let permissionTop = NSStackView(views: [permissionIcon, permissionStatus])
        permissionTop.orientation = .horizontal
        permissionTop.alignment = .centerY
        permissionTop.spacing = 7

        permissionButton.target = self
        permissionButton.action = #selector(requestOrOpenPermission)
        permissionButton.bezelStyle = .rounded
        let permissionBody = label(
            "macOS groups screen capture with system audio. ScreenWren captures still images only and does not record audio or video.",
            size: 12,
            color: .secondaryLabelColor
        )
        permissionBody.maximumNumberOfLines = 3
        let permissionTitle = label("Screen & System Audio Recording", size: 13, weight: .semibold)
        let permissionContent = NSView()
        [permissionTitle, permissionTop, permissionBody, permissionButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            permissionContent.addSubview($0)
        }
        NSLayoutConstraint.activate([
            permissionTitle.topAnchor.constraint(equalTo: permissionContent.topAnchor),
            permissionTitle.leadingAnchor.constraint(equalTo: permissionContent.leadingAnchor),
            permissionTop.centerYAnchor.constraint(equalTo: permissionTitle.centerYAnchor),
            permissionTop.leadingAnchor.constraint(equalTo: permissionTitle.trailingAnchor, constant: 10),
            permissionTop.trailingAnchor.constraint(lessThanOrEqualTo: permissionContent.trailingAnchor),
            permissionBody.topAnchor.constraint(equalTo: permissionTitle.bottomAnchor, constant: 9),
            permissionBody.leadingAnchor.constraint(equalTo: permissionContent.leadingAnchor),
            permissionBody.trailingAnchor.constraint(equalTo: permissionContent.trailingAnchor),
            permissionButton.topAnchor.constraint(equalTo: permissionBody.bottomAnchor, constant: 9),
            permissionButton.trailingAnchor.constraint(equalTo: permissionContent.trailingAnchor),
            permissionButton.bottomAnchor.constraint(equalTo: permissionContent.bottomAnchor),
        ])
        let permissionCard = card(permissionContent)

        let shortcutTitle = label("Keyboard Shortcuts", size: 13, weight: .semibold)
        let shortcutRows = NSStackView()
        shortcutRows.identifier = NSUserInterfaceItemIdentifier("ShortcutRows")
        shortcutRows.orientation = .vertical
        shortcutRows.spacing = 6
        let restoreButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreShortcuts))
        restoreButton.bezelStyle = .inline
        let shortcutContent = NSView()
        [shortcutTitle, shortcutSummary, shortcutRows, restoreButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            shortcutContent.addSubview($0)
        }
        NSLayoutConstraint.activate([
            shortcutTitle.topAnchor.constraint(equalTo: shortcutContent.topAnchor),
            shortcutTitle.leadingAnchor.constraint(equalTo: shortcutContent.leadingAnchor),
            shortcutSummary.centerYAnchor.constraint(equalTo: shortcutTitle.centerYAnchor),
            shortcutSummary.leadingAnchor.constraint(equalTo: shortcutTitle.trailingAnchor, constant: 10),
            shortcutSummary.trailingAnchor.constraint(lessThanOrEqualTo: shortcutContent.trailingAnchor),
            shortcutRows.topAnchor.constraint(equalTo: shortcutTitle.bottomAnchor, constant: 8),
            shortcutRows.leadingAnchor.constraint(equalTo: shortcutContent.leadingAnchor),
            shortcutRows.trailingAnchor.constraint(equalTo: shortcutContent.trailingAnchor),
            restoreButton.topAnchor.constraint(equalTo: shortcutRows.bottomAnchor, constant: 8),
            restoreButton.trailingAnchor.constraint(equalTo: shortcutContent.trailingAnchor),
            restoreButton.bottomAnchor.constraint(equalTo: shortcutContent.bottomAnchor),
        ])
        let shortcutCard = card(shortcutContent)

        launchSwitch.target = self
        launchSwitch.action = #selector(toggleLaunchAtLogin)
        launchStatus.font = .systemFont(ofSize: 12, weight: .medium)
        launchStatus.textColor = .secondaryLabelColor
        let launchTrailing = NSStackView(views: [launchStatus, launchSwitch])
        launchTrailing.orientation = .horizontal
        launchTrailing.alignment = .centerY
        launchTrailing.spacing = 9
        let launchTitle = label("Launch at Login", size: 13, weight: .semibold)
        let launchBody = label("Start quietly in the menu bar so Control-P is ready when you are.", size: 12, color: .secondaryLabelColor)
        launchBody.maximumNumberOfLines = 2
        let launchContent = NSView()
        [launchTitle, launchTrailing, launchBody].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            launchContent.addSubview($0)
        }
        NSLayoutConstraint.activate([
            launchTitle.topAnchor.constraint(equalTo: launchContent.topAnchor),
            launchTitle.leadingAnchor.constraint(equalTo: launchContent.leadingAnchor),
            launchTrailing.centerYAnchor.constraint(equalTo: launchTitle.centerYAnchor),
            launchTrailing.leadingAnchor.constraint(greaterThanOrEqualTo: launchTitle.trailingAnchor, constant: 10),
            launchTrailing.trailingAnchor.constraint(equalTo: launchContent.trailingAnchor),
            launchBody.topAnchor.constraint(equalTo: launchTitle.bottomAnchor, constant: 8),
            launchBody.leadingAnchor.constraint(equalTo: launchContent.leadingAnchor),
            launchBody.trailingAnchor.constraint(equalTo: launchContent.trailingAnchor),
            launchBody.bottomAnchor.constraint(equalTo: launchContent.bottomAnchor),
        ])
        let launchCard = card(launchContent)

        let privacy = label(
            "ScreenWren does not upload captures. Images are placed on the system clipboard, and session recents stay only in memory until ScreenWren quits.",
            size: 11,
            color: .tertiaryLabelColor
        )
        privacy.maximumNumberOfLines = 3

        messageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        secondaryButton.title = "Not Now"
        secondaryButton.target = self
        secondaryButton.action = #selector(dismissWindow)
        primaryButton.target = self
        primaryButton.action = #selector(primaryAction)
        primaryButton.keyEquivalent = "\r"
        primaryButton.bezelColor = .controlAccentColor
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footerButtons = NSStackView(views: [messageLabel, footerSpacer, secondaryButton, primaryButton])
        footerButtons.orientation = .horizontal
        footerButtons.alignment = .centerY
        footerButtons.spacing = 10

        let stack = NSStackView(views: [hero, permissionCard, shortcutCard, launchCard, privacy, footerButtons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22),
            permissionCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            launchCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            privacy.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerButtons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])

        rebuildShortcutRows(in: shortcutRows)
        refresh()
        return controller
    }

    private func rebuildShortcutRows() {
        guard let root = window?.contentViewController?.view,
              let rows = findView(identifier: "ShortcutRows", in: root) as? NSStackView else { return }
        rebuildShortcutRows(in: rows)
    }

    private func rebuildShortcutRows(in rows: NSStackView) {
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        for command in ShortcutCommand.allCases {
            let name = label(command.title, size: 12, weight: .medium)
            let recorder = ShortcutRecorderField(shortcut: shortcutManager.shortcut(for: command))
            recorder.setAccessibilityLabel("\(command.title) shortcut")
            recorder.onRecord = { [weak self] shortcut in
                self?.shortcutManager.update(command, to: shortcut)
            }
            recorder.onMessage = { [weak self] message in
                self?.messageLabel.stringValue = message
                self?.refresh()
            }
            recorder.translatesAutoresizingMaskIntoConstraints = false
            recorder.widthAnchor.constraint(equalToConstant: 112).isActive = true
            recorder.heightAnchor.constraint(equalToConstant: 24).isActive = true

            let row = NSStackView(views: [name, recorder])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            recorder.setContentHuggingPriority(.required, for: .horizontal)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    private func card(_ content: NSView) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        container.layer?.borderWidth = 1
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        return container
    }

    private func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func findView(identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        return view.subviews.lazy.compactMap { self.findView(identifier: identifier, in: $0) }.first
    }

    private func finishDismissal() {
        guard !dismissed else { return }
        dismissed = true
        onDismiss?()
    }
}
