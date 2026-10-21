# Support matrix

## Floors and targets

| Item | Value |
|---|---|
| iOS minimum | 14.0 |
| iOS device architectures | arm64 |
| iOS simulator architectures | arm64, x86_64 |
| Swift tools | 5.9 |
| Xcode | Built and tested with 26.3; App Store uploads need Xcode 26 |
| Installation, iOS | Swift Package Manager; CocoaPods 1.16 or later |
| Android minSdk | 24 |
| Android compileSdk | 36 |
| Android ABIs | arm64-v8a, armeabi-v7a, x86, x86_64 |
| Kotlin compiler, Android | 2.1 or later (the AAR carries Kotlin 2.2 metadata) |
| Kotlin standard library, Android | 2.2.10 or later (the AAR's dependency) |
| Android 16 KB pages | Yes, checked on every release build |
| Installation, Android | Maven Central, `xyz.cr3dentials:zktls-sdk` |

iOS 13 and Android API 23 were checked on 24 September 2026 and are not supported. iOS 13: the
arm64 simulator slice needs iOS 14.0, and the SDK has not run on iOS 13. Android API 23 fails because
the core's network callback needs API 24, and JNA 5.19.1 fails to load on API 23 (`NoClassDefFoundError`).

## Tested on

| Platform | Where | Result |
|---|---|---|
| iOS | Simulator: iPhone 16, iOS 18.1 (arm64); x86_64 build | SDK tests pass |
| iOS | Device: iPhone 14 Pro Max, iOS 26.5.2 | Against a live cell: the proof flow through `claim()`, accepted (16 October 2026); a platform pack that attests, handed off to the attester, whose result reached the backend (21 October 2026) |
| iOS | Device: the lowest iOS available | Not run yet: no device on an older iOS has been tested |
| Android | Emulator, API 35 arm64 | SDK and sample tests pass; the sample's end-to-end test is skipped without a live cell |
| Android | Device, mid-range: Samsung Galaxy M33 5G (SM-M336K), Android 16 | Against a live cell: a platform pack that attests, handed off to the attester, whose result reached the backend (21 October 2026) |
| Android | Device: Pixel 8a, Android 15 (Firebase Test Lab) | Against a live cell: the sample's full flow through `claim()`, accepted (7 October 2026) |
| Android | Device, low-end | Not run yet |
| Both | An end-to-end session against a live cell, through `claim()` | Run on both platforms: the rows above |

## Measured (build 0.1.0)

Measured on the 0.1.0 build, the version the SDK carries before its first public release. Sizes in
MiB (1 MiB = 1,048,576 bytes).

| Item | Size |
|---|---|
| `ZktlsSDKFFI-0.1.0.xcframework.zip` | 34.3 MiB |
| Device slice, `libzktls_sdk.a` | 43.2 MiB; the linker keeps only what the app reaches |
| The sample app's arm64 executable, stripped | 4.9 MiB, almost all of it the SDK |
| AAR | 12.8 MiB |
| Download size per ABI (the sample's AAB) | arm64-v8a 3.4 MiB; armeabi-v7a 3.0 MiB; x86_64 3.5 MiB; x86 3.7 MiB (`bundletool get-size total --dimensions=ABI` on the R8-minified, upload-signed bundle) |
| Java bytecode | 55 (Java 11) |
