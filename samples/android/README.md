# Android sample app

The partner sample: `login` → `capture` → `prove` → `claim` against a cell, using only the public
`ai.zktls.sdk` surface. As it sits here, in the releases repository, it is its own Gradle build
that resolves the SDK from Maven Central (`xyz.cr3dentials:zktls-sdk`), exactly as a
partner's app does.

Two lifecycle pieces:

- **The SDK's `ZkTlsSessionService`** around the capture and proof, opened once the login returns,
  so the work survives the screen going off: a `shortService` from API 34, and below that an
  untyped foreground service that ends itself after the same three minutes. When it ends, the flow
  is cancelled and the user starts a new session. Its notification text and icon are the SDK's
  `zktls_session_*` resources, which an app overrides to localise or rebrand them.
- **`ZkTlsLifecycle`** watches the default network, so a Wi-Fi to cellular handover reaches the
  Rust transport at once. Before the freeze that session is lost; the user taps again. Neither
  the SDK nor the sample retries by itself.

## Build and run

```bash
./gradlew :app:installDebug
adb push session.json /sdcard/Android/data/ai.zktls.sample/files/session.json
```

## Settings

The app reads one JSON object: the `SessionConfig` fields in snake case
(`base_url`, `app_credential`, `user_id_hash`, `profile_id`, `policy_id`, `client_region`,
`network_key`, `trust_bundle_json`, `trust_bundle_url` (optional: where the SDK refetches the trust bundle
once if an enclave's key is newer than `trust_bundle_json`), `trust_operator_key` (the operator's public key,
PEM), `policy_bundle_json`, `policy_bundle_digest`).

**A platform's pack.** *Run a platform pack* runs `runTree` for the platform picked above it. Its
settings are a second file, `tree.json`, beside `session.json`: `base_url`, `app_credential`,
`trust_operator_key` (the operator's public key the packs are signed with, PEM), `runs_url`, and
`platforms` (the platform ids to offer), with `user_id_hash`, `client_region`, `network_key` and
`trust_bundle_url` optional. `runs_url` is your backend's endpoint for a run: it answers `POST {"platform_id": ...}`
with the `result_url` and `result_token` our backend issued for it, and a check's `params` if it
takes any.

```bash
adb push tree.json /sdcard/Android/data/ai.zktls.sample/files/tree.json
```

The app makes each session's client ahead, the first one at launch. Making it loads the SDK's native
core, so with the settings in place a release build that lost the core's classes fails at launch.

