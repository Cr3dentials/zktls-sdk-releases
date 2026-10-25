# zkTLS SDK

Verify your users' accounts from your own iOS or Android app. Your app makes two calls:
`Zktls.configure` once at launch, and `Zktls.verify` with the platforms you want and a reference of your
choice. The SDK shows its own screens, opens each platform's sign-in page, and has each result read and
signed by an attester. Your server gets the results in signed webhooks; they never pass through your app.

```swift
Zktls.configure(appKey: "zk_test_…")                                    // once, at launch
let outcome = try await Zktls.verify(["zktls-demo"], reference: "order_8f3k2")
```

```kotlin
Zktls.configure(appKey = "zk_test_…")                                   // once, at launch
val outcome = Zktls.verify(activity, listOf("zktls-demo"), reference = "order_8f3k2")
```

This repository holds the SDK's releases: the Swift API and the signed compiled core for iOS (Swift
Package Manager and CocoaPods). The Android library is on Maven Central. The core's source is not
published here.

| | iOS | Android |
|---|---|---|
| Minimum OS | iOS 14.0 | Android 7.0 (API 24) |
| Install | Swift Package Manager or CocoaPods | Gradle, from Maven Central |
| API reference | `ZktlsSDK-<version>.doccarchive.zip` on each release | `zktls-sdk-<version>-dokka.zip` on each release |

No account or token is needed to install.

## Install

**Swift Package Manager.** In Xcode, choose File → Add Package Dependencies, enter
`https://github.com/Cr3dentials/zktls-sdk-releases`, and add the product `ZktlsSDK`. In a `Package.swift`:

```swift
.package(url: "https://github.com/Cr3dentials/zktls-sdk-releases", from: "2.0.1"),
// and in your target's dependencies:
.product(name: "ZktlsSDK", package: "zktls-sdk-releases"),
```

**CocoaPods.** This repository is its own spec source. Keep it first in your `Podfile`: CocoaPods
takes a pod from the first source that has it.

```ruby
source 'https://github.com/Cr3dentials/zktls-sdk-releases.git'
source 'https://cdn.cocoapods.org/'
platform :ios, '14.0'

target 'YourApp' do
  pod 'ZktlsSDK', '~> 2.0'
end
```

**Gradle.** From `mavenCentral()`, which Android projects include by default:

```kotlin
dependencies {
    implementation("xyz.cr3dentials:zktls-sdk:2.0.1")
}
```

## Signatures

The xcframework is signed with our Apple Distribution certificate, Team ID `R8287QD4F7`.
`codesign -dv ZktlsSDKFFI.xcframework` prints the `TeamIdentifier` to compare. The Android library's
files on Maven Central are signed with our OpenPGP key, fingerprint
`E8588B38D6FDCC59E6C03011AE4CC59A87AD0C0B`, on the public keyservers.

## Documentation

- **[Partner integration checklist](docs/partner-checklist.md): start here**
- [iOS integration guide](docs/integration-ios.md)
- [Android integration guide](docs/integration-android.md)
- [Errors](docs/errors.md)
- [Support matrix](docs/support-matrix.md)
- [Privacy: what the SDK sends, keeps and declares](docs/privacy.md)
- [Store review: the sign-in pages and their cookies](docs/store-review.md)
- [Export compliance](docs/export-compliance.md)
- [Changelog](CHANGELOG.md)

For proof mode, which we enable per partner, and for pack authors:

- [Verifying a proof-mode claim on your backend](docs/backend-verification.md)
- [Platform packs and `runTree`, behind the lab opt-in](docs/integration-packs.md)
- [Receiving a lab run's result](docs/backend-tree-results.md)

## Versions

Releases follow [Semantic Versioning](https://semver.org/). A patch release never changes the
public API. A breaking change comes only in a major release, listed under "Breaking" in the
[changelog](CHANGELOG.md).

## Licence

[LICENSE](LICENSE); the open-source crates inside the binary: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
Include it in your app's open-source notices. On Android, JNA, kotlinx-coroutines, androidx.webkit,
Google Play Integrity and the Kotlin standard library arrive as Maven dependencies under their own
licences, which your licence tooling lists. Google Play Integrity and the Google Play services libraries
it brings are under Google's own terms, not an open-source licence (see each library's POM, and the
[Play Integrity API Terms of Service](https://developer.android.com/google/play/integrity/terms)).
