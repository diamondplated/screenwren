import AppKit

// Preferences contain behavior and dimensions only, never captured content.
enum CaptureDestination: String, CaseIterable, Codable {
    case clipboard, editor, pin, save, review
    var title: String {
        switch self {
        case .clipboard: "Copy only"
        case .editor: "Copy and open editor"
        case .pin: "Copy and pin"
        case .save: "Save…"
        case .review: "Review redactions before copying"
        }
    }
    var copiesImmediately: Bool { self == .clipboard || self == .editor || self == .pin }
}

struct SelectionPreset: Codable, Equatable {
    var name: String
    var width: Int
    var height: Int
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (4...16_000).contains(width)
            && (4...16_000).contains(height)
    }
}

struct SelectionOptions: Equatable {
    var adjustBeforeCapture = false
    var fixedSize: CGSize?
    var aspectRatio: CGFloat?
}

@MainActor
final class WorkflowPreferences {
    static let shared = WorkflowPreferences()
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var destination: CaptureDestination {
        get { CaptureDestination(rawValue: defaults.string(forKey: "capture.destination") ?? "") ?? .clipboard }
        set { defaults.set(newValue.rawValue, forKey: "capture.destination") }
    }
    var showsThumbnail: Bool {
        get { defaults.bool(forKey: "capture.thumbnail") }
        set { defaults.set(newValue, forKey: "capture.thumbnail") }
    }
    var adjustBeforeCapture: Bool {
        get { defaults.bool(forKey: "selection.adjust") }
        set { defaults.set(newValue, forKey: "selection.adjust") }
    }
    var fixedSize: CGSize? {
        get {
            let w = defaults.integer(forKey: "selection.width")
            let h = defaults.integer(forKey: "selection.height")
            return (4...16_000).contains(w) && (4...16_000).contains(h) ? CGSize(width: w, height: h) : nil
        }
        set {
            defaults.set(newValue.map { Int($0.width) } ?? 0, forKey: "selection.width")
            defaults.set(newValue.map { Int($0.height) } ?? 0, forKey: "selection.height")
        }
    }
    var aspectRatio: CGFloat? {
        get {
            let r = defaults.double(forKey: "selection.ratio")
            return r.isFinite && r > 0 ? r : nil
        }
        set { defaults.set(newValue ?? 0, forKey: "selection.ratio") }
    }
    var presets: [SelectionPreset] {
        get {
            guard let data = defaults.data(forKey: "selection.presets"),
                let values = try? JSONDecoder().decode([SelectionPreset].self, from: data)
            else { return [] }
            return Array(values.filter(\.isValid).prefix(20))
        }
        set {
            defaults.set(
                try? JSONEncoder().encode(Array(newValue.filter(\.isValid).prefix(20))), forKey: "selection.presets")
        }
    }
    var selectionOptions: SelectionOptions {
        SelectionOptions(adjustBeforeCapture: adjustBeforeCapture, fixedSize: fixedSize, aspectRatio: aspectRatio)
    }
}

// Clamp without shrinking when moving; resize remains inside the desktop bounds.
func adjustedSelection(
    _ rectangle: CGRect, dx: CGFloat, dy: CGFloat, resizing: Bool, bounds: CGRect, ratio: CGFloat? = nil,
    minimumSize: CGFloat = 4
) -> CGRect {
    var result = rectangle
    if resizing {
        var width = max(minimumSize, rectangle.width + dx)
        var height = max(minimumSize, rectangle.height + dy)
        if let ratio, ratio > 0 {
            if dx != 0 { height = width / ratio } else { width = height * ratio }
            let fit = min(1, (bounds.maxX - rectangle.minX) / width, (bounds.maxY - rectangle.minY) / height)
            width *= fit
            height *= fit
        }
        result.size = CGSize(
            width: min(width, bounds.maxX - result.minX), height: min(height, bounds.maxY - result.minY))
    } else {
        result.origin.x = min(max(bounds.minX, rectangle.minX + dx), bounds.maxX - rectangle.width)
        result.origin.y = min(max(bounds.minY, rectangle.minY + dy), bounds.maxY - rectangle.height)
    }
    return result
}

func constrainedSelection(
    from start: CGPoint, to end: CGPoint, bounds: CGRect, fixedSize: CGSize?, ratio: CGFloat?, pixelScale: CGFloat = 1
)
    -> CGRect
{
    let target = CGPoint(x: min(max(end.x, bounds.minX), bounds.maxX), y: min(max(end.y, bounds.minY), bounds.maxY))
    if let fixedSize {
        let size = CGSize(width: min(fixedSize.width, bounds.width), height: min(fixedSize.height, bounds.height))
        let x = ((target.x - size.width / 2) * pixelScale).rounded() / pixelScale
        let y = ((target.y - size.height / 2) * pixelScale).rounded() / pixelScale
        return CGRect(
            x: min(max(x, bounds.minX), bounds.maxX - size.width),
            y: min(max(y, bounds.minY), bounds.maxY - size.height), width: size.width,
            height: size.height)
    }
    var dx = target.x - start.x
    var dy = target.y - start.y
    if let ratio, ratio > 0 {
        let width = min(abs(dx), abs(dy) * ratio)
        dx = (dx < 0 ? -1 : 1) * width
        dy = (dy < 0 ? -1 : 1) * width / ratio
    }
    return normalizedRect(from: start, to: CGPoint(x: start.x + dx, y: start.y + dy)).intersection(bounds)
}

@MainActor
final class WorkflowPreferencesWindow: NSWindowController {
    private let preferences: WorkflowPreferences
    private let destination = NSPopUpButton()
    private let thumbnail = NSButton(
        checkboxWithTitle: "Show a quick-action thumbnail for 6 seconds", target: nil, action: nil)
    private let adjust = NSButton(
        checkboxWithTitle: "Adjust the selection before capturing (Return confirms)", target: nil, action: nil)
    private let width = NSTextField(string: "")
    private let height = NSTextField(string: "")
    private let ratio = NSPopUpButton()
    private let presets = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")

    init(preferences: WorkflowPreferences = .shared) {
        self.preferences = preferences
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 590, height: 500), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Capture Preferences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
        ])
        let heading = NSTextField(labelWithString: "Capture, then keep moving")
        heading.font = .systemFont(ofSize: 22, weight: .bold)
        content.addArrangedSubview(heading)
        destination.addItems(withTitles: CaptureDestination.allCases.map(\.title))
        destination.selectItem(at: CaptureDestination.allCases.firstIndex(of: preferences.destination) ?? 0)
        destination.target = self
        destination.action = #selector(saveBehavior)
        content.addArrangedSubview(row("After capture", destination))
        thumbnail.state = preferences.showsThumbnail ? .on : .off
        thumbnail.target = self
        thumbnail.action = #selector(saveBehavior)
        content.addArrangedSubview(thumbnail)
        adjust.state = preferences.adjustBeforeCapture ? .on : .off
        adjust.target = self
        adjust.action = #selector(saveBehavior)
        content.addArrangedSubview(adjust)
        content.addArrangedSubview(
            NSTextField(
                wrappingLabelWithString:
                    "Hold Shift when releasing a selection to adjust it once. Arrow keys move it; Option–arrows resize it; Shift makes larger steps. Escape always cancels."
            ))
        width.placeholderString = "Free"
        height.placeholderString = "Free"
        width.setAccessibilityLabel("Selection width in pixels")
        height.setAccessibilityLabel("Selection height in pixels")
        width.widthAnchor.constraint(equalToConstant: 92).isActive = true
        height.widthAnchor.constraint(equalToConstant: 92).isActive = true
        if let size = preferences.fixedSize {
            width.stringValue = "\(Int(size.width))"
            height.stringValue = "\(Int(size.height))"
        }
        let dimensions = NSStackView(views: [
            NSTextField(labelWithString: "Exact pixels"), width, NSTextField(labelWithString: "×"), height,
            NSButton(title: "Apply", target: self, action: #selector(saveDimensions)),
            NSButton(title: "Free", target: self, action: #selector(clearDimensions)),
        ])
        dimensions.spacing = 8
        content.addArrangedSubview(dimensions)
        ratio.addItems(withTitles: ["Free aspect ratio", "Square (1:1)", "16:9", "4:3", "3:2"])
        let ratios: [CGFloat] = [0, 1, 16.0 / 9, 4.0 / 3, 1.5]
        ratio.selectItem(at: ratios.firstIndex(of: preferences.aspectRatio ?? 0) ?? 0)
        ratio.target = self
        ratio.action = #selector(saveBehavior)
        content.addArrangedSubview(row("Shape", ratio))
        presets.target = self
        presets.action = #selector(loadPreset)
        content.addArrangedSubview(
            NSStackView(views: [
                presets, NSButton(title: "Save Size Preset…", target: self, action: #selector(savePreset)),
                NSButton(title: "Delete Preset", target: self, action: #selector(deletePreset)),
            ]))
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        content.addArrangedSubview(status)
        reloadPresets()
        status.stringValue =
            "Save always asks for a destination. Review mode does not copy or add an unreviewed image to Recents."
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func row(_ label: String, _ control: NSView) -> NSStackView {
        let row = NSStackView(views: [NSTextField(labelWithString: label), control])
        row.spacing = 12
        return row
    }
    @objc private func saveBehavior() {
        preferences.destination = CaptureDestination.allCases[destination.indexOfSelectedItem]
        preferences.showsThumbnail = thumbnail.state == .on
        preferences.adjustBeforeCapture = adjust.state == .on
        let ratios: [CGFloat] = [0, 1, 16.0 / 9, 4.0 / 3, 1.5]
        preferences.aspectRatio = ratio.indexOfSelectedItem == 0 ? nil : ratios[ratio.indexOfSelectedItem]
    }
    @discardableResult @objc private func saveDimensions() -> Bool {
        guard let w = Int(width.stringValue), let h = Int(height.stringValue), (4...16_000).contains(w),
            (4...16_000).contains(h)
        else {
            status.stringValue = "Enter both dimensions from 4 to 16,000 pixels, or choose Free."
            return false
        }
        preferences.fixedSize = CGSize(width: w, height: h)
        status.stringValue = "Size saved. A size larger than the available desktop is clipped to fit."
        return true
    }
    @objc private func clearDimensions() {
        preferences.fixedSize = nil
        width.stringValue = ""
        height.stringValue = ""
        status.stringValue = "Free selection size."
    }
    private func reloadPresets() {
        presets.removeAllItems()
        presets.addItem(withTitle: "Saved sizes…")
        presets.addItems(withTitles: preferences.presets.map { "\($0.name) — \($0.width) × \($0.height)" })
    }
    @objc private func loadPreset() {
        let index = presets.indexOfSelectedItem - 1
        guard preferences.presets.indices.contains(index) else { return }
        let value = preferences.presets[index]
        width.stringValue = "\(value.width)"
        height.stringValue = "\(value.height)"
        saveDimensions()
    }
    @objc private func savePreset() {
        guard saveDimensions(), let size = preferences.fixedSize else { return }
        let alert = NSAlert()
        alert.messageText = "Name this size"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Preset name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = SelectionPreset(
            name: String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)),
            width: Int(size.width), height: Int(size.height))
        guard value.isValid else {
            status.stringValue = "Enter a preset name."
            return
        }
        var values = preferences.presets.filter { $0.name != value.name }
        values.insert(value, at: 0)
        preferences.presets = values
        reloadPresets()
    }
    @objc private func deletePreset() {
        let index = presets.indexOfSelectedItem - 1
        var values = preferences.presets
        guard values.indices.contains(index) else { return }
        values.remove(at: index)
        preferences.presets = values
        reloadPresets()
    }
}
