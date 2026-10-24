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

/// The words on the SDK's screens: English built in, and each key replaced by the `strings` passed to
/// `Zktls.configure`; a key the SDK does not use is ignored. The keys and the English are the same on Android.
/// Words in braces are filled in when a screen is made, in one pass, so a platform's name that holds braces
/// is shown as it is.
struct ZktlsStrings {
    /// Every key the screens use, with its English, in the order the integration guides list them.
    static let english: [(String, String)] = [
        ("intro.title", "Verify your accounts"),
        ("intro.body", "You'll sign in to each one on its own page. Only the result is shared."),
        ("intro.start", "Start"),
        ("intro.cancel", "Not now"),
        ("next.title", "{done} done"),
        ("next.body", "Next: {next}"),
        ("next.continue", "Continue"),
        ("next.stop", "Stop here"),
        ("failed.title", "{platform} couldn't be verified"),
        ("failed.continue", "Continue"),
        ("finish.title", "All done"),
        ("finish.partial", "Finished {done} of {count}"),
        ("finish.close", "Close"),
        ("refusal.device", "This device can't be verified"),
        ("refusal.other", "Verification isn't available right now"),
        ("refusal.close", "Close"),
        ("disclosure.title", "Sign in to {platform}"),
        ("disclosure.body", "{platform} opens its own sign-in page. Data read: {categories}."),
        ("disclosure.accept", "Continue"),
        ("disclosure.decline", "Cancel"),
    ]

    private static let placeholder = try! NSRegularExpression(pattern: "\\{([a-z]+)\\}")
    /// A sentence of a string's text, with the stop that ends it (Latin or CJK) and the spaces after.
    private static let sentence = try! NSRegularExpression(pattern: "[^.!?。！？]+(?:[.!?。！？]+\\s*|$)")

    private let words: [String: String]

    init(_ overrides: [String: String] = [:]) {
        var words = Dictionary(uniqueKeysWithValues: Self.english)
        for (key, text) in overrides where words[key] != nil { words[key] = text }
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

    /// `text` without its sentences that hold `placeholder`: a sentence ends at its stop and the spaces after it.
    private static func withoutSentence(_ text: String, _ placeholder: String) -> String {
        sentence.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .filter { !$0.contains(placeholder) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The intro, naming the platforms in order: Start, or Not now.
    func intro(_ names: [String]) -> VerifyScreen {
        VerifyScreen(title: self["intro.title"], body: self["intro.body"], accept: self["intro.start"], decline: self["intro.cancel"], list: names)
    }

    /// Between platforms, after `finished` was done: Continue to `next`, or Stop here.
    func next(finished: String, next: String) -> VerifyScreen {
        VerifyScreen(
            title: fill("next.title", ["done": finished]), body: fill("next.body", ["next": next]),
            accept: self["next.continue"], decline: self["next.stop"])
    }

    /// `platform` could not be verified: Continue.
    func failed(_ platform: String) -> VerifyScreen {
        VerifyScreen(title: fill("failed.title", ["platform": platform]), body: nil, accept: self["failed.continue"], decline: nil)
    }

    /// The finish: all done, or how many of the platforms were.
    func finish(_ outcome: VerifyOutcome) -> VerifyScreen {
        let done = outcome.platforms.filter { $0.status == .done }.count
        let count = outcome.platforms.count
        let title = done == count ? self["finish.title"] : fill("finish.partial", ["done": "\(done)", "count": "\(count)"])
        return VerifyScreen(title: title, body: nil, accept: self["finish.close"], decline: nil)
    }

    /// The refusal: this device for `device_not_verified`, and for any other code that it isn't available now.
    func refusal(_ code: String) -> VerifyScreen {
        VerifyScreen(
            title: self[code == deviceNotVerified ? "refusal.device" : "refusal.other"], body: nil,
            accept: self["refusal.close"], decline: nil)
    }

    /// The sign-in notice before a platform's page opens, naming `platform`, the site the page signs in to, and
    /// the data the pack reads: Continue, or Cancel. A pack that names no category leaves out the body's
    /// sentence that would list them.
    func disclosure(platform: String, categories: [String]) -> VerifyScreen {
        let body = categories.isEmpty ? Self.withoutSentence(self["disclosure.body"], "{categories}") : self["disclosure.body"]
        let filled = Self.fillIn(body, ["platform": platform, "categories": categories.joined(separator: ", ")])
        return VerifyScreen(
            title: fill("disclosure.title", ["platform": platform]), body: filled.isEmpty ? nil : filled,
            accept: self["disclosure.accept"], decline: self["disclosure.decline"])
    }
}
