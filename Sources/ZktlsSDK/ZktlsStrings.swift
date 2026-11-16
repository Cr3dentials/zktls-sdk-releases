import Foundation

/// One of the SDK's screens, as words: a title, an optional body and list, the button that goes on, and the
/// one that declines (none on a screen that only closes).
struct VerifyScreen: Equatable {
    let title: String
    let body: String?
    let accept: String
    let decline: String?
    var list: [String] = []
}

/// The platform list, as words: its title and the line under it, one row per platform offered, the privacy line
/// under the rows, the button that ends the verification and what it says once tapped (`working`), and the footer.
struct PlatformList: Equatable {
    /// A platform: its name, its state, the words for it (`status`, nil while not run yet), and the line under its
    /// name (`detail`, only for one to try again).
    struct Row: Equatable {
        let name: String
        let state: PlatformRowState
        let status: String?
        var detail: String? = nil
        /// Whether the user may tap it: not run yet, backed out of, or to try again.
        var available: Bool { state == .available || state == .retry }
    }

    let title: String
    let subtitle: String
    let rows: [Row]
    let privacy: String
    let done: String
    let footer: String
    let working: String
}

/// A platform's consent screen: its `name`, as on the list, our backend's text, the second checkbox's `agree` line,
/// whose `links` (each a label in it and its `https://` address) open in the browser, the heading over the bullets
/// (`itemsTitle`), `close`, which declines it, and `working`, on the button once it is accepted, while the
/// platform's page opens and, after it, while the run is handed off.
struct ConsentScreen: Equatable {
    struct Link: Equatable {
        let label: String
        let url: String
    }

    let name: String
    let consent: Consent
    let agree: String
    let links: [Link]
    let itemsTitle: String
    let close: String
    let working: String
}

/// The words on the SDK's screens: English built in, and each key replaced by the `strings` passed to
/// `Zktls.configure`; a key the SDK does not use is ignored. The keys and the English are the same on Android.
/// Words in braces are filled in when a screen is made, in one pass, so a value that holds braces is shown as
/// it is.
struct ZktlsStrings {
    /// Every key the screens use, with its English, in the order the integration guides list them.
    static let english: [(String, String)] = [
        ("list.title", "Choose an account to verify"),
        ("list.subtitle", "Verify one or more, in any order."),
        ("list.verified", "Verified"),
        ("list.failed", "Couldn't be verified"),
        ("list.retry", "Try again"),
        ("list.retryDetail", "Couldn't connect. Nothing was shared."),
        ("list.privacy", "You sign in on your own phone. Your passwords and statements stay with you; only the facts needed are shared with this app."),
        ("list.done", "Done"),
        ("list.footer", "Powered by Cr3dentials"),
        ("consent.agree", "I agree to the {terms} and {privacy}."),
        ("consent.terms", "Terms of Service"),
        ("consent.privacy", "Privacy Policy"),
        ("consent.itemsTitle", "What we'll verify"),
        ("consent.close", "Cancel"),
        ("consent.working", "Finishing up…"),
        ("refusal.device", "This device can't be verified"),
        ("refusal.other", "Verification isn't available right now"),
        ("refusal.close", "Close"),
    ]

    private static let placeholder = try! NSRegularExpression(pattern: "\\{([a-z]+)\\}")

    private let words: [String: String]

    init(_ overrides: [String: String] = [:]) {
        var words = Dictionary(uniqueKeysWithValues: Self.english)
        // A blank value, or one that drops a word in braces its English has (the consent screen's {terms} and
        // {privacy} are its links), is ignored: the English stands.
        for (key, text) in overrides {
            guard let english = words[key], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let kept = Self.placeholder.matches(in: english, range: NSRange(english.startIndex..., in: english))
                .compactMap { Range($0.range, in: english).map { String(english[$0]) } }
                .allSatisfy(text.contains)
            if kept { words[key] = text }
        }
        self.words = words
    }

    /// The text for `key`, the app's own or the English.
    subscript(key: String) -> String { words[key] ?? "" }

    /// The text for `key` with each `{name}` of `values` filled in; any other braces stay.
    func fill(_ key: String, _ values: [String: String]) -> String { Self.fillIn(self[key], values) }

    private static func fillIn(_ text: String, _ values: [String: String]) -> String {
        var out = ""
        var last = text.startIndex
        for m in placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(m.range, in: text), let name = Range(m.range(at: 1), in: text) else { continue }
            out += text[last..<whole.lowerBound]
            out += values[String(text[name])] ?? String(text[whole])
            last = whole.upperBound
        }
        return out + text[last...]
    }

    /// The platform list: each row with the words for how it ended, or for trying again, and the line under it for
    /// one to try again.
    func list(_ rows: [PlatformRow]) -> PlatformList {
        PlatformList(
            title: self["list.title"],
            subtitle: self["list.subtitle"],
            rows: rows.map { row in
                let status: String?
                switch row.state {
                case .available: status = nil
                case .verified: status = self["list.verified"]
                case .failed: status = self["list.failed"]
                case .retry: status = self["list.retry"]
                }
                return PlatformList.Row(
                    name: row.name, state: row.state, status: status, detail: row.state == .retry ? self["list.retryDetail"] : nil)
            },
            privacy: self["list.privacy"],
            done: self["list.done"],
            footer: self["list.footer"],
            working: self["consent.working"])
    }

    /// The consent screen of the platform `name`d: `consent`, our backend's text, with the second checkbox's line,
    /// whose Terms of Service and Privacy Policy link to its `termsUrl` and `privacyUrl`, the heading over its
    /// bullets, and the close button.
    func consent(name: String, _ consent: Consent) -> ConsentScreen {
        let terms = self["consent.terms"]
        let privacy = self["consent.privacy"]
        return ConsentScreen(
            name: name, consent: consent, agree: fill("consent.agree", ["terms": terms, "privacy": privacy]),
            links: [ConsentScreen.Link(label: terms, url: consent.termsUrl), ConsentScreen.Link(label: privacy, url: consent.privacyUrl)],
            itemsTitle: self["consent.itemsTitle"], close: self["consent.close"], working: self["consent.working"])
    }

    /// The refusal: this device for `device_not_verified`, and for any other code that it isn't available now.
    func refusal(_ code: String) -> VerifyScreen {
        VerifyScreen(
            title: self[code == deviceNotVerified ? "refusal.device" : "refusal.other"], body: nil,
            accept: self["refusal.close"], decline: nil)
    }
}
