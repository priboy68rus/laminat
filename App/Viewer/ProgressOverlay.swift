import AppKit

/// Dims the view it covers and shows a large spinner, a message with a running timer and an optional
/// Cancel button (like DBeaver's "Executing query" panel). Appears after a short delay so instant
/// operations don't flash it.
final class ProgressOverlay: NSView {
    var onCancel: (() -> Void)? { didSet { cancelButton.isHidden = onCancel == nil } }

    private let backdrop = NSVisualEffectView()
    private let spinner = NSProgressIndicator()
    private let messageLabel = NSTextField(labelWithString: "")
    private let timerLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var message = ""
    private var startedAt: Date?
    private var timer: Timer?
    private var showWork: DispatchWorkItem?

    static let delay: TimeInterval = 0.15

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true

        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.alphaValue = 0.92
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .regular

        messageLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        messageLabel.alignment = .center

        timerLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timerLabel.textColor = .secondaryLabelColor
        timerLabel.alignment = .center

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.isHidden = true

        let stack = NSStackView(views: [spinner, messageLabel, timerLabel, cancelButton])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(16, after: timerLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(backdrop)
        addSubview(stack)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Swallow clicks so the content underneath can't be used while the overlay is up.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {}

    /// Adds the overlay to `container` as its topmost subview, covering `target` (default: the container).
    func install(in container: NSView, over target: NSView? = nil) {
        let target = target ?? container
        translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(self, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: target.topAnchor),
            leadingAnchor.constraint(equalTo: target.leadingAnchor),
            trailingAnchor.constraint(equalTo: target.trailingAnchor),
            bottomAnchor.constraint(equalTo: target.bottomAnchor),
        ])
    }

    func start(_ message: String) {
        self.message = message
        startedAt = Date()
        messageLabel.stringValue = message
        timerLabel.stringValue = "0.0 s"
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reveal() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    func stop() {
        showWork?.cancel()
        showWork = nil
        timer?.invalidate()
        timer = nil
        startedAt = nil
        spinner.stopAnimation(nil)
        isHidden = true
    }

    private func reveal() {
        guard startedAt != nil else { return }
        superview?.addSubview(self, positioned: .above, relativeTo: nil)
        isHidden = false
        spinner.startAnimation(nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    private func tick() {
        guard let startedAt else { return }
        timerLabel.stringValue = String(format: "%.1f s", Date().timeIntervalSince(startedAt))
    }

    @objc private func cancelClicked() {
        messageLabel.stringValue = "Cancelling…"
        onCancel?()
    }
}
