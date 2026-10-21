import UIKit
import WebKit

/// The site the user is on, above the platform's page: a padlock, the main frame's host, and close.
/// Each colour is a semantic one set on its view, so the bar reads in light and dark whatever the app sets.
final class TreeHostBar: UIView {
    let host = UILabel()
    var hostText: String { host.text ?? "" }

    init(onClose: @escaping () -> Void) {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
        lock.tintColor = .secondaryLabel
        host.font = .preferredFont(forTextStyle: .subheadline)
        host.adjustsFontForContentSizeCategory = true
        host.textColor = .label
        host.lineBreakMode = .byTruncatingHead // a long host keeps its end, the part that names the site
        // A glyph in the host's colour, at its own size in the 44 pt target: the system's close button
        // stretches its grey disc to fill its frame.
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)), for: .normal)
        close.tintColor = .label
        close.accessibilityLabel = "Close"
        close.addAction(UIAction { _ in onClose() }, for: .touchUpInside)
        let row = UIStackView(arrangedSubviews: [lock, host, close])
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The 44 pt target sets the bar's height.
            close.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            close.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        // Only the host stretches or gives way: the padlock and close keep their own widths.
        host.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ h: String) {
        host.text = h
        host.accessibilityLabel = h.isEmpty ? nil : "Site, \(h)"
    }
}

/// The platform's page under its host bar. The page is covered while the screen is captured or the app is
/// not active (the app switcher's snapshot is taken then); the bar, which names no secret, and its Close stay.
final class TreePageController: UIViewController {
    let bar: TreeHostBar
    /// Over the WebView only, and it takes the page's taps.
    let cover = UIView()
    let note = UILabel()
    private let web: WKWebView
    private var resigned = false
    /// Whether the screen the page is on is recorded or mirrored (the main screen's before the page is in a
    /// window); tests stand in for it.
    lazy var isCaptured: () -> Bool = { [unowned self] in (view.window?.windowScene?.screen ?? UIScreen.main).isCaptured }

    init(web: WKWebView, onClose: @escaping () -> Void) {
        self.web = web
        self.bar = TreeHostBar(onClose: onClose)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView(arrangedSubviews: [bar, web])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        note.text = "The sign-in is hidden while the screen is recorded."
        note.textAlignment = .center
        note.numberOfLines = 0
        note.font = .preferredFont(forTextStyle: .body)
        note.adjustsFontForContentSizeCategory = true
        note.textColor = .label
        note.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(note)
        cover.backgroundColor = .systemBackground
        cover.isHidden = true
        cover.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cover)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: web.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: web.trailingAnchor),
            cover.topAnchor.constraint(equalTo: web.topAnchor),
            cover.bottomAnchor.constraint(equalTo: web.bottomAnchor),
            note.leadingAnchor.constraint(equalTo: cover.readableContentGuide.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: cover.readableContentGuide.trailingAnchor),
            note.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
        ])
        let c = NotificationCenter.default
        for name in [UIScreen.capturedDidChangeNotification, UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
            c.addObserver(self, selector: #selector(changed), name: name, object: nil)
        }
        updateCover(captured: isCaptured())
    }

    @objc private func changed(_ n: Notification) {
        if n.name == UIApplication.willResignActiveNotification { resigned = true }
        if n.name == UIApplication.didBecomeActiveNotification { resigned = false }
        updateCover(captured: isCaptured())
    }

    /// Covers the page while `captured`, and while the app is not active. A capture also takes the keyboard
    /// down: it is drawn above the app, so a recording would show each key typed and what QuickType offers.
    /// The page needs the user's tap to bring it back.
    func updateCover(captured: Bool) {
        if captured { view.endEditing(true) }
        let covering = captured || resigned
        let covered = !cover.isHidden
        if covering == covered { return }
        cover.isHidden = !covering
        web.accessibilityElementsHidden = covering // VoiceOver reads the bar and the note, not the page
        UIAccessibility.post(notification: .screenChanged, argument: covering ? note : nil)
    }
}
