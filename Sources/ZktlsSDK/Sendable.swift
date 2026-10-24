// The generated types declare no `Sendable`, so an app in Swift 6 language mode could not hand them
// between actors. Each conformance holds for the reason on its line.

// Objects: the Swift instance holds one pointer that never changes, and every call reaches a Rust object
// that UniFFI requires to be safe to share between threads.
extension Session: @unchecked Sendable {}          // a shareable cancel token; the progress sink behind a lock
extension LifecycleHandle: @unchecked Sendable {}  // the state machine behind a lock
extension CookieHandle: @unchecked Sendable {}     // the cookies behind a lock; the domains never change
extension WitnessHandle: @unchecked Sendable {}    // the capture behind a lock, taken once by `prove`
extension SessionMaterialHandle: @unchecked Sendable {}  // the values behind a lock; the names never change

// Records: values made only of strings, booleans, integers and other such records.
extension SessionConfig: @unchecked Sendable {}    // strings
extension ProofReport: @unchecked Sendable {}      // a boolean, strings and integers
extension Claim: @unchecked Sendable {}            // strings, integers and `TypedOutput`s
extension TypedOutput: @unchecked Sendable {}      // strings
extension Phase: @unchecked Sendable {}            // cases with no associated values
extension TreeRunConfig: @unchecked Sendable {}    // strings and a list of strings
extension VerifyEnv: @unchecked Sendable {}        // strings and a list of strings
extension TreeSummary: @unchecked Sendable {}      // a boolean, strings, integers, `TreeSource`s and a `Claim`
extension TreeSource: @unchecked Sendable {}       // strings, integers, a boolean and a `SourceEvidence`
extension SourceEvidence: @unchecked Sendable {}   // cases with no associated values
extension TreeHeader: @unchecked Sendable {}       // strings
extension TreeFetchRequest: @unchecked Sendable {} // strings, integers and `TreeHeader`s
extension TreeFetchResponse: @unchecked Sendable {} // strings and an integer
extension TreeSessionRequest: @unchecked Sendable {} // strings
extension TreeScriptRequest: @unchecked Sendable {} // strings, an integer and `TreeScriptCookie`s
extension TreeScriptCookie: @unchecked Sendable {}  // strings
extension VerifyOutcome: @unchecked Sendable {}    // a string and `PlatformOutcome`s
extension PlatformOutcome: @unchecked Sendable {}  // strings and a `PlatformStatus`
extension PlatformStatus: @unchecked Sendable {}   // cases with no associated values
extension VerifyRequest: @unchecked Sendable {}    // strings and a list of strings (internal: the facade's)
