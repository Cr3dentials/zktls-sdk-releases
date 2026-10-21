import Foundation

/// What the user is told, and must accept, before the login page opens.
///
/// App Review (guideline 5.1.1) and Google Play's User Data policy both ask for a prominent,
/// in-app disclosure before an app reads account data the user would not expect it to read. A
/// bank's sign-in cookies are that data. ``WebViewLoginPresenter`` shows this every time and opens
/// the page only when the user accepts. Pass your own text to localise it, keeping every fact the
/// standard text states.
public struct LoginDisclosure: Sendable, Equatable {
    /// The dialog's title.
    public var title: String
    /// The dialog's body: what is read, how it is used, and what is kept.
    public var message: String
    /// The button that opens the login page.
    public var accept: String
    /// The button that ends the login without opening it.
    public var decline: String

    /// A disclosure with your own words.
    public init(title: String, message: String, accept: String, decline: String) {
        self.title = title
        self.message = message
        self.accept = accept
        self.decline = decline
    }

    /// The default English text, naming every domain whose cookies are read.
    public static func standard(domains: [String]) -> LoginDisclosure {
        let list = domains.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }.joined(separator: ", ")
        return LoginDisclosure(
            title: "Sign in to \(list)",
            message: "To prove this, the app opens \(list)'s own sign-in page. After you sign in, it reads the sign-in cookies for \(list) on this device and uses them once, to fetch the record you are proving. They are not stored, and they are deleted when the proof ends. The app receives only the proven result, not your account data or your password.",
            accept: "Continue",
            decline: "Not now")
    }
}

/// The disclosure, then the login page, only on accept. Declining returns no cookies, so `login`
/// fails with `NotLoggedIn`, as closing the page does.
func gated(
    _ disclosure: LoginDisclosure, ask: (LoginDisclosure) async -> Bool, open: () async -> [String]
) async -> [String] {
    guard await ask(disclosure) else { return [] }
    return await open()
}
