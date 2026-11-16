import CoreImage
import UIKit

/// The pages' colors: Cr3dentials' (frame's globals.css).
enum Ink {
    static let paper = UIColor(hex: 0xF7F9FC)
    static let ink = UIColor(hex: 0x111827)
    static let ink2 = UIColor(hex: 0x374151)
    static let muted = UIColor(hex: 0x6B7280)
    static let hair = UIColor(hex: 0xE5E9F0)
    static let brand = UIColor(hex: 0x2320D6)
    static let tint = UIColor(hex: 0xE7E7FB)
    static let pressed = UIColor(red: 35 / 255, green: 32 / 255, blue: 214 / 255, alpha: 0.06)
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

/// The pages' icons, each drawn in its own viewport.
enum PageIcon {
    case check, tick, chevron

    /// The viewport's side and the stroke's width in it.
    var viewport: CGFloat { self == .tick ? 18 : 24 }
    var stroke: CGFloat { self == .check ? 2.2 : 2 }

    var path: UIBezierPath {
        let p = UIBezierPath()
        switch self {
        case .check:
            p.move(to: CGPoint(x: 20, y: 6))
            p.addLine(to: CGPoint(x: 9, y: 17))
            p.addLine(to: CGPoint(x: 4, y: 12))
        case .tick:
            p.move(to: CGPoint(x: 5, y: 9.3))
            p.addLine(to: CGPoint(x: 7.7, y: 12.2))
            p.addLine(to: CGPoint(x: 13, y: 6.4))
        case .chevron:
            p.move(to: CGPoint(x: 9, y: 6))
            p.addLine(to: CGPoint(x: 15, y: 12))
            p.addLine(to: CGPoint(x: 9, y: 18))
        }
        return p
    }
}

/// One of the pages' icons, `side` points square, stroked in `color`; a screen reader skips it.
final class IconView: UIView {
    let icon: PageIcon
    private let shape = CAShapeLayer()

    init(_ icon: PageIcon, color: UIColor, side: CGFloat) {
        self.icon = icon
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        isAccessibilityElement = false
        isUserInteractionEnabled = false
        shape.fillColor = nil
        shape.strokeColor = color.cgColor
        shape.lineCap = .round
        shape.lineJoin = .round
        layer.addSublayer(shape)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = bounds.width / icon.viewport
        let path = icon.path
        // The chevron points forward, which in a right-to-left layout is left; a check is the same either way.
        if icon == .chevron, effectiveUserInterfaceLayoutDirection == .rightToLeft {
            path.apply(CGAffineTransform(translationX: icon.viewport, y: 0).scaledBy(x: -1, y: 1))
        }
        path.apply(CGAffineTransform(scaleX: scale, y: scale))
        shape.frame = bounds
        shape.path = path.cgPath
        shape.lineWidth = icon.stroke * scale
    }
}

/// `text` in the system font at `size` and `weight`, scaled with the user's text size, each line `line` points tall
/// when given (scaled too), aligned as `align`.
func pageLabel(
    _ text: String, size: CGFloat, color: UIColor, weight: UIFont.Weight = .regular, line: CGFloat = 0,
    align: NSTextAlignment = .natural, kern: CGFloat = 0
) -> UILabel {
    let l = UILabel()
    let font = UIFontMetrics.default.scaledFont(for: .systemFont(ofSize: size, weight: weight))
    l.font = font
    l.adjustsFontForContentSizeCategory = true
    l.numberOfLines = 0
    l.textColor = color
    l.textAlignment = align
    let p = NSMutableParagraphStyle()
    p.alignment = align
    if line > 0 {
        // The system font's own line is about 1.2 of its size.
        p.lineHeightMultiple = line / (size * 1.2)
    }
    var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: p, .font: font, .foregroundColor: color]
    if kern != 0 { attributes[.kern] = kern }
    l.attributedText = NSAttributedString(string: text, attributes: attributes)
    return l
}

/// A heading's words, 15 points and semibold.
func pageHeading(_ text: String) -> UILabel {
    let l = pageLabel(text, size: 15, color: Ink.ink, weight: .semibold, line: 20)
    l.accessibilityTraits = .header
    return l
}

/// A 1 point rule.
func hairline() -> UIView {
    let v = UIView()
    v.backgroundColor = Ink.hair
    v.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return v
}

/// `image` without its color.
private func greyscale(_ image: UIImage) -> UIImage {
    guard let ci = CIImage(image: image), let f = CIFilter(name: "CIColorControls") else { return image }
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(0, forKey: kCIInputSaturationKey)
    guard let out = f.outputImage, let cg = CIContext().createCGImage(out, from: out.extent) else { return image }
    return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
}

/// A platform's logo, `side` points square and decorative (its name is next to it): the bundled one, or a tile with
/// its first letter. A `dim` one is grey and faded, as a row that can't be verified.
func platformLogo(_ name: String, side: CGFloat, dim: Bool = false) -> UIView {
    let view: UIView
    if let image = PlatformLogos.image(for: name) {
        let v = UIImageView(image: dim ? greyscale(image) : image)
        v.contentMode = .scaleAspectFit
        view = v
    } else {
        let tile = UIView()
        tile.backgroundColor = Ink.tint
        tile.layer.cornerRadius = side / 4
        let letter = UILabel()
        letter.text = name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? ""
        letter.font = .systemFont(ofSize: side * 0.5, weight: .semibold)
        letter.textColor = Ink.brand
        letter.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(letter)
        NSLayoutConstraint.activate([
            letter.centerXAnchor.constraint(equalTo: tile.centerXAnchor), letter.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        view = tile
    }
    view.isAccessibilityElement = false
    view.isUserInteractionEnabled = false
    if dim { view.alpha = 0.5 }
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: side), view.heightAnchor.constraint(equalToConstant: side)])
    return view
}

/// The footer: `text` in small muted words with Cr3dentials' flower before its name, which is in bold ("Powered by",
/// the flower, "Cr3dentials"). Words without the name get the flower first. Read as `text`.
func poweredBy(_ text: String) -> UIView {
    let brand = "Cr3dentials"
    let row = UIStackView()
    row.spacing = 6
    row.alignment = .center
    let flower = UIImageView(image: PlatformLogos.mark)
    flower.contentMode = .scaleAspectFit
    flower.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([flower.widthAnchor.constraint(equalToConstant: 13), flower.heightAnchor.constraint(equalToConstant: 14)])
    if let at = text.range(of: brand) {
        let before = text[..<at.lowerBound].trimmingCharacters(in: .whitespaces)
        if !before.isEmpty { row.addArrangedSubview(pageLabel(before, size: 13, color: Ink.muted)) }
        row.addArrangedSubview(flower)
        row.addArrangedSubview(pageLabel(brand, size: 13, color: Ink.ink2, weight: .semibold))
        let after = String(text[at.upperBound...])
        if !after.trimmingCharacters(in: .whitespaces).isEmpty { row.addArrangedSubview(pageLabel(after, size: 13, color: Ink.muted)) }
    } else {
        row.addArrangedSubview(flower)
        row.addArrangedSubview(pageLabel(text, size: 13, color: Ink.muted))
    }
    row.isAccessibilityElement = true
    row.accessibilityLabel = text
    // Laid out in the words' own direction, not the layout's: an untranslated footer on a right-to-left device
    // would otherwise come out back to front.
    if let language = NSLinguisticTagger.dominantLanguage(for: text) {
        row.semanticContentAttribute = Locale.characterDirection(forLanguage: language) == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
    }
    let centered = UIStackView(arrangedSubviews: [row])
    centered.axis = .vertical
    centered.alignment = .center
    return centered
}

/// A filled pill, 52 points tall: brand and white; grey, with muted words, while disabled.
final class PillButton: UIControl {
    let title: String
    private let label: UILabel
    private let spinner = UIActivityIndicatorView(style: .medium)
    /// Busy: brand still, a spinner before the words, and not tappable.
    private(set) var isBusy = false

    init(_ title: String) {
        self.title = title
        label = pageLabel(title, size: 16, color: .white, weight: .semibold, align: .center)
        super.init(frame: .zero)
        layer.cornerRadius = 26
        isAccessibilityElement = true
        accessibilityLabel = title
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            // The words hug themselves, centered, with room at the start for the spinner beside them.
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 50),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            label.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -10),
        ])
        paint()
    }

    /// Working: `words` with a spinner before them, in brand still, and no longer tappable. Read as `words`, busy.
    func busy(_ words: String) {
        isBusy = true
        label.attributedText = pageLabel(words, size: 16, color: .white, weight: .semibold, align: .center).attributedText
        accessibilityLabel = words
        spinner.startAnimating()
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool { didSet { paint() } }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.85 : 1 } }

    /// 52 points, or the words' height with 12 above and below: a control has no size of its own, and a stack would
    /// give one without any all the space left over.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: max(52, label.intrinsicContentSize.height + 24))
    }

    private func paint() {
        let lit = isEnabled || isBusy
        backgroundColor = lit ? Ink.brand : Ink.hair
        label.textColor = lit ? .white : Ink.muted
        isUserInteractionEnabled = !isBusy
        accessibilityTraits = isEnabled && !isBusy ? .button : [.button, .notEnabled]
    }
}

/// A checkbox, Material's: a 20 point square with a 2 point muted border; checked, filled with brand and ticked in
/// white. Its touch area is 44 points, as Apple asks.
final class Checkbox: UIControl {
    private let box = UIView()
    private let tick = IconView(.tick, color: .white, side: 18)
    var onChange: (() -> Void)?

    var isChecked = false {
        didSet {
            box.backgroundColor = isChecked ? Ink.brand : Ink.paper
            box.layer.borderColor = (isChecked ? Ink.brand : Ink.muted).cgColor
            tick.isHidden = !isChecked
            // VoiceOver reads "selected" for a checked box; a bare value would be read as "1" or "0".
            accessibilityTraits = isChecked ? [.button, .selected] : .button
        }
    }

    init(label: String) {
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityLabel = label
        box.layer.cornerRadius = 3
        box.layer.borderWidth = 2
        box.isUserInteractionEnabled = false
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        box.addSubview(tick)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 20), box.heightAnchor.constraint(equalToConstant: 20),
            box.leadingAnchor.constraint(equalTo: leadingAnchor), box.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            tick.centerXAnchor.constraint(equalTo: box.centerXAnchor), tick.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            widthAnchor.constraint(equalToConstant: 20), heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])
        isChecked = false
        addTarget(self, action: #selector(toggled), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -12, dy: -11).contains(point)
    }

    /// Its words' tap calls this too, so a disabled box (the consent accepted) stays as it is here.
    @objc func toggled() {
        guard isEnabled else { return }
        isChecked.toggle()
        onChange?()
    }
}

/// A row of the platform list, 76 points tall, or taller when its words wrap: the platform's logo, its name and the line under it, and how
/// it ended. Tappable when the user may run it.
final class PlatformRowControl: UIControl {
    let row: PlatformList.Row
    private let names = UIStackView()

    init(_ row: PlatformList.Row) {
        self.row = row
        super.init(frame: .zero)
        let failed = row.state == .failed
        isAccessibilityElement = true
        accessibilityLabel = [row.name, row.status, row.detail].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = row.available ? .button : .staticText
        isEnabled = row.available

        names.addArrangedSubview(pageLabel(row.name, size: 18, color: failed ? Ink.muted : Ink.ink, weight: .medium, line: 24))
        names.axis = .vertical
        names.spacing = 2
        if let detail = row.detail { names.addArrangedSubview(pageLabel(detail, size: 14, color: Ink.muted, line: 18)) }
        // Never squeezed: the row grows past 76 for them instead.
        for l in names.arrangedSubviews { l.setContentCompressionResistancePriority(.required, for: .vertical) }

        let end = UIStackView()
        end.spacing = 6
        end.alignment = .center
        if let status = row.status {
            let words = failed ? pageLabel(status, size: 15, color: Ink.muted) : pageLabel(status, size: 15, color: Ink.brand, weight: .medium)
            words.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            words.setContentCompressionResistancePriority(UILayoutPriority(751), for: .horizontal)
            end.addArrangedSubview(words)
        }
        if row.state == .verified {
            let dot = UIView()
            dot.backgroundColor = Ink.brand
            dot.layer.cornerRadius = 10
            let tick = IconView(.check, color: .white, side: 12)
            dot.addSubview(tick)
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 20), dot.heightAnchor.constraint(equalToConstant: 20),
                tick.centerXAnchor.constraint(equalTo: dot.centerXAnchor), tick.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            ])
            end.addArrangedSubview(dot)
        }
        if row.available { end.addArrangedSubview(IconView(.chevron, color: Ink.brand, side: 18)) }

        // Laid out by hand, not in a stack: a stack holding two columns of words caps each at half its width, and
        // the words at the end would take the rest and drift from the edge. The logo at the start, the words at the
        // end against the edge, and the names between them, which wrap when the row is short of room.
        let logo = platformLogo(row.name, side: 32, dim: failed)
        for v in [logo, names, end] {
            v.isUserInteractionEnabled = false
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        // 76 tall unless the names need more: a wish just short of required, so the names' room (required) can
        // override it, and the page's spacer, not the row, takes any height left over.
        let tall = heightAnchor.constraint(equalToConstant: 76)
        tall.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: leadingAnchor), logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            end.trailingAnchor.constraint(equalTo: trailingAnchor), end.centerYAnchor.constraint(equalTo: centerYAnchor),
            names.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 16),
            end.leadingAnchor.constraint(equalTo: names.trailingAnchor, constant: 16),
            // Short of width (large text), the words at the end take at most 45% and wrap; the names keep the rest
            // and wrap too, each at its words, neither starving the other.
            end.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.45),
            names.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            bottomAnchor.constraint(greaterThanOrEqualTo: names.bottomAnchor, constant: 8),
            names.centerYAnchor.constraint(equalTo: centerYAnchor),
            tall,
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Outside a stack, a label is told the width it wraps at; otherwise its height stays that of one line.
        for case let l as UILabel in names.arrangedSubviews where l.preferredMaxLayoutWidth != names.bounds.width {
            l.preferredMaxLayoutWidth = names.bounds.width
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? Ink.pressed : nil }
    }
}

/// A full-screen page on the stage (`StageController`), which answers once: by the user, or, when the stage goes
/// away under it, as `none`. It leaves nothing to dismiss: the stage shows the next page in its place.
class WebPage: UIViewController, Shown {
    private var gone = false
    /// The partner's logo, from the app's theme.
    let logo: UIImage?
    /// The width of the screen it is shown on, for the title's size on a small one.
    let width: CGFloat
    let scroll = UIScrollView()
    /// The column's inset from the screen's sides: none on a phone, half the width over 560 on a tablet.
    private var sides: [NSLayoutConstraint] = []

    init(logo: UIImage?, width: CGFloat) {
        self.logo = logo
        self.width = width
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    /// The bar on top: the partner's logo at the start, 32 points tall and at most 160 wide, and `end` (the consent
    /// screen's Cancel) at the end.
    func topBar(end: UIView?) -> UIView {
        let bar = UIStackView()
        bar.alignment = .center
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 12)
        bar.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        if let logo {
            let v = UIImageView(image: logo)
            v.contentMode = .scaleAspectFit
            v.isAccessibilityElement = false
            v.translatesAutoresizingMaskIntoConstraints = false
            let ratio = logo.size.height > 0 ? logo.size.width / logo.size.height : 1
            let wide = v.widthAnchor.constraint(equalTo: v.heightAnchor, multiplier: ratio)
            wide.priority = .defaultHigh
            NSLayoutConstraint.activate([v.heightAnchor.constraint(equalToConstant: 32), v.widthAnchor.constraint(lessThanOrEqualToConstant: 160), wide])
            bar.addArrangedSubview(v)
        }
        let gap = UIView()
        let none = gap.widthAnchor.constraint(equalToConstant: 0)
        none.priority = UILayoutPriority(1)
        none.isActive = true
        bar.addArrangedSubview(gap)
        if let end { bar.addArrangedSubview(end) }
        return bar
    }

    /// The page, scrolling on the paper under the system bars: `top`, `body` (24 points at its sides, its sections
    /// 24 apart), and `foot` at the bottom of the screen, or after the body when that is taller. At most 560 points
    /// wide, so a tablet keeps a phone's line length.
    func layOut(top: UIView, body: [UIView], foot: [UIView]) {
        view.backgroundColor = Ink.paper
        let content = UIStackView(arrangedSubviews: body)
        content.axis = .vertical
        content.spacing = 24
        content.isLayoutMarginsRelativeArrangement = true
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 0, trailing: 24)
        let bottom = UIStackView(arrangedSubviews: foot)
        bottom.axis = .vertical
        bottom.spacing = 14
        bottom.isLayoutMarginsRelativeArrangement = true
        bottom.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 24, bottom: 12, trailing: 24)
        let gap = UIView()
        let none = gap.heightAnchor.constraint(equalToConstant: 0)
        none.priority = UILayoutPriority(1)
        none.isActive = true
        let column = UIStackView(arrangedSubviews: [top, content, gap, bottom])
        column.axis = .vertical

        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(column)
        let safe = view.safeAreaLayoutGuide
        let frame = scroll.frameLayoutGuide
        let inside = scroll.contentLayoutGuide
        // The column spans the screen, inset on each side by `sides` (set at layout): every constraint required, so
        // the width is never left to the stack's own guesses.
        sides = [
            column.leadingAnchor.constraint(equalTo: inside.leadingAnchor), inside.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ]
        NSLayoutConstraint.activate(sides + [
            scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: safe.topAnchor), scroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            inside.widthAnchor.constraint(equalTo: frame.widthAnchor),
            column.topAnchor.constraint(equalTo: inside.topAnchor), column.bottomAnchor.constraint(equalTo: inside.bottomAnchor),
            column.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset = max(0, (scroll.bounds.width - 560) / 2)
        for c in sides where c.constant != inset { c.constant = inset }
    }

    /// A cancel of the caller: the page answers `none`; the stage goes with the verification.
    func close() { leave() }

    /// Whether it still waits on the user's answer.
    var isWaiting: Bool { !gone }

    /// The page has answered, or is abandoned: `answered` gives its answer, once.
    func leave() {
        guard !gone else { return }
        gone = true
        answered()
    }

    /// Gives the page's answer, or its `none`. Called once.
    func answered() {}
}

/// The platform list: the partner's logo on top, the title and the line under it, a row per platform, the privacy
/// line, Done and the footer. A row the user may run answers its index; Done answers nil. A verified or failed row
/// says so and does nothing.
final class ListPage: WebPage {
    let list: PlatformList
    private var reply: ((ListPage, Int?) -> Void)?
    private var picked: Int?
    private(set) var rows: [PlatformRowControl] = []
    let doneButton: PillButton

    init(list: PlatformList, logo: UIImage?, width: CGFloat, reply: @escaping (ListPage, Int?) -> Void) {
        self.list = list
        self.reply = reply
        doneButton = PillButton(list.done)
        super.init(logo: logo, width: width)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let title = pageLabel(list.title, size: 28, color: Ink.ink, weight: .semibold, line: 34, kern: -0.28)
        title.accessibilityTraits = .header
        let head = UIStackView(arrangedSubviews: [title, pageLabel(list.subtitle, size: 16, color: Ink.ink2, line: 24)])
        head.axis = .vertical
        head.spacing = 8

        let table = UIStackView(arrangedSubviews: [hairline()])
        table.axis = .vertical
        table.isLayoutMarginsRelativeArrangement = true
        table.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0)
        for (i, row) in list.rows.enumerated() {
            let r = PlatformRowControl(row)
            r.tag = i
            r.addTarget(self, action: #selector(tappedRow(_:)), for: .touchUpInside)
            rows.append(r)
            table.addArrangedSubview(r)
            table.addArrangedSubview(hairline())
        }

        doneButton.addTarget(self, action: #selector(tappedDone), for: .touchUpInside)
        layOut(
            top: topBar(end: nil),
            body: [head, table, pageLabel(list.privacy, size: 15, color: Ink.muted, line: 22)],
            foot: [doneButton, poweredBy(list.footer)])
    }

    @objc private func tappedRow(_ r: PlatformRowControl) {
        guard r.row.available else { return }
        picked = r.tag
        leave()
    }

    /// Done ends the verification, which tells our backend first (up to 10 seconds): the list says it is working
    /// and takes no more taps until the stage goes.
    @objc private func tappedDone() {
        doneButton.busy(list.working)
        for r in rows { r.isEnabled = false }
        leave()
    }

    override func answered() {
        let r = reply
        reply = nil
        r?(self, picked)
    }
}

/// A platform's consent screen: the partner's logo and Cancel (which answers false) on top; the platform's logo, the
/// title and the subtitle, centered; what will be verified; the privacy words and "how this works"; the two
/// checkboxes; the button (enabled once both are checked, which answers true) and the footer.
final class ConsentPage: WebPage, UITextViewDelegate {
    let screen: ConsentScreen
    private var reply: ((ConsentPage, Bool) -> Void)?
    private var accepted = false
    let closeButton = UIButton(type: .system)
    let authorize: Checkbox
    let agree: Checkbox
    let continueButton: PillButton
    let howToggle = UIButton(type: .system)
    private(set) lazy var howBody = pageLabel(screen.consent.howThisWorksBody, size: 15, color: Ink.muted, line: 22)
    let terms = UITextView()

    init(screen: ConsentScreen, logo: UIImage?, width: CGFloat, reply: @escaping (ConsentPage, Bool) -> Void) {
        self.screen = screen
        self.reply = reply
        authorize = Checkbox(label: screen.consent.authConsentLabel)
        agree = Checkbox(label: screen.agree)
        continueButton = PillButton(screen.consent.cta)
        super.init(logo: logo, width: width)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let s = screen.consent
        closeButton.setTitle(screen.close, for: .normal)
        closeButton.titleLabel?.font = UIFontMetrics.default.scaledFont(for: .systemFont(ofSize: 16, weight: .medium))
        closeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        closeButton.tintColor = Ink.brand
        closeButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.addTarget(self, action: #selector(tappedClose), for: .touchUpInside)

        let small = width > 0 && width < 360
        let title = pageLabel(
            s.title, size: small ? 23 : 26, color: Ink.ink, weight: .semibold, line: small ? 28 : 32, align: .center, kern: small ? -0.23 : -0.26)
        title.accessibilityTraits = .header
        let subtitle = pageLabel(s.subtitle, size: 16, color: Ink.ink2, line: 24, align: .center)
        // The words span the column, so they wrap, and are centered in it; the subtitle keeps a phone's line length.
        let hero = UIStackView(arrangedSubviews: [centered(platformLogo(screen.name, side: 48)), title, centered(subtitle, upTo: 300)])
        hero.axis = .vertical
        hero.alignment = .fill
        hero.spacing = 12
        hero.isLayoutMarginsRelativeArrangement = true
        hero.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0)

        let items = UIStackView(arrangedSubviews: [pageHeading(screen.itemsTitle)])
        items.axis = .vertical
        items.spacing = 10
        for item in s.verificationItems { items.addArrangedSubview(bullet(item)) }

        howToggle.contentHorizontalAlignment = .leading
        howToggle.tintColor = Ink.brand
        howToggle.titleLabel?.adjustsFontForContentSizeCategory = true
        howToggle.titleLabel?.numberOfLines = 0
        howToggle.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        howToggle.addTarget(self, action: #selector(toggledHow), for: .touchUpInside)
        showHow(false)
        let privacy = UIStackView(arrangedSubviews: [
            pageHeading(s.privacyTitle), pageLabel(s.privacyBody, size: 15, color: Ink.muted, line: 22), howToggle, howBody,
        ])
        privacy.axis = .vertical
        privacy.spacing = 10
        privacy.setCustomSpacing(4, after: privacy.arrangedSubviews[1])
        privacy.setCustomSpacing(0, after: howToggle)

        let authorizeRow = checkboxRow(authorize, pageLabel(s.authConsentLabel, size: 15, color: Ink.ink2, line: 22))
        terms.attributedText = agreeText()
        terms.isEditable = false
        terms.isScrollEnabled = false
        terms.backgroundColor = .clear
        terms.textContainerInset = .zero
        terms.textContainer.lineFragmentPadding = 0
        terms.linkTextAttributes = [.foregroundColor: Ink.brand, .underlineStyle: NSUnderlineStyle.single.rawValue]
        terms.adjustsFontForContentSizeCategory = true
        let agreements = UIStackView(arrangedSubviews: [authorizeRow, checkboxRow(agree, terms)])
        agreements.axis = .vertical
        agreements.spacing = 8

        for box in [authorize, agree] { box.onChange = { [weak self] in self?.update() } }
        continueButton.addTarget(self, action: #selector(tappedContinue), for: .touchUpInside)
        update()

        layOut(
            top: topBar(end: closeButton),
            body: [hero, items, privacy, hairline(), agreements],
            foot: [continueButton, poweredBy(s.footer)])
    }

    /// `view` centered in a view as wide as the column, and at most `upTo` wide when given.
    private func centered(_ view: UIView, upTo: CGFloat? = nil) -> UIView {
        let box = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        var constraints = [
            view.centerXAnchor.constraint(equalTo: box.centerXAnchor), view.topAnchor.constraint(equalTo: box.topAnchor),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor), view.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor),
        ]
        if let upTo {
            let full = view.widthAnchor.constraint(equalTo: box.widthAnchor)
            full.priority = .defaultHigh
            constraints += [view.widthAnchor.constraint(lessThanOrEqualToConstant: upTo), full]
        }
        NSLayoutConstraint.activate(constraints)
        return box
    }

    /// A bullet: a brand check, and the item.
    private func bullet(_ item: String) -> UIView {
        let check = IconView(.check, color: Ink.brand, side: 16)
        let mark = UIView()
        mark.addSubview(check)
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 16), mark.heightAnchor.constraint(equalToConstant: 19),
            check.leadingAnchor.constraint(equalTo: mark.leadingAnchor), check.topAnchor.constraint(equalTo: mark.topAnchor, constant: 3),
        ])
        let row = UIStackView(arrangedSubviews: [mark, pageLabel(item, size: 16, color: Ink.ink, line: 22)])
        row.spacing = 12
        row.alignment = .top
        return row
    }

    /// A checkbox and its words, 48 points tall at least: a tap on a label's words checks the box too (the Terms
    /// line's words are its links', as on Android).
    private func checkboxRow(_ box: Checkbox, _ words: UIView) -> UIView {
        let row = UIStackView(arrangedSubviews: [box, words])
        row.spacing = 14
        row.alignment = .top
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        if words is UILabel {
            words.isUserInteractionEnabled = true
            words.addGestureRecognizer(UITapGestureRecognizer(target: box, action: #selector(Checkbox.toggled)))
        }
        return row
    }

    /// The second checkbox's line, its Terms and Privacy labels linked.
    private func agreeText() -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 22 / (15 * 1.2)
        let text = NSMutableAttributedString(string: screen.agree, attributes: [
            .font: UIFontMetrics.default.scaledFont(for: .systemFont(ofSize: 15)), .foregroundColor: Ink.ink2, .paragraphStyle: p,
        ])
        for link in screen.links {
            let at = (screen.agree as NSString).range(of: link.label)
            if at.location != NSNotFound, let url = URL(string: link.url) { text.addAttribute(.link, value: url, range: at) }
        }
        return text
    }

    /// "How this works" after the web's + or −, the words underlined, and its body shown or not.
    private func showHow(_ open: Bool) {
        let s = screen.consent
        let font = UIFontMetrics.default.scaledFont(for: .systemFont(ofSize: 15, weight: .medium))
        let title = NSMutableAttributedString(string: open ? "−  " : "+  ", attributes: [.font: font, .foregroundColor: Ink.brand])
        title.append(NSAttributedString(string: open ? s.hideHowThisWorksLabel : s.showHowThisWorksLabel, attributes: [
            .font: font, .foregroundColor: Ink.brand, .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]))
        howToggle.setAttributedTitle(title, for: .normal)
        howBody.isHidden = !open
    }

    private func update() { continueButton.isEnabled = authorize.isChecked && agree.isChecked }

    @objc private func toggledHow() { showHow(howBody.isHidden) }

    @objc private func tappedContinue() {
        guard authorize.isChecked && agree.isChecked else { return }
        accepted = true
        // The page stays on the stage behind the platform's page and shows again during the hand-off: it says
        // what is happening, and nothing on it is left to change.
        continueButton.busy(screen.working)
        closeButton.isHidden = true
        for box in [authorize, agree] { box.isEnabled = false }
        for v in [authorize, agree, howToggle, terms] as [UIView] { v.isUserInteractionEnabled = false }
        leave()
    }

    @objc private func tappedClose() { leave() }

    override func answered() {
        let r = reply
        reply = nil
        r?(self, accepted)
    }
}

/// The stage: one full-screen controller, presented over the app at the first page and taken down when the
/// verification ends, with the page in turn as its child. Nothing of the app shows between pages, and the
/// platform's sign-in page is presented over it. Gone for good (dismissed by us or by the app), it has the page up
/// answer `none`; covered by the sign-in page, it does nothing.
final class StageController: UIViewController {
    /// The page up now.
    private(set) var current: WebPage?
    /// What presented it, which takes it down.
    weak var from: UIViewController?
    /// Runs once it has gone for good.
    var onGone: (() -> Void)?
    /// Runs when it goes with a page still waiting on the user: no answer of theirs.
    var onLost: (() -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.paper
    }

    /// `page` in place of the one up, which is removed once the new one is in: no moment with nothing shown.
    func show(_ page: WebPage) {
        let old = current
        current = page
        addChild(page)
        page.view.frame = view.bounds
        page.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(page.view)
        page.didMove(toParent: self)
        if let old {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { gone() }
    }

    /// Gone for good: the page up answers `none`, and `onGone` runs, once. A page still waiting (the app dismissed
    /// the stage, or UIKit refused it) runs `onLost` first, which ends the verification, so its `none` is never read
    /// as the user's Done or decline. Ours at the end closes the pages first.
    func gone() {
        if current?.isWaiting == true { onLost?() }
        current?.leave()
        let g = onGone
        onGone = nil
        g?()
    }
}
