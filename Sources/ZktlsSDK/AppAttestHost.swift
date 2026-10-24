import CryptoKit
import DeviceCheck
import Foundation

/// App Attest as the SDK asks it: `DCAppAttestService` on a device, a script in tests.
protocol AppAttest: AnyObject {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

extension DCAppAttestService: AppAttest {}

/// The device's half of a start on iOS: the install's id, and each live start's attestation. With App Attest,
/// the install is its App Attest key, made on first use and registered with our backend once (for a live key);
/// a live start then carries an assertion over its exact body. Without App Attest, a test key's install is a
/// random id kept for the install, and a live key is refused: the device cannot attest. The key's id, the id
/// registered and the random id live in `UserDefaults`, under `ai.zktls.attest.key`, `ai.zktls.attest.registered`
/// and `ai.zktls.install`.
final class AppAttestHost: @unchecked Sendable {
    static let keyDefault = "ai.zktls.attest.key"
    static let registeredDefault = "ai.zktls.attest.registered"
    static let installDefault = "ai.zktls.install"

    private let live: Bool
    private let attest: AppAttest
    private let defaults: UserDefaults

    /// The host for a live key when `live`, else for a test key, which never attests.
    init(live: Bool, attest: AppAttest = DCAppAttestService.shared, defaults: UserDefaults = .standard) {
        self.live = live
        self.attest = attest
        self.defaults = defaults
    }

    /// The install's id: its App Attest key, made now if it has none; without App Attest (or, for a test key,
    /// when the key cannot be made), a random id made once. A live key on a device that cannot attest is
    /// refused with `device_not_verified`.
    func installId() async throws -> String {
        if attest.isSupported {
            if let key = defaults.string(forKey: Self.keyDefault) { return key }
            do {
                return try await newKey()
            } catch {
                if live { throw refused("App Attest made no key: \(error.localizedDescription)") }
            }
        } else if live {
            throw refused("App Attest is not supported on this device")
        }
        if let id = defaults.string(forKey: Self.installDefault) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.installDefault)
        return id
    }

    /// Whether the install's key has yet to be registered with our backend.
    var needsRegistration: Bool {
        guard let key = defaults.string(forKey: Self.keyDefault) else { return true }
        return defaults.string(forKey: Self.registeredDefault) != key
    }

    /// The install's key attested over `challengeSha256`, in base64. Apple attests a key once: a key it will not
    /// attest (again) is replaced by a new one, attested now, which `installId` then answers.
    func register(challengeSha256: Data) async throws -> String {
        do {
            var key = defaults.string(forKey: Self.keyDefault) ?? ""
            if key.isEmpty { key = try await newKey() }
            do {
                return try await attest.attestKey(key, clientDataHash: challengeSha256).base64EncodedString()
            } catch let e as DCError where e.code == .invalidKey {
                return try await attest.attestKey(newKey(), clientDataHash: challengeSha256).base64EncodedString()
            }
        } catch {
            throw refused("App Attest did not attest the key: \(error.localizedDescription)")
        }
    }

    /// Our backend registered the install's key.
    func registered() {
        defaults.set(defaults.string(forKey: Self.keyDefault), forKey: Self.registeredDefault)
    }

    /// `ios.` and an assertion by the install's key over `body`'s SHA-256, for a start whose body is exactly
    /// `body`. A key the device no longer has (a backup restored the defaults, not the Secure Enclave's key) is
    /// forgotten and answered as `attest_key_unknown`, on which the core registers a new key and starts again.
    func sign(body: Data) async throws -> String {
        guard let key = defaults.string(forKey: Self.keyDefault) else { throw refused("the install has no App Attest key") }
        do {
            let assertion = try await attest.generateAssertion(key, clientDataHash: Data(SHA256.hash(data: body)))
            return "ios." + assertion.base64EncodedString()
        } catch {
            if let e = error as? DCError, e.code == .invalidKey {
                defaults.removeObject(forKey: Self.keyDefault)
                defaults.removeObject(forKey: Self.registeredDefault)
                throw SdkError.Refused(code: attestKeyUnknown, message: "the install's App Attest key is gone: \(error.localizedDescription)")
            }
            throw refused("App Attest gave no assertion: \(error.localizedDescription)")
        }
    }

    private func newKey() async throws -> String {
        let key = try await attest.generateKey()
        defaults.set(key, forKey: Self.keyDefault)
        return key
    }

    private func refused(_ message: String) -> SdkError { .Refused(code: deviceNotVerified, message: message) }
}
