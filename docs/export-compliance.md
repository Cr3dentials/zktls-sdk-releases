# Export compliance: the cryptography in the SDK

**A draft for counsel, not legal advice.** Your app's export classification is your decision, made
with your counsel. This page lists every cryptographic component the zkTLS SDK's compiled core
contains, what each is used for, and the questions our own filings put to counsel. The SDK's release
tests fail when a crate in the core's dependency graph is not named on this page and is either on
their list of known cryptographic crates or filed by its authors under crates.io's `cryptography`
category. How the list was made, and the crates in the graph that are not listed, are under
[Method](#method).

## Inventory

| Crate | Algorithm | Linked by | Standard | Used for |
|---|---|---|---|---|
| `rustls` | TLS 1.3 client | zktls-capture, zktls-resume, tokio-rustls | RFC 8446 | Attested connections to the enclaves and to the verifier, pinned by the trust bundle |
| `rustls-webpki` | X.509 certificate path validation; its signature checks call `ring` | rustls | RFC 5280 | rustls's certificate and handshake-signature checks |
| `ring` | AES-GCM, ChaCha20-Poly1305, X25519, ECDSA (P-256, P-384), Ed25519, RSA verification, SHA-2, HKDF. Also in the library, unused by the SDK (its TLS sends no client certificate): ECDSA, Ed25519 and RSA signing, PBKDF2, and QUIC header protection | rustls, rustls-webpki | FIPS 197, RFC 8439, RFC 7748, FIPS 186-5, RFC 8032, RFC 8017, FIPS 180-4, RFC 5869 | rustls's cryptography |
| `hpke` | HPKE: X25519, HKDF-SHA256, ChaCha20-Poly1305 | zktls-capture | RFC 9180 | Generating the phone's X25519 key pair for each capture (HPKE's key derivation, with HKDF-SHA256). Its public half goes to the two capture enclaves, which bind it into their signed receipts. This build seals and opens nothing with it |
| `x25519-dalek` | X25519 key agreement | hpke | RFC 7748 | The per-capture key pair, inside hpke |
| `chacha20poly1305` | ChaCha20-Poly1305 AEAD | hpke | RFC 8439 | HPKE's encryption, which this build does not call |
| `chacha20` | ChaCha20 stream cipher, and ChaCha12 as a random generator | chacha20poly1305, rand | RFC 8439 | Inside the AEAD, and rand 0.10's generator |
| `poly1305` | Poly1305 authenticator | chacha20poly1305 | RFC 8439 | Inside the AEAD |
| `hkdf` | HKDF | hpke | RFC 5869 | HPKE's key derivation for the per-capture key pair |
| `hmac` | HMAC | hkdf, rfc6979 | RFC 2104 | Inside HKDF, and RFC 6979 deterministic ECDSA nonces |
| `ed25519-dalek` | Ed25519 signature verification. The crate's signing code is also in the library, unused | zktls-sdk, zktls-claim, zktls-policy-bundle | RFC 8032 | Verifying the trust bundle, the policy bundle and claims |
| `curve25519-dalek` | Curve25519 arithmetic, and its prime-order group ristretto255 | ed25519-dalek, x25519-dalek, mpz-ot-core, zktls-claim | RFC 7748, RFC 9496 | Ed25519, X25519, and the proof protocol's base oblivious transfer over ristretto255: Chou–Orlandi in version 1, Masny–Rindal in version 2, whose hash to the group is RFC 9380's |
| `p256` | ECDSA P-256 verification | zktls-sdk | FIPS 186-5 | Verifying a trust bundle signed with a P-256 key |
| `primeorder` | Point arithmetic for prime-order short-Weierstrass curves (complete addition formulas) | p256 | none: a support crate | P-256 point arithmetic inside p256 |
| `k256` | ECDSA secp256k1 public-key recovery. Also in the library, unused by the SDK: ECDSA signing (zktls-tee-protocol's enclave-side `sign_body`, which the SDK calls only in its own tests) and BIP-340 Schnorr signing | zktls-tee-protocol | SEC 2, FIPS 186-5, BIP-340 | Recovering each capture enclave's signer address from the ECDSA signature on its capture evidence |
| `ecdsa` | ECDSA | p256, k256 | FIPS 186-5 | Inside p256 and k256 |
| `rfc6979` | HMAC-DRBG deterministic ECDSA nonces | ecdsa | RFC 6979 | Only inside k256's signing code above, which the SDK does not call |
| `elliptic-curve` | Elliptic-curve traits | p256, k256, ecdsa, primeorder | none: a support crate | Inside p256 and k256 |
| `rsa` | RSA-PSS SHA-256 verification. Also in the library, unused: PKCS#1 v1.5 signature verification and PKCS#1 v1.5 decryption | zktls-sdk | RFC 8017 | Verifying a trust bundle signed with an RSA key |
| `sha2` | SHA-256, SHA-512 | many | FIPS 180-4 | Digests, commitments, signatures, and in the proof protocol's version 2 base oblivious transfer, hashing to ristretto255 (RFC 9380's `expand_message_xmd` with SHA-512) and deriving its keys (SHA-256) |
| `sha3` | SHA-3 | zktls-tee-protocol | FIPS 202 | Keccak256: the digest the capture enclaves sign their evidence over, and each enclave's Ethereum-style signer address |
| `keccak` | Keccak permutation | sha3 | FIPS 202 | Inside SHA-3 |
| `sha1` | SHA-1 | tungstenite | FIPS 180-4 | The WebSocket handshake's accept key (RFC 6455); not a security use |
| `siphasher` | SipHash-1-3 keyed hash | uniffi_meta | Published specification; no standards body | Checksums of the interface description in UniFFI's bindings generator, which is compiled into the library but never called at run time; not a security use |
| `blake3` | BLAKE3 hash | mpz-core, mpz-ot-core, mpz-zk-core, tlsn-mux, zktls-prover | Published specification; no standards body | Hashing inside the proof protocol |
| `aes` | AES block cipher | mpz-core, mpz-ot-core | FIPS 197 | AES as a hash and generator inside oblivious transfer, under a fixed public key or, in the proof protocol's version 2, a key derived from the public session id; encrypts no user data |
| `clmul` | Carry-less multiplication, GF(2^128) arithmetic | mpz-core, mpz-ot-core | none: arithmetic | Inside the proof protocol |
| `mpz-*` | Oblivious transfer (base OT, SoftSpoken and Ferret extension), coin tossing, VOLE-based zero-knowledge proofs, and a SHA-256 compression circuit evaluated inside the proof (mpz-circuits) | zktls-prover, zktls-circuit, zktls-capture-circuit | Published academic protocols; not standards | Proving a statement about the captured record to the verifier without revealing it |
| `rand_chacha` | ChaCha8, ChaCha12 and ChaCha20 random generators | rand, mpz-core, mpz-ot, mpz-ot-core, zktls-prover | none: the RFC 8439 cipher used as a generator | Seeded generators inside the proof protocol, and rand 0.8's and 0.9's generators |
| `rand` | ThreadRng and StdRng: ChaCha12 generators (from `rand_chacha` or `chacha20`) seeded from the operating system | mpz-core, mpz-fields, mpz-ot, mpz-ot-core, zktls-prover, zktls-resume, ark-std, num-bigint-dig, tungstenite, tlsn-mux | none: a generator design, not a standard | Random values for the proof protocol, and WebSocket keys and frame masks |
| `ark-secp256r1` | The P-256 curve's base-field parameters, with ark-ff's Montgomery arithmetic over them: field arithmetic only, no point arithmetic | mpz-fields | FIPS 186-5 (the P-256 field) | mpz-fields' `P256` field type, which no crate in the SDK's graph uses |
| `zktls-lowmc` | LowMC-256 block cipher in Davies-Meyer mode, as a hash | zktls-capture-circuit | Published academic cipher; not a standards-body algorithm | A candidate commitment hash, pending an external cryptanalysis review. Not used: this build's circuit compiler (`zktls-circuit::commitment::require`) and the policy bundle's validation accept only `CommitmentHashId::Sha256`, so the commitment hash is SHA-256 and no code path reaches LowMC. Its code is still in the library, and survives an app's linker: the sample app's dSYM lists 9 `zktls_lowmc` symbols. |

## Method

The list is every crate in the core's normal (run-time) dependency graph for the shipped targets
(`cargo tree -e normal --target aarch64-apple-ios` and `--target aarch64-linux-android`) that
implements a cipher, hash, MAC, key derivation, signature, key exchange, curve arithmetic or random
generator. For the 0.1.0 build, each was checked against the iOS device slice, `libzktls_sdk.a`: its
member objects, their machine code, and their symbols (`nm-classic`). That static library holds the compiled
code of every crate in the graph, including code the SDK never calls; an app's linker keeps only what
the SDK reaches. So the Algorithm column names what the library holds, and the last column what the
SDK uses it for.

In the graph, with no cryptographic code in the library:

| Crate | What it is | Evidence |
|---|---|---|
| `ctr` | CTR block-cipher mode | Declared by mpz-ot-core, whose source never uses it (its `ctr` identifiers are local counters). The library has no object from it and no symbol that names it |
| `ark-ec` | Generic elliptic-curve arithmetic | The library holds only its non-generic helpers, 168 bytes (a wNAF table constructor, error text); no curve's arithmetic is instantiated |

Not in the graph: `fiat-crypto` is in the lockfiles, but curve25519-dalek (4.1 and 5.0) takes it only when built with
`curve25519_dalek_backend = "fiat"`, which the SDK is not.

Also in the graph, and not rows, because they implement no algorithm of their own: traits (`aead`,
`cipher`, `digest`, `signature`, `universal-hash`, `crypto-common`, `ff`, `group`, `rand_core`, `inout`,
`block-buffer`); arithmetic (`crypto-bigint`, `num-bigint-dig`, `ark-ff`, `ark-poly`,
`matrix-transpose`); constant-time helpers and key wiping (`subtle`, `cmov`, `ctutils`,
`constant_time_eq`, `zeroize`); encodings (`der`, `spki`, `pkcs1`, `pkcs8`, `sec1`, `pem-rfc7468`,
`base16ct`, `base64ct`); `ed25519` (signature types); `getrandom` (the operating system's random
source); `tokio-rustls` (an async wrapper around rustls); and `ahash` (a hash-table hasher, not
cryptographic by its own documentation). Their authors file these under crates.io's `cryptography`
category too, and none implements an algorithm: `ark-serialize`, `const-oid` and
`rustls-pki-types` (encodings and key and certificate types); `ark-std` (standard-library shims for
the arkworks crates); `ppv-lite86` (SIMD vector types for rand_chacha's generators); and
`ark-ff-asm`, `ark-ff-macros`, `ark-serialize-derive` and `zeroize_derive` (procedural macros, which
run inside the compiler and leave no code of their own in the library). zktls-circuit and
zktls-capture-circuit build the proof's statement from the primitives above (sha2, mpz-circuits'
SHA-256 circuit, zktls-lowmc).

## What the encryption protects

- **Confidentiality in transit**, with standard algorithms only: TLS 1.3 (rustls) to the enclaves (the
  attester among them) and to the verifier, and HTTPS to the front door through the operating system's
  own HTTP stack. The
  institution's own TLS session is built with the capture enclave's help. The phone relays it, and the
  cookie is split so that no single enclave reads it.
- **Key generation, not yet encryption**: the phone generates an X25519 key pair for each capture
  (HPKE's key derivation) and sends its public half to the enclaves, which bind it into their signed
  receipts. This build seals and opens nothing with it.
- **Authenticity**: signatures on the trust bundle, the policy bundle, enclave evidence and claims.
- **Zero-knowledge proof**: the oblivious-transfer and VOLE protocols prove that the captured record
  satisfies the policy. They are integrity mechanisms. They do not encrypt data the user stores or sends.

## Questions for counsel

*Reviewed by Cr3dentials on 21 October 2026. Counsel has not answered these yet; until counsel does,
this page is a draft.*

We propose classification **5D992.c**: mass-market software (Note 3 to Category 5, Part 2) whose
confidentiality mechanisms use only published standard algorithms. Counsel decides, and the answers
decide what is filed:

1. Whether 5D992.c holds.
2. Whether the SDK, a library that other apps link, is a mass-market encryption *component* under
   EAR §740.17(e)(3). If it is, a self-classification report goes to BIS and the ENC Encryption
   Request Coordinator by 1 February after each calendar year in which it is exported. If it is not,
   whether any report is due.
3. Whether the zero-knowledge and oblivious-transfer protocols, and `zktls-lowmc`'s LowMC-256 (in the
   library but unreachable, see its row), are "non-standard cryptography" under EAR part 772, or
   "proprietary or not accepted by international standard bodies" in Apple's table below. If they
   are: §740.17(b)(3)(ii) calls for a 30-day classification request to BIS instead of
   self-classification, and Apple asks for the resulting CCATS. If a later release makes LowMC
   reachable, its changelog says so, and this point is asked again.
4. Whether Note 4 to Category 5, Part 2 (items whose primary function is not information security)
   takes the proof protocols, or the SDK as a whole, out of Category 5, Part 2.
5. How you file Apple's French encryption declaration, which Apple requires to distribute on the App
   Store in France.

## App Store Connect

Apple's table, from "Export compliance documentation for encryption"
(https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption,
read 25 September 2026):

| Encryption algorithm in use | Required documentation |
|---|---|
| Your app uses encryption limited to that within the Apple operating system | No documentation required in App Store Connect. |
| Your app uses an industry standard algorithm, not provided within the Apple operating system | Upload your French encryption declaration in App Store Connect.¹ |
| Your app uses proprietary encryption algorithms not accepted by international standard bodies (such as IEEE, IETF, or ITU) | Upload your: US Commodity Classification Automated Tracking System (CCATS); French encryption declaration in App Store Connect¹ |

¹ "French encryption declaration form is only required if you're distributing your app on the App
Store in France."

What that means for an app with the SDK, once counsel has answered:

- **Your app uses encryption.** The SDK carries its own TLS 1.3 (rustls), beyond what the operating
  system provides, so the first row does not apply.
- **If counsel answers point 3 no**, the second row applies: upload the French declaration if you
  distribute in France; otherwise there is nothing to upload.
- **If counsel answers point 3 yes**, the third row applies: upload the CCATS, and the French
  declaration if you distribute in France.
- When Apple approves uploaded documentation, it gives you a key value. Enter it in your app's
  `Info.plist` as `ITSEncryptionExportComplianceCode`, with `ITSAppUsesNonExemptEncryption`, so later
  uploads skip the questions (Apple, "Determine and upload app encryption documentation",
  https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation).

Google Play asks no export question. The same export law applies to the app all the same.
