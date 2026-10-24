# ``ZktlsSDK``

Verify your users' accounts from your app, with the results going to your server.

## Overview

``Zktls`` is the SDK. Call `Zktls.configure(appKey:theme:strings:)` once, when your app launches, with
your app's publishable key, then `Zktls.verify(_:reference:)` with the platforms you want and a reference
of your choice. The SDK checks the device with App Attest (a live key), starts a verification with our
backend, shows its own screens over your app, and opens each platform's sign-in page. Each platform's
result goes to your server from ours, in a signed webhook; `verify` returns a ``VerifyOutcome`` that says
how each platform ended. ``ZktlsTheme`` and the `strings` set the screens' look and words.

In proof mode, which we enable per partner, ``ZktlsClient`` runs one session.
``ZktlsClient/login(host:)`` opens the institution's own sign-in page through a presenter. ``ZktlsClient/capture()`` fetches the record. ``ZktlsClient/prove()`` proves the
policy's statement about it to the verifier the session was assigned. ``ZktlsClient/claim()`` returns the signed claim, verified
against the trust bundle. ``ZkTlsLifecycle`` keeps the session alive for the seconds iOS allows after the
user leaves your app, and reconnects on a network change.

The default presenter, ``WebViewLoginPresenter``, shows a ``LoginDisclosure`` first and opens the page
only if the user accepts. A ``ZktlsLoginPresenter`` of your own must show an equivalent disclosure in
the same way: the app stores ask for it.

The integration guide, the error catalogue and the support matrix are in the `docs/` folder of the
releases repository.

## Topics

### Verifying

- ``Zktls``
- ``ZktlsTheme``
- ``VerifyOutcome``
- ``PlatformOutcome``
- ``PlatformStatus``
- ``SdkError``

### Proof mode: running a session

- ``ZktlsClient``
- ``SessionConfig``
- ``Phase``
- ``ProofReport``
- ``Claim``
- ``TypedOutput``

### Proof mode: login

- ``ZktlsLoginPresenter``
- ``WebViewLoginPresenter``
- ``LoginDisclosure``

### Proof mode: lifecycle

- ``ZkTlsLifecycle``
- ``BackgroundTaskHost``
