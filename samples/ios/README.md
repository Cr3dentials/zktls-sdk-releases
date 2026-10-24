# iOS sample app

The partner sample, using only the public `ZktlsSDK` package. *Verify with zktls-demo* is a partner's whole
integration: `Zktls.configure` with your app's key at launch, then `Zktls.verify` on the demo platform
`zktls-demo`, with the SDK's own screens. *Prove my transfer* is the proof flow, `login` → `capture` →
`prove` → `claim` against a cell, and *Run a platform pack* one platform's pack on its own, the lab's. Open
`ZktlsSample.xcodeproj`. It uses the package at the repository root.

## Build

```bash
xcodebuild -project ZktlsSample.xcodeproj -scheme ZktlsSample \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.1' build CODE_SIGNING_ALLOWED=NO
```

## Settings

Each is a build setting copied into `Info.plist`; pass them to `xcodebuild` (`NAME=value`) or set
them in Xcode. The three `_URL` settings are fetched with `URLSession` at the start of a run.

| Setting | What |
|---|---|
| `ZKTLS_APP_KEY` | Your app's publishable key for *Verify with zktls-demo*. A test key (`zk_test_…`) runs on the simulator; a live key needs a device with App Attest |
| `ZKTLS_BASE_URL` | The front door the allocate call goes to |
| `ZKTLS_APP_CREDENTIAL` | The app's credential, from us |
| `ZKTLS_USER_ID_HASH` | The app's hash of its user id |
| `ZKTLS_PROFILE_ID`, `ZKTLS_POLICY_ID` | The profile and policy the session proves |
| `ZKTLS_CLIENT_REGION` | ISO country code; empty means unknown and the SDK probes cells |
| `ZKTLS_TRUST_BUNDLE_URL` | The published trust bundle (JSON), fetched at the start of a run and passed as `trustBundleUrl` too, so the SDK refetches it once if an enclave's key is newer than that copy |
| `ZKTLS_TRUST_OPERATOR_KEY` | The operator's public key the bundle must be signed by, base64 DER; pinned in the app |
| `ZKTLS_POLICY_BUNDLE_URL`, `ZKTLS_POLICY_BUNDLE_DIGEST` | The signed policy bundle and the digest a session pins it by |
| `ZKTLS_POLICY_BUNDLE_KEYS` | For a pack that attests: the keys the policy bundle must be signed with, comma-separated, 64 lowercase hex characters each |
| `ZKTLS_RUNS_URL` | Your backend's endpoint for a platform pack's run: it answers `POST {"platform_id": ...}` with the `result_url` and `result_token` our backend issued for it, and a check's `params` if it takes any |
| `ZKTLS_PLATFORMS` | The platform ids *Run a platform pack* offers, comma-separated |

*Run a platform pack* runs `runTree` for the platform picked, with `ZKTLS_BASE_URL`, `ZKTLS_APP_CREDENTIAL`,
`ZKTLS_USER_ID_HASH`, `ZKTLS_CLIENT_REGION` and `ZKTLS_TRUST_OPERATOR_KEY`, which the packs are signed with,
and the run `ZKTLS_RUNS_URL` issues.

