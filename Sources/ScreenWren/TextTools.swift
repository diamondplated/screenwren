import AppKit
import Vision

struct RecognizedWord: Sendable, Equatable {
    let text: String
    let bounds: CGRect
}
struct RecognizedLine: Sendable, Equatable {
    let text: String
    let bounds: CGRect
    var words: [RecognizedWord] = []
}
enum TextCopyLayout: String, CaseIterable {
    case plain, table, code
    var title: String {
        switch self {
        case .plain: "Plain Text"
        case .table: "Table (tab separated)"
        case .code: "Code / Preserve Spacing"
        }
    }
}
func recognizeLines(in image: CGImage) throws -> [RecognizedLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.automaticallyDetectsLanguage = true
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return (request.results ?? []).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let text = candidate.string
        let words = text.rangesOfWords.compactMap { range -> RecognizedWord? in
            guard let box = try? candidate.boundingBox(for: range) else { return nil }
            return RecognizedWord(text: String(text[range]), bounds: box.boundingBox)
        }
        return RecognizedLine(text: text, bounds: observation.boundingBox, words: words)
    }
}
extension String {
    fileprivate var rangesOfWords: [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in indices {
            if self[index].isWhitespace {
                if let first = start {
                    ranges.append(first..<index)
                    start = nil
                }
            } else if start == nil {
                start = index
            }
        }
        if let start { ranges.append(start..<endIndex) }
        return ranges
    }
}
func groupedTextRows(_ lines: [RecognizedLine]) -> [[RecognizedLine]] {
    var rows: [[RecognizedLine]] = []
    for index in readingOrderIndices(for: lines.map(\.bounds)) {
        let line = lines[index]
        if let row = rows.firstIndex(where: { values in
            guard let anchor = values.first else { return false }
            return abs(anchor.bounds.midY - line.bounds.midY) <= max(anchor.bounds.height, line.bounds.height) * 0.45
        }) {
            rows[row].append(line)
        } else {
            rows.append([line])
        }
    }
    return rows.map { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
}
func formattedRecognizedText(_ lines: [RecognizedLine], layout: TextCopyLayout) -> String {
    guard !lines.isEmpty else { return "" }
    let rows = groupedTextRows(lines)
    if layout == .plain { return rows.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n") }
    let characterWidths = lines.flatMap { line -> [CGFloat] in
        let words = line.words.isEmpty ? [RecognizedWord(text: line.text, bounds: line.bounds)] : line.words
        return words.filter { !$0.text.isEmpty }.map { $0.bounds.width / CGFloat(max(1, $0.text.count)) }
    }.filter { $0 > 0 }.sorted()
    let characterWidth = characterWidths.isEmpty ? 0.01 : characterWidths[characterWidths.count / 2]
    let left = lines.map { $0.bounds.minX }.min() ?? 0
    if layout == .code {
        var output: [String] = []
        var previousY: CGFloat?
        let lineHeight = lines.map { $0.bounds.height }.sorted()[lines.count / 2]
        for row in rows {
            guard let first = row.first else { continue }
            if let previousY, lineHeight > 0, previousY - first.bounds.midY > lineHeight * 2 {
                output.append(
                    contentsOf: repeatElement(
                        "", count: min(3, max(1, Int((previousY - first.bounds.midY) / lineHeight) - 1))))
            }
            var text = ""
            var right = left
            let words = row.flatMap { $0.words.isEmpty ? [RecognizedWord(text: $0.text, bounds: $0.bounds)] : $0.words }
                .sorted { $0.bounds.minX < $1.bounds.minX }
            for word in words {
                let spaces = min(
                    160, max(text.isEmpty ? 0 : 1, Int(((word.bounds.minX - right) / characterWidth).rounded())))
                text += String(repeating: " ", count: spaces) + word.text
                right = word.bounds.maxX
            }
            output.append(text)
            previousY = first.bounds.midY
        }
        return output.joined(separator: "\n")
    }
    // Merge nearby words into cells, then align cells across rows by their left edge.
    let cells = rows.map { row -> [RecognizedWord] in
        let words = row.flatMap { $0.words.isEmpty ? [RecognizedWord(text: $0.text, bounds: $0.bounds)] : $0.words }
            .sorted { $0.bounds.minX < $1.bounds.minX }
        var cells: [RecognizedWord] = []
        for word in words {
            if let last = cells.last, word.bounds.minX - last.bounds.maxX < characterWidth * 2.5 {
                cells[cells.count - 1] = RecognizedWord(
                    text: last.text + " " + word.text, bounds: last.bounds.union(word.bounds))
            } else {
                cells.append(word)
            }
        }
        return cells
    }
    var columns: [CGFloat] = []
    for x in cells.flatMap({ $0.map { $0.bounds.minX } }).sorted() {
        if columns.last.map({ abs($0 - x) > characterWidth * 2 }) ?? true { columns.append(x) }
    }
    return cells.map { row in
        var values = Array(repeating: "", count: columns.count)
        for cell in row {
            guard
                let index = columns.indices.min(by: {
                    abs(columns[$0] - cell.bounds.minX) < abs(columns[$1] - cell.bounds.minX)
                })
            else { continue }
            values[index] +=
                (values[index].isEmpty ? "" : " ")
                + cell.text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        return values.joined(separator: "\t")
    }.joined(separator: "\n")
}

enum RedactionKind: String, CaseIterable, Sendable {
    case email, phone, custom
    var title: String {
        switch self {
        case .email: "Email addresses"
        case .phone: "Phone numbers"
        case .custom: "Matching text"
        }
    }
}
struct RedactionSuggestion: Sendable, Equatable {
    let kind: RedactionKind
    let text: String
    let bounds: CGRect  // Vision normalized bottom-left coordinates.
}
func redactionSuggestions(in lines: [RecognizedLine], emails: Bool, phones: Bool, matching text: String)
    -> [RedactionSuggestion]
{
    let emailPattern = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
    let emailRegex = try? NSRegularExpression(pattern: emailPattern, options: .caseInsensitive)
    let phoneDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
    var output: [RedactionSuggestion] = []
    for line in lines {
        let full = NSRange(line.text.startIndex..., in: line.text)
        var matches: [(RedactionKind, NSRange)] = []
        if emails { matches += (emailRegex?.matches(in: line.text, range: full) ?? []).map { (.email, $0.range) } }
        if phones { matches += (phoneDetector?.matches(in: line.text, range: full) ?? []).map { (.phone, $0.range) } }
        if !text.isEmpty,
            let regex = try? NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: text), options: .caseInsensitive)
        {
            matches += regex.matches(in: line.text, range: full).map { (.custom, $0.range) }
        }
        for (kind, range) in matches {
            guard let swiftRange = Range(range, in: line.text) else { continue }
            // Mask the whole recognized line conservatively; no partial-character leaks.
            let value = String(line.text[swiftRange])
            if !output.contains(where: { $0.bounds == line.bounds }) {
                output.append(RedactionSuggestion(kind: kind, text: value, bounds: line.bounds))
            }
        }
    }
    return output
}
func redactionPixelRect(_ normalized: CGRect, width: Int, height: Int) -> CGRect {
    CGRect(
        x: normalized.minX * CGFloat(width), y: (1 - normalized.maxY) * CGFloat(height),
        width: normalized.width * CGFloat(width), height: normalized.height * CGFloat(height)
    )
    .insetBy(dx: -3, dy: -3).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
}
func applyRedactions(_ image: CGImage, bounds: [CGRect]) throws -> CGImage {
    try renderCGImage(width: image.width, height: image.height) { context in
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for box in bounds {
            let rect = redactionPixelRect(box, width: image.width, height: image.height)
            context.fill(
                CGRect(x: rect.minX, y: CGFloat(image.height) - rect.maxY, width: rect.width, height: rect.height))
        }
    }
}

@MainActor
final class TextPreviewWindow: NSWindowController, NSWindowDelegate {
    private let editor = NSTextView()
    private let mode = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "Recognizing text on this Mac…")
    private let copyButton = NSButton(title: "Copy Text", target: nil, action: nil)
    private var lines: [RecognizedLine] = []
    private var task: Task<Void, Never>?
    var onClose: (() -> Void)?
    init(image: CGImage) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 740, height: 570), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Text Preview"
        window.minSize = CGSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        mode.addItems(withTitles: TextCopyLayout.allCases.map(\.title))
        mode.target = self
        mode.action = #selector(changeLayout)
        mode.setAccessibilityLabel("Text layout")
        copyButton.target = self
        copyButton.action = #selector(copyText)
        copyButton.isEnabled = false
        editor.frame = CGRect(x: 0, y: 0, width: 700, height: 380)
        editor.minSize = CGSize(width: 660, height: 340)
        editor.maxSize = CGSize(width: 100_000, height: 100_000)
        editor.isVerticallyResizable = true
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isHorizontallyResizable = true
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = CGSize(width: 100_000, height: 100_000)
        editor.setAccessibilityLabel("Recognized text — editable preview")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = editor
        let top = NSStackView(views: [mode, copyButton])
        top.spacing = 16
        let content = NSStackView(views: [
            top,
            NSTextField(
                wrappingLabelWithString:
                    "Check and correct the text before copying. Layout is inferred from text positions; changing the mode replaces preview edits."
            ), scroll, status,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
        window.center()
        let payload = SendableImage(image: image)
        task = Task { @MainActor [weak self] in
            do {
                let lines = try await Task.detached(priority: .userInitiated) { try recognizeLines(in: payload.image) }
                    .value
                try Task.checkCancellation()
                guard let self else { return }
                self.lines = lines
                self.changeLayout()
                self.copyButton.isEnabled = true
            } catch is CancellationError {} catch {
                self?.status.stringValue = "Text recognition failed. Close and try again."
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changeLayout() {
        editor.string = formattedRecognizedText(lines, layout: TextCopyLayout.allCases[mode.indexOfSelectedItem])
        editor.sizeToFit()
        status.stringValue =
            lines.isEmpty ? "No text detected. You can type or paste corrections here." : "Nothing has been copied yet."
    }
    @objc private func copyText() {
        guard !editor.string.isEmpty else {
            status.stringValue = "There is no text to copy."
            return
        }
        _ = ClipboardDeliveryOrder.shared.begin()
        NSPasteboard.general.clearContents()
        status.stringValue =
            NSPasteboard.general.setString(editor.string, forType: .string) ? "Copied" : "Couldn’t copy text"
    }
    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        lines = []
        editor.string = ""
        onClose?()
    }
}

@MainActor
private final class RedactionPreview: NSView {
    let image: CGImage
    var onManualMask: ((CGRect) -> Void)?
    private var dragStart: CGPoint?
    private var dragRect: CGRect?
    private var imageFrame: CGRect {
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragRect = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        dragRect = normalizedRect(from: dragStart, to: convert(event.locationInWindow, from: nil)).intersection(
            imageFrame)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragRect = nil
            needsDisplay = true
        }
        guard let rect = dragRect, rect.width >= 2, rect.height >= 2, imageFrame.width > 0, imageFrame.height > 0 else {
            return
        }
        onManualMask?(
            CGRect(
                x: (rect.minX - imageFrame.minX) / imageFrame.width,
                y: (rect.minY - imageFrame.minY) / imageFrame.height, width: rect.width / imageFrame.width,
                height: rect.height / imageFrame.height))
    }
    var masks: [CGRect] = [] { didSet { needsDisplay = true } }
    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Redaction preview. Selected suggestions appear as opaque black masks.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let rect = CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        NSImage(cgImage: image, size: size).draw(in: rect)
        if let dragRect {
            NSColor.systemOrange.withAlphaComponent(0.6).setFill()
            dragRect.fill()
        }
        NSColor.black.setFill()
        for mask in masks {
            let pixels = redactionPixelRect(mask, width: image.width, height: image.height)
            CGRect(
                x: rect.minX + pixels.minX * scale, y: rect.minY + (CGFloat(image.height) - pixels.maxY) * scale,
                width: pixels.width * scale, height: pixels.height * scale
            ).fill()
        }
    }
}

@MainActor
final class RedactionReviewWindow: NSWindowController, NSWindowDelegate {
    private let image: CGImage
    private let preview: RedactionPreview
    private let emails = NSButton(checkboxWithTitle: "Emails", target: nil, action: nil)
    private let phones = NSButton(checkboxWithTitle: "Phones", target: nil, action: nil)
    private let match = NSTextField(string: "")
    private let rows = TopAlignedStackView()
    private let status = NSTextField(wrappingLabelWithString: "Recognizing text locally…")
    private let apply = NSButton(title: "", target: nil, action: nil)
    private var lines: [RecognizedLine] = []
    private var suggestions: [RedactionSuggestion] = []
    private var manualMasks: [CGRect] = []
    private var checks: [NSButton] = []
    private var task: Task<Void, Never>?
    private let onApply: (CGImage, ClipboardTicket?) -> Void
    private let copiesOnApproval: Bool
    var onClose: (() -> Void)?
    init(
        image: CGImage, actionTitle: String, copiesOnApproval: Bool = true,
        onApply: @escaping (CGImage, ClipboardTicket?) -> Void
    ) {
        self.image = image
        preview = RedactionPreview(image: image)
        self.onApply = onApply
        self.copiesOnApproval = copiesOnApproval
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 780, height: 700), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Review Redactions"
        window.minSize = CGSize(width: 660, height: 620)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        preview.onManualMask = { [weak self] rect in
            self?.manualMasks.append(rect)
            self?.updateMasks()
        }
        emails.state = .on
        phones.state = .on
        for button in [emails, phones] {
            button.target = self
            button.action = #selector(findSuggestions)
        }
        match.placeholderString = "Also mask this text"
        match.setAccessibilityLabel("Literal text to redact")
        match.widthAnchor.constraint(equalToConstant: 210).isActive = true
        match.target = self
        match.action = #selector(findSuggestions)
        let controls = NSStackView(views: [
            emails, phones, match, NSButton(title: "Find", target: self, action: #selector(findSuggestions)),
            NSButton(title: "Clear Drawn Masks", target: self, action: #selector(clearManualMasks)),
        ])
        controls.spacing = 12
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        let scroll = NSScrollView()
        scroll.documentView = rows
        scroll.hasVerticalScroller = true
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        apply.title = actionTitle
        apply.target = self
        apply.action = #selector(applySelected)
        apply.isEnabled = false
        let buttons = NSStackView(views: [NSButton(title: "Cancel", target: self, action: #selector(cancel)), apply])
        buttons.spacing = 12
        let delivery =
            copiesOnApproval
            ? "This capture stays off the clipboard until you approve it."
            : "Changes apply to the editor. This cannot retract any image you already copied."
        let explanation = NSTextField(
            wrappingLabelWithString:
                "Review every mask. Suggestions can miss sensitive content and cover whole recognized lines. Drag on the preview to add a mask. Uncheck a suggestion to keep that line. "
                + delivery)
        let content = NSStackView(views: [explanation, preview, controls, scroll, status, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            preview.widthAnchor.constraint(equalTo: content.widthAnchor),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 140),
        ])
        window.center()
        let payload = SendableImage(image: image)
        task = Task { @MainActor [weak self] in
            do {
                let lines = try await Task.detached(priority: .userInitiated) { try recognizeLines(in: payload.image) }
                    .value
                try Task.checkCancellation()
                guard let self else { return }
                self.lines = lines
                self.findSuggestions()
                self.apply.isEnabled = true
            } catch is CancellationError {} catch {
                self?.status.stringValue = "Recognition failed. Draw masks on the preview before approving."
                self?.apply.isEnabled = true
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func findSuggestions() {
        suggestions = redactionSuggestions(
            in: lines, emails: emails.state == .on, phones: phones.state == .on, matching: match.stringValue)
        rows.arrangedSubviews.forEach {
            rows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        checks = []
        for suggestion in suggestions {
            let check = NSButton(
                checkboxWithTitle: "\(suggestion.kind.title): \(suggestion.text)", target: self,
                action: #selector(updateMasks))
            check.state = .on
            check.lineBreakMode = .byTruncatingTail
            checks.append(check)
            rows.addArrangedSubview(check)
        }
        updateMasks()
    }
    @objc private func clearManualMasks() {
        manualMasks = []
        updateMasks()
    }
    @objc private func updateMasks() {
        preview.masks =
            suggestions.indices.filter { checks[$0].state == .on }.map { suggestions[$0].bounds } + manualMasks
        status.stringValue =
            suggestions.isEmpty
            ? "No matches found. This does not mean the image contains no private information."
            : "\(preview.masks.count) masks selected (\(manualMasks.count) drawn)."
    }
    @objc private func applySelected() {
        guard apply.isEnabled else { return }
        apply.isEnabled = false
        let payload = SendableImage(image: image)
        let masks = preview.masks
        let ticket = copiesOnApproval ? ClipboardTicket() : nil
        task = Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    SendableImage(image: try applyRedactions(payload.image, bounds: masks))
                }.value
                try Task.checkCancellation()
                guard let self else { return }
                self.onApply(result.image, ticket)
                self.close()
            } catch is CancellationError {} catch {
                self?.status.stringValue = "Couldn’t apply redactions."
                self?.apply.isEnabled = true
            }
        }
    }
    override func close() {
        if let sheet = window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        super.close()
    }
    @objc private func cancel() { close() }
    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        lines = []
        suggestions = []
        onClose?()
    }
}
