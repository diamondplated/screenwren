import AppKit

@MainActor
final class TopAlignedStackView: NSStackView { override var isFlipped: Bool { true } }

struct SessionCapture {
    let id: UUID
    let image: CGImage
    let date: Date
    let scale: CGFloat
    init(image: CGImage, date: Date = Date(), scale: CGFloat = 1, id: UUID = UUID()) {
        self.image = image
        self.date = date
        self.scale = scale
        self.id = id
    }
    var byteCount: Int { image.bytesPerRow * image.height }
}

@MainActor
struct ClipboardTicket {
    let generation: UInt64
    let changeCount: Int
    init(on pasteboard: NSPasteboard = .general) {
        generation = ClipboardDeliveryOrder.shared.begin()
        changeCount = pasteboard.changeCount
    }
    func isCurrent(on pasteboard: NSPasteboard = .general) -> Bool {
        ClipboardDeliveryOrder.shared.isCurrent(generation)
            && clipboardStateIsUnchanged(since: changeCount, on: pasteboard)
    }
}

enum RecentAction { case copy, edit, pin, save }

@MainActor
final class RecentPickerWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var records: [SessionCapture] = []
    private let table = NSTableView()
    private let layout = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private let onAction: (RecentAction, UUID) -> Void
    private let onCombine: ([UUID], CompositionLayout) -> Void
    private let onDelete: ([UUID]) -> Void
    var onClose: (() -> Void)?
    init(
        onAction: @escaping (RecentAction, UUID) -> Void, onCombine: @escaping ([UUID], CompositionLayout) -> Void,
        onDelete: @escaping ([UUID]) -> Void
    ) {
        self.onAction = onAction
        self.onCombine = onCombine
        self.onDelete = onDelete
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 750, height: 590), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Recent Captures — This Session"
        window.minSize = CGSize(width: 650, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let preview = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preview"))
        preview.title = "Capture"
        preview.width = 190
        let details = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("details"))
        details.title = "Details"
        details.width = 400
        table.addTableColumn(preview)
        table.addTableColumn(details)
        table.rowHeight = 86
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(edit)
        table.setAccessibilityLabel("Recent captures")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyImage))
        let edit = NSButton(title: "Edit", target: self, action: #selector(edit))
        let pin = NSButton(title: "Pin", target: self, action: #selector(pin))
        let save = NSButton(title: "Export…", target: self, action: #selector(save))
        let remove = NSButton(title: "Remove", target: self, action: #selector(remove))
        let combine = NSButton(title: "Combine Selected", target: self, action: #selector(combine))
        buttons = [copy, edit, pin, save, remove, combine]
        layout.addItems(withTitles: CompositionLayout.allCases.map(\.title))
        layout.setAccessibilityLabel("Combined image layout")
        let actions = NSStackView(views: [copy, edit, pin, save, remove])
        actions.spacing = 10
        let combineRow = NSStackView(views: [layout, combine])
        combineRow.spacing = 12
        let content = NSStackView(views: [
            NSTextField(
                wrappingLabelWithString:
                    "Choose a capture, or Command-click several to combine. Combined images are ordered oldest first. Up to five captures stay in memory; quitting clears them."
            ), scroll, actions, combineRow, status,
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
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        window.center()
        refreshButtons()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ values: [SessionCapture]) {
        let selected = Set(selectedIDs)
        records = values
        table.reloadData()
        let indices = IndexSet(records.indices.filter { selected.contains(records[$0].id) })
        if indices.isEmpty && !records.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            table.selectRowIndexes(indices, byExtendingSelection: false)
        }
        refreshButtons()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let record = records[row]
        if tableColumn?.identifier.rawValue == "preview" {
            let image = NSImageView(
                image: NSImage(
                    cgImage: record.image, size: CGSize(width: record.image.width, height: record.image.height)))
            image.imageScaling = .scaleProportionallyUpOrDown
            image.setAccessibilityLabel("Capture \(row + 1)")
            return image
        }
        let label = NSTextField(
            wrappingLabelWithString:
                "\(record.date.formatted(date: .omitted, time: .standard))\n\(record.image.width) × \(record.image.height) pixels"
        )
        label.font = .systemFont(ofSize: 13)
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { refreshButtons() }
    private var selectedIDs: [UUID] {
        table.selectedRowIndexes.compactMap { records.indices.contains($0) ? records[$0].id : nil }
    }
    private func refreshButtons() {
        let count = selectedIDs.count
        for button in buttons.prefix(4) { button.isEnabled = count == 1 }
        if buttons.count == 6 {
            buttons[4].isEnabled = count > 0
            buttons[5].isEnabled = count >= 2
        }
        status.stringValue =
            records.isEmpty ? "No captures yet." : "\(count) selected · \(records.count) in this session"
    }
    private func act(_ action: RecentAction) {
        guard let id = selectedIDs.first, selectedIDs.count == 1 else { return }
        onAction(action, id)
    }
    @objc private func copyImage() { act(.copy) }
    @objc private func edit() { act(.edit) }
    @objc private func pin() { act(.pin) }
    @objc private func save() { act(.save) }
    @objc private func remove() { onDelete(selectedIDs) }
    @objc private func combine() {
        guard selectedIDs.count >= 2 else { return }
        onCombine(selectedIDs, CompositionLayout.allCases[layout.indexOfSelectedItem])
    }
    func windowWillClose(_ notification: Notification) {
        records = []
        table.reloadData()
        onClose?()
    }
}

@MainActor
private final class QuickCapturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickCaptureWindow: NSWindowController {
    private var expiry: Task<Void, Never>?
    var onClose: (() -> Void)?
    private let onAction: (RecentAction) -> Void
    init(image: CGImage, onAction: @escaping (RecentAction) -> Void) {
        self.onAction = onAction
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let panel = QuickCapturePanel(
            contentRect: CGRect(x: visible.maxX - 310, y: visible.minY + 20, width: 290, height: 210),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.backgroundColor = .windowBackgroundColor
        super.init(window: panel)
        let preview = PNGPromiseDragView(
            image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        ) { makePNGFilePromiseProvider { try await pngDataOffMain(for: image) } }
        preview.toolTip = "Drag this capture as PNG"
        preview.heightAnchor.constraint(equalToConstant: 132).isActive = true
        let edit = NSButton(title: "Edit", target: self, action: #selector(edit))
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        let pin = NSButton(title: "Pin", target: self, action: #selector(pin))
        let dismiss = NSButton(title: "×", target: self, action: #selector(dismiss))
        dismiss.setAccessibilityLabel("Dismiss capture thumbnail")
        let actions = NSStackView(views: [edit, save, pin, dismiss])
        actions.spacing = 8
        let content = NSStackView(views: [preview, actions])
        content.orientation = .vertical
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 12),
            preview.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        window?.orderFrontRegardless()
        expiry = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(6))
                try Task.checkCancellation()
                self?.close()
            } catch {}
        }
    }
    override func close() {
        expiry?.cancel()
        expiry = nil
        super.close()
        let completion = onClose
        onClose = nil
        completion?()
    }
    @objc private func edit() {
        close()
        onAction(.edit)
    }
    @objc private func save() {
        close()
        onAction(.save)
    }
    @objc private func pin() {
        close()
        onAction(.pin)
    }
    @objc private func dismiss() { close() }
}
