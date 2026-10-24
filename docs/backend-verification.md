# Verifying a claim on your backend

This page is for proof mode's claim. With `verify`, the attester's signed claim comes in your
`platform.finished` webhook instead, and [checking a result](backend-tree-results.md#checking-a-result-typescript-node-22-or-later)
shows how to check one.

`claim()` verifies the claim on the phone, but your backend must not trust the phone. Send it
`claim.encoded`, the claim's canonical bytes in base64, and verify them again with one of our libraries.
Each does the same checks, in the same order, as the SDK.

## What you configure once

- **The operator's public key**, PEM, from us. Pin it in your backend's configuration; never fetch it.
  The trust bundle is believed only when this key signed it.
- **The trust bundle's URL**, from us. Fetch it at least every 60 seconds and keep the highest version you
  have accepted; refuse a lower one, so a stale copy cannot undo a revocation. If you have not fetched a
  fresh copy for 30 minutes, stop accepting claims until you do.

## The checks

1. The signature: Ed25519 over the claim's canonical encoding, by a claim key the trust bundle lists for
   the claim's `verifier_epoch`, on a verifier that is not revoked, in an epoch that is valid.
2. The time: `issued_at` at most 60 seconds ahead of your clock, and `expires_at` not passed.
3. No holder binding, unless your backend checks one: `verify` refuses a bound claim.
4. `profile_id` and `policy_id` are the ones you asked for, and the outputs say what you need.
5. The nullifier: if an account may prove a fact once, refuse a nullifier you have already seen.

The libraries do checks 1 to 3; 4 and 5 are yours. Verify a claim when it arrives: a claim stops
verifying once the epoch it was signed in closes, which can be before its `expires_at`.

## TypeScript (Node 22 or later)

    npm install @zktls/claim

```typescript
import { canonicalDecode, loadTrustBundle, verify, type TrustBundle } from "@zktls/claim";

const OPERATOR_KEY = process.env.ZKTLS_TRUST_OPERATOR_KEY!; // PEM, pinned in your configuration
let highest = 0n;

async function trustBundle(): Promise<TrustBundle> {
  const json = await (await fetch(process.env.ZKTLS_TRUST_BUNDLE_URL!)).text();
  const bundle = loadTrustBundle(json, OPERATOR_KEY, { minVersion: highest });
  highest = bundle.version;
  return bundle;
}

export async function accept(encoded: string, policyId: string) {
  const claim = canonicalDecode(Buffer.from(encoded, "base64"));
  const outputs = await verify(claim, await trustBundle(), BigInt(Math.floor(Date.now() / 1000)));
  if (claim.policy_id !== policyId) throw new Error(`claim is for ${claim.policy_id}`);
  return { outputs, nullifier: claim.nullifier };           // check the nullifier against your own store
}
```

Cache the bundle between claims rather than fetching it for each one, as the Go client below does.

## Go (Go 1.27 or later)

    go get github.com/Cr3dentials/zktls-consumers/consumers/go/zktlsclaim

```go
// startBundles pins the operator key and keeps a fresh bundle: every 60 s, the highest version only,
// and stale (Current returns an error) after 30 minutes without a fetch.
func startBundles(ctx context.Context, pinnedOperatorPEM []byte, trustBundleURL string) (*zktlsclaim.BundleClient, error) {
	key, err := zktlsclaim.ParseOperatorKey(pinnedOperatorPEM)
	if err != nil {
		return nil, err
	}
	bundles := zktlsclaim.NewBundleClient(trustBundleURL, key, nil, nil)
	go bundles.Run(ctx)
	return bundles, nil
}

func accept(bundles *zktlsclaim.BundleClient, encoded, policyID string) ([]zktlsclaim.TypedOutput, error) {
	raw, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, err
	}
	c, err := zktlsclaim.ClaimCanonicalDecode(raw)
	if err != nil {
		return nil, err
	}
	b, err := bundles.Current() // stale: refuse the claim
	if err != nil {
		return nil, err
	}
	outputs, err := zktlsclaim.VerifyClaim(c, b, uint64(time.Now().Unix()))
	if err != nil {
		return nil, err
	}
	if c.PolicyID != policyID {
		return nil, fmt.Errorf("claim is for %s", c.PolicyID)
	}
	return outputs, nil // then zktlsclaim.ConsumeNullifier(c, yourStore) if an account may prove this once
}
```

## Rust

    cargo add zktls-claim

```rust
use zktls_claim::bundle::{load_trust_bundle, OperatorKey};

let key = OperatorKey::from_pem_or_der(PINNED_OPERATOR_PEM.as_bytes())?;
let bundle = load_trust_bundle(&fetched_bundle_json, &key)?;
if bundle.version < highest_seen {
    return Err("a stale trust bundle".into());
}
highest_seen = bundle.version; // keep it across claims (and restarts)
let claim = zktls_claim::canonical_decode(&base64_decoded_claim)?;
let outputs = zktls_claim::verify(&claim, &bundle, now_unix_seconds)?;
if claim.policy_id != expected_policy_id {
    return Err("not the policy asked for".into());
}
```

## A claim bound to a holder key

A policy may bind its claim to a key the user holds. `verify` refuses such a claim. When your backend has
itself checked that the presenter controls that key (a challenge they signed), call `verifyWithHolder`
(TypeScript), `VerifyClaimWithHolder` (Go) or `verify_with_holder` (Rust) with that key instead.
