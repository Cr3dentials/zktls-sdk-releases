import UIKit

/// The look of the SDK's screens, passed to `Zktls.configure(appKey:theme:strings:)`. The layout is fixed; you
/// set the colours and the logo. Each has the system's own look until you set it.
public struct ZktlsTheme {
    /// The buttons' colour.
    public var accent: UIColor
    /// The screens' background.
    public var background: UIColor
    /// The titles' and the text's colour.
    public var text: UIColor
    /// An image shown at the top of every screen.
    public var logo: UIImage?

    /// A theme. Each argument left out keeps the system's look: its blue buttons, its background and label
    /// colours, and no logo.
    public init(accent: UIColor = .systemBlue, background: UIColor = .systemBackground, text: UIColor = .label, logo: UIImage? = nil) {
        self.accent = accent
        self.background = background
        self.text = text
        self.logo = logo
    }
}

// Colours and images do not change once made.
extension ZktlsTheme: @unchecked Sendable {}
