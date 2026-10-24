import UIKit

/// What shows the screens: view controllers over the app's own on a device, a script in tests.
protocol ScreenPresenter: AnyObject {
    /// Shows `screen` until the user answers: true for its accept button; false for its decline button, a tap
    /// outside it, a screen that went away, or one that could not be shown. A cancel of the caller takes the
    /// screen down and answers false.
    func ask(_ screen: VerifyScreen) async -> Bool

    /// Takes down every screen still up, each answering false: the verification is over.
    func dismissAll()
}

/// A screen that is up, which a cancel takes down.
protocol Shown: AnyObject, Sendable {
    /// Takes it down.
    func close()
}

/// One screen's answer: the first of the user's reply, a cancel and a screen not shown, the last two false.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var shown: Shown?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func wait(_ c: CheckedContinuation<Bool, Never>) {
        lock.lock()
        guard let r = result else {
            waiter = c
            lock.unlock()
            return
        }
        lock.unlock()
        c.resume(returning: r)
    }

    func reply(_ answer: Bool) {
        lock.lock()
        guard result == nil else { return lock.unlock() }
        result = answer
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: answer)
    }

    /// Keeps `s` for a cancel to take down; false when the caller has already given up.
    func keep(_ s: Shown) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !cancelled { shown = s }
        return !cancelled
    }

    /// The caller gave up: false, and the screen up, if any, to take down.
    func cancel() -> Shown? {
        lock.lock()
        cancelled = true
        let s = shown
        shown = nil
        lock.unlock()
        reply(false)
        return s
    }
}

/// The answer to one screen. `show` runs through `ui` (the main queue) and puts the screen up, handing it the
/// callback for its answer, of which only the first counts; it returns nil when it cannot show the screen,
/// which answers false. When the caller is cancelled first, the screen is taken down, through `ui` too, or
/// never put up.
func answered(
    ui: @escaping (@escaping @Sendable () -> Void) -> Void, show: @escaping @Sendable (_ answer: @escaping @Sendable (Bool) -> Void) -> Shown?
) async -> Bool {
    let a = FirstAnswer()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { c in
            a.wait(c)
            ui {
                guard !a.isCancelled else { return }
                guard let shown = show({ a.reply($0) }) else { return a.reply(false) }
                if !a.keep(shown) { shown.close() }
            }
        }
    } onCancel: {
        if let s = a.cancel() { ui { s.close() } }
    }
}

/// Has `from` dismiss what it presents, then runs `done`, once: UIKit refuses a new presentation while a
/// dismissal is in flight, so the next screen or page waits for it. After 2 s `done` runs anyway, in case
/// UIKit never calls back: a `verify` that waited for ever would hold every later one.
@MainActor func dismissPresented(by from: UIViewController, then done: @escaping () -> Void) {
    var ran = false
    let once = {
        guard !ran else { return }
        ran = true
        done()
    }
    from.dismiss(animated: true, completion: once)
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        once()
    }
}

/// The app's key window's root view controller, which the screens and pages are shown over.
@MainActor func keyWindowRoot() -> UIViewController? {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
}

/// The screens as view controllers presented over the app's top-most one, which `top` finds the root of: the
/// SDK has no window of its own. Each is coloured by `theme`.
final class VerifyScreens: ScreenPresenter, @unchecked Sendable {
    private let theme: ZktlsTheme
    private let top: @MainActor () -> UIViewController?
    /// The screens up now. On the main thread only.
    private var open: [ScreenController] = []

    init(theme: ZktlsTheme, top: @escaping @MainActor () -> UIViewController? = keyWindowRoot) {
        self.theme = theme
        self.top = top
    }

    func ask(_ screen: VerifyScreen) async -> Bool {
        await answered(ui: { body in DispatchQueue.main.async(execute: body) }) { answer in
            MainActor.assumeIsolated { self.show(screen, answer) }
        }
    }

    func dismissAll() {
        DispatchQueue.main.async { self.open.forEach { $0.close() } }
    }

    /// On the main thread: `screen` over the top-most controller, or nil when there is none to show it over.
    @MainActor private func show(_ screen: VerifyScreen, _ answer: @escaping (Bool) -> Void) -> Shown? {
        guard var from = top() else { return nil }
        while let next = from.presentedViewController, !next.isBeingDismissed { from = next }
        let c = ScreenController(screen: screen, theme: theme, from: from) { [weak self] done, a in
            self?.open.removeAll { $0 === done }
            answer(a)
        }
        open.append(c)
        from.present(c, animated: true)
        return c
    }
}

/// One screen: a card over a dimmed backdrop with the logo, the title, the body and the list, and its buttons.
/// Its accept button answers true; its decline button, a tap outside the card, or its going away any other
/// way answers false. The first answer counts, and takes the screen down.
final class ScreenController: UIViewController, Shown {
    let screen: VerifyScreen
    private let theme: ZktlsTheme
    private weak var from: UIViewController?
    private var reply: ((ScreenController, Bool) -> Void)?

    let card = UIView()
    // Made with the view, so they take its traits (the text size) as the labels made then do.
    private(set) lazy var titleLabel = UILabel()
    private(set) lazy var bodyLabel = UILabel()
    let acceptButton = UIButton(type: .system)
    private(set) var declineButton: UIButton?
    private(set) var logoView: UIImageView?
    /// The buttons: side by side on the trailing edge, or one above the other at the accessibility text sizes.
    private let buttons = UIStackView(arrangedSubviews: [UIView()])

    init(screen: VerifyScreen, theme: ZktlsTheme, from: UIViewController, reply: @escaping (ScreenController, Bool) -> Void) {
        self.screen = screen
        self.theme = theme
        self.from = from
        self.reply = reply
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        let outside = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        outside.cancelsTouchesInView = false
        view.addGestureRecognizer(outside)

        card.backgroundColor = theme.background
        card.layer.cornerRadius = 14
        card.accessibilityViewIsModal = true
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        // The card's content scrolls when it is taller than the screen allows (the largest text sizes).
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        if let logo = theme.logo {
            // On the leading edge, at most 48 points high; a template image takes the accent.
            let v = UIImageView(image: logo)
            v.contentMode = .scaleAspectFit
            v.tintColor = theme.accent
            v.isAccessibilityElement = false
            v.heightAnchor.constraint(lessThanOrEqualToConstant: 48).isActive = true
            if logo.size.height > 0 {
                v.widthAnchor.constraint(equalTo: v.heightAnchor, multiplier: logo.size.width / logo.size.height).isActive = true
            }
            logoView = v
            stack.addArrangedSubview(UIStackView(arrangedSubviews: [v, UIView()]))
        }
        stack.addArrangedSubview(label(titleLabel, screen.title, .headline))
        if let body = screen.body { stack.addArrangedSubview(label(bodyLabel, body, .body)) }
        for item in screen.list { stack.addArrangedSubview(label(UILabel(), "•  \(item)", .body)) }

        // The buttons on the trailing edge, accept last.
        buttons.spacing = 16
        if let decline = screen.decline {
            let b = button(decline, #selector(declined), weight: .regular)
            declineButton = b
            buttons.addArrangedSubview(b)
        }
        buttons.addArrangedSubview(button(screen.accept, #selector(accepted), weight: .semibold, into: acceptButton))
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(20, after: last) }
        stack.addArrangedSubview(buttons)
        arrangeButtons()

        let safe = view.safeAreaLayoutGuide
        let content = scroll.contentLayoutGuide
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 24),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            card.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: 16),
            card.bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor, constant: -16),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
        ])
        // As wide as the screen allows, centred, and as tall as its content until the screen runs out.
        for c in [
            card.widthAnchor.constraint(equalTo: safe.widthAnchor, constant: -48),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ] {
            c.priority = .defaultHigh
            c.isActive = true
        }
        // Below the labels' compression resistance: past the screen's height, the content scrolls rather than
        // squeezing its text.
        let fit = scroll.frameLayoutGuide.heightAnchor.constraint(equalTo: content.heightAnchor)
        fit.priority = UILayoutPriority(UILayoutPriority.defaultHigh.rawValue - 1)
        fit.isActive = true
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        arrangeButtons()
    }

    private func arrangeButtons() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        buttons.axis = large ? .vertical : .horizontal
        buttons.alignment = large ? .trailing : .fill
        buttons.arrangedSubviews.first?.isHidden = large
    }

    /// `l` with `text` in `style`, coloured by the theme, wrapping and following Dynamic Type.
    private func label(_ l: UILabel, _ text: String, _ style: UIFont.TextStyle) -> UILabel {
        l.text = text
        l.font = .preferredFont(forTextStyle: style, compatibleWith: traitCollection)
        l.adjustsFontForContentSizeCategory = true
        l.numberOfLines = 0
        l.textColor = theme.text
        return l
    }

    private func button(_ title: String, _ action: Selector, weight: UIFont.Weight, into b: UIButton = UIButton(type: .system)) -> UIButton {
        b.setTitle(title, for: .normal)
        // Body text's size at the default text size, which the metrics scale to the user's.
        b.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: weight), compatibleWith: traitCollection)
        b.titleLabel?.adjustsFontForContentSizeCategory = true
        b.titleLabel?.numberOfLines = 0
        b.titleLabel?.textAlignment = .natural
        b.tintColor = theme.accent
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    @objc private func accepted() { answer(true) }
    @objc private func declined() { answer(false) }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        if !card.frame.contains(g.location(in: view)) { answer(false) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Taken down by something other than its answer (the app's own dismissal, say): a decline.
        answer(false)
    }

    /// Takes the screen down, answering false unless it has answered.
    func close() { answer(false) }

    /// The first answer, given once the screen has gone, so whatever follows it can be shown.
    private func answer(_ a: Bool) {
        guard let r = reply else { return }
        reply = nil
        guard let from, from.presentedViewController === self else { return r(self, a) }
        dismissPresented(by: from) { r(self, a) }
    }
}
