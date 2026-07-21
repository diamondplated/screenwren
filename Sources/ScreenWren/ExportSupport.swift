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

    init(image: CGImage) {
        let imageSize = NSSize(width: image.width, height: image.height)
        let nsImage = NSImage(cgImage: image, size: imageSize)
        let dragView = PNGPromiseDragView(image: nsImage) {
            makePNGFilePromiseProvider {
                try await pngDataOffMain(for: image)
            }
        }

        let available = NSScreen.main?.visibleFrame.insetBy(dx: 80, dy: 80).size
            ?? NSSize(width: 900, height: 700)
        let scale = min(1, available.width / imageSize.width, available.height / imageSize.height)
        let contentSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let window = NSPanel(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = dragView
        window.contentAspectRatio = imageSize
        window.title = "Pinned Capture"
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }
}
