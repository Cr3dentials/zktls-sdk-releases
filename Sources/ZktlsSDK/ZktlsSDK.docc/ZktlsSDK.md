# ``ZktlsSDK``

Prove a fact from a user's own account without the account data leaving their phone.

## Overview

``ZktlsClient`` runs one session. ``ZktlsClient/login(host:)`` opens the institution's own sign-in
page through a presenter. ``ZktlsClient/capture()`` fetches the record. ``ZktlsClient/prove()`` proves the
policy's statement about it to the verifier the session was assigned. ``ZktlsClient/claim()`` returns the signed claim, verified
against the trust bundle. ``ZkTlsLifecycle`` keeps the session alive for the seconds iOS allows after the
user leaves your app, and reconnects on a network change.

The default presenter, ``WebViewLoginPresenter``, shows a ``LoginDisclosure`` first and opens the page
only if the user accepts. A ``ZktlsLoginPresenter`` of your own must show an equivalent disclosure in
the same way: the app stores ask for it.

The integration guide, the error catalogue and the support matrix are in the `docs/` folder of the
releases repository.

## Topics

### Running a session

- ``ZktlsClient``
- ``SessionConfig``
- ``Phase``
- ``ProofReport``
- ``Claim``
- ``TypedOutput``
- ``SdkError``

### Login

- ``ZktlsLoginPresenter``
- ``WebViewLoginPresenter``
- ``LoginDisclosure``

### Lifecycle

- ``ZkTlsLifecycle``
- ``BackgroundTaskHost``
