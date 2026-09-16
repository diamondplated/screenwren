import AppKit
import UniformTypeIdentifiers

func timestampedPNGFilename(for date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return "ScreenWren Capture \(formatter.string(from: date)).png"
}

final class PNGFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let filename: String
    private let dataProvider: @MainActor @Sendable () async throws -> Data
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ScreenWren PNG file promise"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(filename: String, dataProvider: @escaping @MainActor @Sendable () async throws -> Data) {
        self.filename = filename
        self.dataProvider = dataProvider
    }

    @MainActor
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        filename
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        promiseQueue
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo destinationURL: URL,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        Task {
            do {
                let data = try await dataProvider()
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var writeError: Error?
                coordinator.coordinate(
                    writingItemAt: destinationURL,
                    options: .forReplacing,
                    error: &coordinationError
                ) { coordinatedURL in
                    do {
                        try data.write(to: coordinatedURL, options: .atomic)
                    } catch {
                        writeError = error
                    }
                }
                if let error = coordinationError ?? writeError as NSError? { throw error }
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}

@MainActor
func makePNGFilePromiseProvider(
    filename: String = timestampedPNGFilename(),
    dataProvider: @escaping @MainActor @Sendable () async throws -> Data
) -> NSFilePromiseProvider {
    let delegate = PNGFilePromiseDelegate(filename: filename, dataProvider: dataProvider)
    let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: delegate)
    provider.userInfo = delegate // NSFilePromiseProvider's delegate is weak.
    return provider
}

@MainActor
func makePNGItemProvider(
    filename: String = timestampedPNGFilename(),
    dataProvider: @escaping @MainActor @Sendable () async throws -> Data
) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.suggestedName = filename
    provider.registerDataRepresentation(
        forTypeIdentifier: UTType.png.identifier,
        visibility: .all
    ) { completion in
        let progress = Progress(totalUnitCount: 1)
        Task { @MainActor in
            do {
                let data = try await dataProvider()
                progress.completedUnitCount = 1
                completion(data, nil)
            } catch {
                completion(nil, error)
            }
        }
        return progress
    }
    return provider
}

@MainActor
final class PNGPromiseDragView: NSImageView, NSDraggingSource {
    private let provider: () -> NSFilePromiseProvider
    private var dragStarted = false
    private var mouseDownEvent: NSEvent?

    init(image: NSImage, provider: @escaping () -> NSFilePromiseProvider) {
        self.provider = provider
        super.init(frame: .zero)
        self.image = image
        imageAlignment = .alignCenter
        imageScaling = .scaleProportionallyUpOrDown
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Drag image as PNG")
        setAccessibilityHelp("Drag the image to export it as a PNG file.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragStarted = false
    }

    override func mouseUp(with event: NSEvent) {
        if !dragStarted { mouseDownEvent = nil }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let image, let mouseDownEvent else { return }
        dragStarted = true

        let item = NSDraggingItem(pasteboardWriter: provider())
        item.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [item], event: mouseDownEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        dragStarted = false
        mouseDownEvent = nil
    }
}

@MainActor
final class PinnedWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let opacity = NSSlider(value: 100, minValue: 20, maxValue: 100, target: nil, action: nil)
    private let zoom = NSSlider(value: 100, minValue: 25, maxValue: 200, target: nil, action: nil)
    private let lock = NSButton(checkboxWithTitle: "Click through", target: nil, action: nil)
    private let baseSize: CGSize

    init(image: CGImage, sourceScale: CGFloat = 1) {
        let imageSize = CGSize(
            width: CGFloat(image.width) / max(1, sourceScale), height: CGFloat(image.height) / max(1, sourceScale))
        let available = NSScreen.main?.visibleFrame.insetBy(dx: 80, dy: 80).size ?? CGSize(width: 900, height: 700)
        let fit = min(1, available.width / imageSize.width, (available.height - 75) / imageSize.height)
        baseSize = CGSize(width: max(320, imageSize.width * fit), height: max(100, imageSize.height * fit))
        let dragView = PNGPromiseDragView(image: NSImage(cgImage: image, size: imageSize)) {
            makePNGFilePromiseProvider { try await pngDataOffMain(for: image) }
        }
        let window = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: baseSize.width, height: baseSize.height + 75)),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Pinned Capture"; window.level = .floating; window.isFloatingPanel = true;
        window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 320, height: 200); window.center()
        super.init(window: window); window.delegate = self
        opacity.target = self; opacity.action = #selector(changeOpacity); opacity.setAccessibilityLabel("Pin opacity")
        zoom.target = self; zoom.action = #selector(changeZoom); zoom.setAccessibilityLabel("Pin zoom")
        lock.target = self; lock.action = #selector(changeLock)
        let controls = NSStackView(views: [
            NSTextField(labelWithString: "Opacity"), opacity, NSTextField(labelWithString: "Zoom"), zoom,
        ]); controls.spacing = 8
        NSLayoutConstraint.activate([
            opacity.widthAnchor.constraint(equalTo: zoom.widthAnchor),
            zoom.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
        let help = NSTextField(
            wrappingLabelWithString: "Unlock from ScreenWren’s menu. Use Toggle Pins to hide or restore all references."
        ); help.font = .systemFont(ofSize: 10); help.textColor = .secondaryLabelColor
        let bottom = NSStackView(views: [lock, help]); bottom.spacing = 8
        let content = NSStackView(views: [dragView, controls, bottom]); content.orientation = .vertical;
        content.spacing = 6; content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -8),
            dragView.widthAnchor.constraint(equalTo: content.widthAnchor),
            dragView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            controls.widthAnchor.constraint(equalTo: content.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changeOpacity() { window?.alphaValue = opacity.doubleValue / 100 }
    @objc private func changeZoom() {
        guard let window else { return }; let ratio = zoom.doubleValue / 100
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1000, height: 800)
        window.setContentSize(
            CGSize(
                width: min(available.width - 20, max(320, baseSize.width * ratio)),
                height: min(available.height - 45, max(150, baseSize.height * ratio + 75))))
    }
    @objc private func changeLock() { window?.ignoresMouseEvents = lock.state == .on }
    func unlock() { lock.state = .off; window?.ignoresMouseEvents = false }
    func windowWillClose(_ notification: Notification) { onClose?(); onClose = nil }
}
