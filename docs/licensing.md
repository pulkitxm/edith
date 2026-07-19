# Licensing and signed receipts

How Edith is licensed, how a machine is activated, and how the app proves it stays
licensed offline. This covers the whole path: the website APIs, the Postgres schema,
the signed receipt format, and the checks the macOS app and helper run.

## The pieces

- **edith.pulkit.page** (`apps/web`, Next.js on Vercel): the public site and a set of
  hidden `/api/v1` endpoints. It owns the Postgres database of licenses and machines,
  signs receipts, and proxies the private release DMG and Sparkle appcast.
- **Edith.app** (`apps/macos`, target `Edith`): the product. Gated behind activation at
  launch; verifies its receipt offline on every start.
- **Edith Installer.app** (`apps/macos`, target `EdithInstaller`): the small public
  download. Takes a key, activates the machine, downloads the real DMG through the
  licensed endpoint, opens it, and quits.
- **The signing keypair**: an Ed25519 pair. The private key lives only in the server env
  (`LICENSE_SIGNING_PRIVATE_KEY`) and never leaves it. The public key is compiled into the
  app and the helper. The server signs receipts; the app verifies them.

## Data model

Two Postgres tables (`apps/web/lib/schema.ts`, migration `apps/web/drizzle/0000_init.sql`):

- `licenses`: `id`, `key` (format `EDITH-XXXX-XXXX-XXXX-XXXX`, unique), `label` (who it was
  issued to), `max_machines` (default 1), `active` (default true), `created_at`.
- `machines`: `id`, `license_id`, `hardware_uuid`, `hostname`, `first_seen`, `last_seen`,
  with a unique constraint on `(license_id, hardware_uuid)`.

A seat is one distinct `hardware_uuid` under a license. Keys are minted by hand for now
with `bun scripts/create-license.ts --machines N --label "name"`; billing can create them
later.

## Machine identity

Every device is identified by its `IOPlatformUUID` (read via IOKit, no permission prompt).
It is stable across OS reinstalls, which is the property the whole seat model depends on:
a wiped and reinstalled Mac reports the same UUID, so re-activation updates the existing
row instead of consuming another seat.

## Endpoints

All under `apps/web/app/api/v1/`. None are linked from any page; responses are
`cache-control: no-store` and `x-robots-tag: noindex`, and `/api` is disallowed in
`robots.txt`. This keeps them undiscoverable from the website; they are meant to be called
only by the apps.

- `POST activate` `{key, hardwareUuid, hostname?}`: verifies the license is active, upserts
  the machine on `(license_id, hardware_uuid)` updating `last_seen`. Rejects with
  `403 {error: "license_limit_reached"}` only when the license already has `max_machines`
  distinct hardware UUIDs and this is a new one. Concurrent activations are serialized with
  a Postgres advisory lock so the seat count cannot be raced. On success returns
  `{ok: true, label, machinesUsed, maxMachines, receipt}`.
- `POST verify` `{key, hardwareUuid}`: returns `{ok: true, receipt}` only when the license
  is active and that machine is registered; otherwise `{ok: false}` with no receipt.
- `GET download/dmg`: header-authenticated (`x-edith-license`, `x-edith-machine`); on a
  valid, registered pair it streams the latest `Edith-v*.dmg` asset from the private GitHub
  release using the server's `GITHUB_TOKEN`. 403 when unlicensed.
- `GET appcast`: same header auth; streams the Sparkle feed and rewrites the DMG enclosure
  URLs to point back at `download/dmg`, so updates also flow through the licensed endpoint.
- `GET download/installer`: no license required; streams `EdithInstaller.dmg` from the
  latest release. This is what the website Download button links to. Returns a friendly
  holding page (503) when the asset is not published yet.

## The signed receipt

A receipt is the app's proof that the server said "this key, this machine, is good", which
the app can then check offline without calling home every launch.

Format (`apps/web/lib/receipt.ts`):

```
receipt = base64url(payloadJSON) + "." + base64url(ed25519_signature)
```

The payload is a JSON string with a fixed key order:

```json
{"machine":"<hardwareUuid>","label":"<license label>","issuedAt":<unix seconds>,"expiresAt":<unix seconds>,"keyLast4":"<last 4 of key>"}
```

`expiresAt` is `issuedAt + 30 days`. The server signs the exact UTF-8 bytes of that JSON
string with the Ed25519 private key, and base64url-encodes those same bytes as the first
segment. The app treats that first segment as the source of truth: it verifies the
signature against the bytes it decodes, so the two sides never disagree over serialization.

The server includes a fresh `receipt` in every successful `activate` and `verify`. The full
key is never logged, and only the last four characters go into the payload.

Signing key handling: the private key is stored as base64 of the 32 raw Ed25519 seed bytes.
Node builds a `KeyObject` by wrapping the seed in the fixed PKCS8 DER prefix
`302e020100300506032b657004220420` and calling `crypto.createPrivateKey`. Signing uses
`crypto.sign(null, message, key)` (Ed25519 takes no digest algorithm).

### A worked example

Activating the machine `4C4C4544-0037-5A10-8051-B4C04F503733` on a license labeled
`Pulkit` with key ending `2097` produces this payload (the exact bytes that get signed):

```json
{"machine":"4C4C4544-0037-5A10-8051-B4C04F503733","label":"Pulkit","issuedAt":1752930000,"expiresAt":1755522000,"keyLast4":"2097"}
```

That JSON string is base64url-encoded into the first segment, and its Ed25519 signature is
base64url-encoded into the second. Joined with a `.`, the receipt the server returns and the
app stores in the Keychain looks like this (one line, 261 characters here):

```
eyJtYWNoaW5lIjoiNEM0QzQ1NDQtMDAzNy01QTEwLTgwNTEtQjRDMDRGNTAzNzMzIiwibGFiZWwiOiJQdWxraXQiLCJpc3N1ZWRBdCI6MTc1MjkzMDAwMCwiZXhwaXJlc0F0IjoxNzU1NTIyMDAwLCJrZXlMYXN0NCI6IjIwOTcifQ.u87Eb4Gl5t52cG0lsqk8LexJZV3pKVixa3CaIznGkFxZNkV58mUJaEArA6ROzBpXc3PpIzKjeQYduM-_kehcAA
```

- Segment before the `.` is base64url of the payload above. Decoding it gives back the exact
  JSON string, which is what the app hashes for verification.
- Segment after the `.` is the 64-byte Ed25519 signature, base64url-encoded (86 characters,
  no padding).

At launch the app splits on the `.`, base64url-decodes the first segment back to bytes,
verifies the second segment is a valid Ed25519 signature of those bytes under the embedded
public key, then reads `machine` and `expiresAt` from the decoded JSON and checks the machine
matches this Mac and the receipt has not expired. No network is involved in that check. The
signature is deterministic for a given payload and key, so re-signing the same payload always
yields the same string; a different machine, label, key, or timestamp yields a completely
different signature.

## What the app does at launch

`apps/macos/Sources/EdithKit/Core/License.swift` stores the key and receipt as two separate
generic-password items in the login Keychain (service `com.pulkit.edith.license`, accounts
`license-key` and `license-receipt`, not iCloud-synced). `LicenseReceipt.swift` verifies a
receipt with CryptoKit `Curve25519.Signing.PublicKey` and the embedded public key, checking
three things: the signature is valid, the payload's `machine` equals this Mac's hardware
UUID, and `now < expiresAt`.

The gate (`MainAppDelegate.applicationDidFinishLaunching`) reads the offline status:

| Keychain state | Receipt check | Action |
|---|---|---|
| Key + receipt | valid | Start the app; routine background re-verify |
| Key + receipt | expired, or key present but receipt missing (transition) | Start the app; refresh the receipt in the background |
| Key + receipt | tampered / machine mismatch | Clear state, terminate helper, show activation |
| No key | n/a | Terminate helper, show activation |

Re-gating happens only on a definitive failure: a tampered receipt, or a server response
that explicitly says the license is invalid. A network error or a merely expired receipt
(with a key still present) never locks the user out; the app runs and refreshes in the
background. Re-verification runs on a 12-hour timer and when the app becomes active.

## The helper

The menu-bar helper (`apps/macos/Sources/EdithHelper`) runs its own gate at startup and
`exit(0)`s before initializing any feature engine, hotkey, observer, or IPC bridge if the
receipt is not valid. It verifies the receipt offline with the same embedded public key and
makes no network calls. The main app launches and relaunches it after activation, so an
unlicensed copy runs nothing at all.

## The installer flow

1. A visitor clicks Download; the site serves `EdithInstaller.dmg`.
2. The installer asks for a key, sends `activate` with this Mac's hardware UUID.
3. On success it downloads the real DMG through `download/dmg` (license headers), saves it
   to `~/Downloads`, opens it, and quits. It does not write the Keychain; Edith itself
   re-activates idempotently on first launch with the same UUID, so no extra seat is used.

## Updates

Sparkle in the main app is pointed at `edith.pulkit.page/api/v1/appcast` and sends the
license headers via `SPUUpdater.httpHeaders`. Only a licensed app can read the feed or
download an update, and the DMG is verified by Sparkle's own EdDSA signature (separate from
the license receipt keypair) before install-on-quit. See the release flow in the root
`Makefile` `release` target, which builds the DMG, signs the appcast, builds the installer
DMG, and uploads all three assets to the GitHub release.

## What this does and does not protect

It makes casual sharing useless: a shared DMG sits at the activation screen, an unregistered
machine is refused, and a leaked key burns one of its finite seats the moment it is used.
Because the receipt is signed and machine-bound, a local flag cannot simply be flipped to
fake activation; the binary itself would have to be patched. This is client-side enforcement,
so a determined attacker who patches and stays offline can still run a cracked copy; the
defense is raising the effort past where casual piracy happens, not making it impossible.

## Operations

- Server env vars (Vercel, Production and Preview): `DATABASE_URL`, `GITHUB_TOKEN`
  (read access to the private release repo), `GITHUB_REPO=pulkitxm/edith`, and
  `LICENSE_SIGNING_PRIVATE_KEY` (base64 of the 32-byte Ed25519 seed). If the signing key is
  missing, the activate and verify routes throw by design rather than issuing unsigned
  receipts.
- The public verification key is compiled into the app and helper. Rotating the keypair
  means shipping a new app build with the new public key and setting the new private key in
  the server at the same time.
- Mint a key: `cd apps/web && bun scripts/create-license.ts --machines N --label "name"`.

## Version 2

v2 replaces hardware-UUID activation with device keys and signed entitlements. v1 stays
fully working during the migration (dual protocol).

### Identity and cryptography

- Each install generates a random device id and a P-256 device key pair (Secure Enclave
  when available, software key otherwise). No hostname or hardware UUID is sent to the
  server in v2.
- Public key on the wire is base64url(SPKI DER); its thumbprint is
  base64url(SHA-256(SPKI DER)). Signatures are base64url DER ECDSA over SHA-256.
- License keys are stored server-side as lowercase hex
  HMAC-SHA256(`LICENSE_KEY_LOOKUP_PEPPER`, normalized key), plus `key_last4` for support.
- Entitlements are Ed25519-signed with a `keyId` (`LICENSE_SIGNING_KEY_ID`, default
  `edith-2026-07`); the client trusts a static (keyId, publicKey) list so keys can rotate.
- Each device holds a rotating refresh credential (`edithrc_` + base64url random) stored
  server-side as an HMAC digest; the previous generation stays valid 60 seconds after
  rotation. Downloads and appcast use a short-lived HMAC access token
  (`Authorization: Bearer`, default TTL 30 minutes) alongside the legacy headers until
  migration completes.

### Endpoints (`/api/v2`)

Every mutating call is challenge-response: the client requests a challenge
(`POST activation/challenge` or `POST devices/refresh/challenge`), then signs
`edith-v2.<purpose>.<challengeId>.<nonce>` with the device private key. Challenges expire
in 5 minutes and are single-use.

- `POST activation`: license key + signed challenge -> entitlement, refresh credential,
  access token. Seat-limit failures return `machine_limit_reached` only for a valid key;
  unknown keys get a generic `invalid_credentials`.
- `POST devices/migrate`: converts an existing v1 machines row (matched by hardware UUID)
  into a v2 device transactionally, consuming no extra seat.
- `POST devices/refresh`: rotates the credential and issues a fresh entitlement + token.
- `POST devices/deactivate`: revokes credentials, frees the seat, records a security event.
- `POST payments/lemonsqueezy/webhook`: HMAC-verified, idempotent on event id; creates
  licenses from orders and maps refunds/chargebacks to statuses.

All routes are no-store, strict-zod validated, and rate limited (per-ip, per-key/device,
and a stricter failure bucket; Upstash Redis in production, in-memory in dev).

### Entitlement format

`b64url(json) + "." + b64url(ed25519 sig)` with fixed key order:

```json
{"version":2,"keyId":"edith-2026-07","receiptId":"<uuid>","licenseId":"<uuid>","deviceId":"<device id>","deviceKeyThumbprint":"<b64url sha256 spki>","productId":"edith","planId":"personal_3","maxMachines":3,"features":["edith-core"],"issuedAt":0,"notBefore":0,"expiresAt":0,"policyVersion":2}
```

TTL defaults to 30 days (`LICENSE_ENTITLEMENT_TTL_DAYS`). The client checks version,
keyId, signature, productId, deviceId, thumbprint, notBefore, and expiry/grace.

### Plans and ceilings

Seeded plans: `individual_1` (1 Mac), `personal_3` (3), `power_5` (5), mapped from
LemonSqueezy price ids. `custom` allowances live on the license as an explicit override.
Env ceilings (`LICENSE_STANDARD_MAX_MACHINES_CAP`, `LICENSE_CUSTOM_MAX_MACHINES_CAP`,
both default 5) are validated at issuance: a plan allowance above its ceiling throws,
never clamps. The validated allowance is copied into a non-null `max_machines` snapshot
on the license.

### Statuses and seats

License statuses: `active | expired | refunded | chargeback | suspended | compromised |
revoked | migrated`, each with a `status_reason`; transitions land in `security_events`.
Active seats = active v2 devices + remaining v1 machines rows, counted inside the existing
per-license advisory-lock transaction. Deactivated and revoked devices never count.

### Client states and migration

The client derives one shared licensing state from the stored entitlement plus a trusted
time record (last server time, wall clock, monotonic anchor, boot session): `valid ->
refreshNeeded` (expired, inside the 30-day offline grace, silent until the last 5 days)
`-> recovery` (grace exhausted; data, export, settings, and support stay available while
feature engines stop), plus `revoked` and `noLicense`. Wall-clock rollback more than 24
hours behind the last server time caps the state at grace. Existing v1 installs call
`devices/migrate` once with their stored key and hardware UUID; on success the legacy
key/receipt files are retired and the machines row is deleted without consuming a seat.
