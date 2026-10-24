# Receiving a tree run's result

`runTree` never hands the platform's data to the app. When a run ends, one result is posted to the
`resultUrl` the backend issued for the run, and the app receives only a summary. For a pack without an
attest block the SDK posts it from the phone. For a pack that attests, the attester posts it: the phone
hands the run to that enclave once the user has signed in and the observed collection is done, and the
app may close ([a result from the attester](#a-result-from-the-attester)). This page is for the backend
behind that URL: what arrives, and how to check it.

With `verify`, that URL is our backend's, and your server gets our signed webhooks instead
([your server: the webhooks](integration-ios.md#your-server-the-webhooks)). This page is for a lab run's
result URL ([integration-packs.md](integration-packs.md)), and for checking the attester's claim a
webhook carries, [below](#checking-a-result-typescript-node-22-or-later).

## What arrives

One result per run. The SDK sends its `POST` once and never retries it; the attester's is the same
request, retried as [below](#a-result-from-the-attester):

| | |
|---|---|
| `Content-Type` | `application/x-protobuf` |
| `Content-Encoding` | `gzip`, applied once |
| `Authorization` | `Bearer <resultToken>`: the token you issued with the URL |
| Body | one `TreeRunResult`, defined by [`proto/tree_result.proto`](../proto/tree_result.proto) |

The SDK sends no other header and no cookie. It does not send a result over 5 MB gzipped or 32 MB
inflated; enforce the same caps on your side, the inflated one while you inflate, so a crafted body
cannot make you allocate more.

`TreeRunResult` carries:
- the pack's id, version and SHA-256, as the app pinned them;
- `status`: `SUCCESS`, `PARTIAL` (a cap ended a source before it said it was done) or `ERROR` (the
  pack's tree failed: `error` says why, in the pack's words);
- one `Source` per result key, `{ store_as, evidence, json, pages, rows, bytes, complete }`;
- `claim`: for a pack that attests, the attester's signed claim in its canonical encoding;
- the failures on the way, the run's statistics and the SDK's version.

A run that the SDK stopped (a refused pack, a cancel, an upload the attester did not accept) posts
nothing; the app gets an error instead.

## A result from the attester

For a pack that attests, the phone uploads the session and its observed result to the attester, and
posts nothing itself once the attester accepts them (the app's summary says `handedOff`). The attester
then reads the platform from our cell and posts the run's result to the same `resultUrl`, with the same
token, headers, encoding and caps:

- **With a read**, the phone's observed sources come first, in their order, then the attested source
  under the pack's key for it; `claim` is the attester's claim, and `status` is `SUCCESS`, or `PARTIAL`
  when a cap ended a source.
- **With a failed read**, `status` is `ERROR`, `error` gives the read's reason, `claim` is empty, and the
  observed sources are still there.
- **A result over the caps** once the attested source is added is not sent: you receive `ERROR` with no
  sources and `error` set to `result over the size cap`.
- `finished_at_ms` is when the attester posts.

The attester makes up to 5 attempts, 1 s after its read ends and then 5 s, 30 s, 120 s and 600 s after
the one before, and stops at a 4xx answer other than 408 or 429. Any 3xx stops the retries too: the
attester never follows a redirect, so answer at the `resultUrl` you issued. A retry can follow an
attempt you accepted whose answer was lost, so answer a result you already hold as you answered it the
first time (409 for a receipt already accepted). If no attempt arrives, the run's deadline ends it on your side:
treat a handed-off run that has not reported by then as failed.

The claim's signer is the attester, a member of the trust bundle that publishes a claim key, rather than a
verifier; `verifyV2` and `verifyAttestedEvidence` below check it the same way, in a claim library version
that accepts an attester's claim: the first released with the attester, and every later one.
`@zktls/claim`, `zktlsclaim` and `zktls-claim` share one version. An older version refuses the claim
with `UnknownVerifier`, so your backend answers 422, the attester stops retrying, and the run's result
is lost. Upgrade the library before your app runs a pack that attests.

## Reading the evidence tags

| `evidence` | What `json` holds | What to store |
|---|---|---|
| `OBSERVED` | The source as the pack collected it in the user's page, compact JSON | `json`, labelled observed: nothing vouches for it |
| `ATTESTED` | The claim's outputs, `[{"name", "value"}]`, for reading only | the outputs of the claim you verified, labelled attested, never these bytes |

A result with an `ATTESTED` source must carry a claim, and the claim must verify; refuse it otherwise.

## Checking a result (TypeScript, Node 22 or later)

    npm install @zktls/claim @bufbuild/protobuf

Generate the message types from `tree_result.proto` with `buf generate` (protobuf-es), and pin the
operator key and the attested policy per platform in your configuration, as for any claim
([Verifying a claim on your backend](backend-verification.md)).

```typescript
import { gunzipSync } from "node:zlib";
import { fromBinary } from "@bufbuild/protobuf";
import { canonicalDecodeV2, loadTrustBundle, verifyAttestedEvidence, verifyV2, type TrustBundle } from "@zktls/claim";
import { Evidence, TreeRunResultSchema } from "./gen/tree_result_pb.js"; // generated from tree_result.proto

const OPERATOR_KEY = process.env.ZKTLS_TRUST_OPERATOR_KEY!; // PEM, pinned in your configuration
let highest = 0n;

async function trustBundle(): Promise<TrustBundle> {
  const json = await (await fetch(process.env.ZKTLS_TRUST_BUNDLE_URL!)).text();
  const bundle = loadTrustBundle(json, OPERATOR_KEY, { minVersion: highest });
  highest = bundle.version;
  return bundle;
}

// After your route has checked the Bearer token against the run it issued: 401 otherwise.
export async function ingest(body: Buffer, attestedPolicyId: string) {
  if (body.length > 5 << 20) throw new Error("413: over 5 MB");
  const run = fromBinary(TreeRunResultSchema, gunzipSync(body, { maxOutputLength: 32 << 20 }));

  let verified = undefined;
  if (run.sources.some((s) => s.evidence === Evidence.ATTESTED)) {
    const claim = canonicalDecodeV2(run.claim);
    const bundle = await trustBundle();
    const outputs = await verifyV2(claim, bundle, BigInt(Math.floor(Date.now() / 1000)));
    verifyAttestedEvidence(claim, bundle, "KOnly"); // the enclave's own signature over these figures
    if (claim.policy_id !== attestedPolicyId) throw new Error(`422: claim is for ${claim.policy_id}`);
    if (claim.evidence.kind !== "Attested") throw new Error("422: not an attested claim");
    // Refuse a receipt you have already accepted: key claim.evidence.receipt_digest for a day.
    verified = outputs;
  }

  const collected: Record<string, unknown> = {};
  const evidence: Record<string, "observed" | "attested"> = {};
  for (const s of run.sources) {
    const attested = s.evidence === Evidence.ATTESTED;
    collected[s.storeAs] = attested ? verified : JSON.parse(new TextDecoder().decode(s.json));
    evidence[s.storeAs] = attested ? "attested" : "observed";
  }
  return { status: run.status, error: run.error, collected, evidence };
}
```

`verifyV2` checks the claim's signature (the attester's), the trust bundle and the time;
`verifyAttestedEvidence` checks that the figures are the ones the enclave signed, under the attester set
you pin (`KOnly`). Both throw on failure: answer 422. Cache the bundle between results rather than fetching it for each one, as the Go
client in the claim guide does.

## Answers the SDK reports

The app's summary says whether the phone's post arrived (`delivered`), and for any status but 2xx,
which one (`deliveryError`, [errors](errors.md#a-result-that-did-not-arrive)); after a hand-off it says
`handedOff`, and only your backend learns how the attester's post went. Answer 401 for a bad token, 409
for a receipt already accepted, 413 for a body over a cap, 400 for one that does not decode and 422 for
a claim that does not verify: the attester stops retrying at any of them.
