# iOS sample app

The partner sample: `login` → `capture` → `prove` → `claim` against a cell, using only the public
`ZktlsSDK` package. Open `ZktlsSample.xcodeproj`. It uses the package at the repository root.

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
| `ZKTLS_BASE_URL` | The front door the allocate call goes to |
| `ZKTLS_APP_CREDENTIAL` | The app's credential, from us |
| `ZKTLS_USER_ID_HASH` | The app's hash of its user id |
| `ZKTLS_PROFILE_ID`, `ZKTLS_POLICY_ID` | The profile and policy the session proves |
| `ZKTLS_CLIENT_REGION` | ISO country code; empty means unknown and the SDK probes cells |
| `ZKTLS_TRUST_BUNDLE_URL` | The published trust bundle (JSON), fetched at the start of a run and passed as `trustBundleUrl` too, so the SDK refetches it once if an enclave's key is newer than that copy |
| `ZKTLS_TRUST_OPERATOR_KEY` | The operator's public key the bundle must be signed by, base64 DER; pinned in the app |
| `ZKTLS_POLICY_BUNDLE_URL`, `ZKTLS_POLICY_BUNDLE_DIGEST` | The signed policy bundle and the digest the app pins it by |
| `ZKTLS_RUNS_URL` | Your backend's endpoint for a platform pack's run: it answers `POST {"platform_id": ...}` with the `result_url` and `result_token` our backend issued for it, and a check's `params` if it takes any |
| `ZKTLS_PLATFORMS` | The platform ids *Run a platform pack* offers, comma-separated |

*Run a platform pack* runs `runTree` for the platform picked, with `ZKTLS_BASE_URL`, `ZKTLS_APP_CREDENTIAL`,
`ZKTLS_USER_ID_HASH`, `ZKTLS_CLIENT_REGION` and `ZKTLS_TRUST_OPERATOR_KEY`, which the packs are signed with,
and the run `ZKTLS_RUNS_URL` issues.

