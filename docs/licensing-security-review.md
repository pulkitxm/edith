# Licensing, Anti-Piracy, Privacy, and Security Implementation Plan

Last reviewed: July 19, 2026

## Executive summary

Edith already has a meaningful licensing foundation. It uses server-side seat records,
machine-bound Ed25519 receipts, Keychain storage, protected downloads, and recurring
verification. This is substantially stronger than a local activation flag or an unsigned
license file.

The implementation is not yet ready to serve as the licensing boundary for a serious
commercial product. The most urgent problems are not the Ed25519 design. They are
inconsistencies between product promises and enforcement, incomplete production signing,
privacy disclosures that do not describe licensing data, unreliable rate limiting, missing
device-transfer workflows, reusable bearer credentials, and an offline policy that weakens
revocation.

No fully local desktop application can be guaranteed to remain uncracked. A determined
attacker controls the executable, process memory, system clock, local storage, and network
on their own Mac. A business-grade solution therefore has five goals:

1. Prevent ordinary key sharing and unauthorized installations.
2. Make binary patches expensive to create and maintain across releases.
3. Keep authoritative entitlement decisions on infrastructure the attacker does not
   control.
4. Detect and contain abuse without locking out legitimate customers.
5. Maintain truthful privacy, licensing, and availability commitments.

The confirmed commercial model has standard plans for one, three, or five active Macs.
The purchased plan determines the allowance, while a deployment environment variable acts
only as a global safety ceiling. Licenses are generated or updated by verified, idempotent
payment webhooks. The client never chooses its plan or machine allowance.

The recommended commercial architecture is a merchant of record or payment provider for
commerce, a version 2 licensing service or managed licensing platform for entitlements and
device management, and Developer ID-signed, Hardened Runtime, notarized distribution
through Sparkle. Keygen is the preferred managed licensing option. Cryptlex is the
strongest managed alternative when packaged client enforcement, multiple fingerprints, VM
detection, and offline activation justify its cost.

If Edith retains its custom licensing service, it should implement the version 2 design in
this document before relying on it for public sales.

## Confirmed commercial decisions

These decisions replace earlier fixed-seat recommendations:

- Standard plans allow one, three, or five active Macs.
- The allowance is determined by the purchased plan, not hard-coded in the app.
- A future custom plan may use an explicitly approved machine allowance.
- A deployment environment variable defines the maximum standard allowance accepted by the
  licensing service.
- A separate custom-plan ceiling should be introduced before custom allowances can exceed
  the standard ceiling.
- Licenses are generated from verified payment events.
- A browser checkout-success page never generates a license directly.
- The activation API never accepts `maxMachines`, plan price, or plan identity from the
  client.
- Existing licenses store an entitlement snapshot so changing a plan does not silently
  change previous purchases.
- Subscription upgrades or downgrades are applied only through verified payment events.
- Customers receive self-service device management and legitimate transfers.
- The customer-facing language uses "Macs" or "devices," not "MacBooks," so Mac mini,
  iMac, and Mac Studio installations are covered.

Suggested initial plan identifiers are:

| Internal plan ID | Active Macs | Intended use |
|---|---:|---|
| `individual_1` | 1 | One person on one active Mac |
| `personal_3` | 3 | One person across several Macs |
| `power_5` | 5 | One person with a larger device allowance |
| `custom` | Explicit override | Contracted or manually approved allowance |

Plan identifiers are stable internal values. Customer-facing names and prices may change
without changing the identifiers or the historical license record.

## Scope

This review covers:

- The licensing design in `docs/licensing.md`.
- The macOS license client, state, Keychain storage, receipt verifier, app gate, and helper
  gate.
- The activation, verification, DMG, and Sparkle endpoints.
- The Postgres license and machine records.
- API validation and rate limiting.
- Build signing and the release workflow.
- The public privacy policy and terms of service.
- Current official approaches from Apple, Keygen, Cryptlex, LicenseSpring, Lemon Squeezy,
  Thales, OWASP, and European privacy guidance.

This is a technical and product-risk review, not legal advice. Privacy policies, license
terms, refund rules, and regional compliance should be reviewed by qualified counsel before
launch.

## Current licensing architecture

The current flow is:

1. A customer receives an `EDITH-XXXX-XXXX-XXXX-XXXX` key.
2. The public installer sends the key, `IOPlatformUUID`, and optional hostname to the
   activation endpoint.
3. Postgres records a machine and enforces `max_machines` for that license.
4. The server returns a 30-day Ed25519-signed receipt bound to the submitted machine UUID.
5. Edith stores the full license key and receipt as generic-password items in the login
   Keychain.
6. The main app verifies the signature, machine UUID, and receipt expiry at startup.
7. The helper independently verifies the same receipt before starting its feature engines.
8. The main app re-verifies when it becomes active and on a 12-hour timer.
9. The full license key and machine UUID are sent in headers to protected DMG and Sparkle
   endpoints.
10. The backend verifies the pair before proxying private release assets.

## What the current system does well

### Signed receipts

Ed25519 is an appropriate choice for signed offline entitlements. The signing private key
remains on the server, while the client embeds only the verification key. Editing a receipt
or changing its machine value invalidates its signature.

### Server-side seat counting

Machines are recorded server-side, a unique database constraint prevents duplicate rows,
and the advisory transaction lock prevents concurrent activation requests from racing the
seat limit.

### Keychain storage

Using Keychain is better than storing credentials in preferences or a plain file. The key
and receipt are also configured not to synchronize through iCloud.

### Independent helper gate

The helper verifies a receipt before initializing feature engines. This creates another
enforcement point and prevents an unlicensed normal installation from receiving most Edith
functionality.

### Protected delivery and updates

The real application DMG and Sparkle appcast require a valid license and registered
machine. Sparkle also verifies its own update signature. This prevents anonymous access to
official release assets and reduces casual redistribution.

## Critical findings

### P0: The privacy policy contradicts actual licensing data collection

The privacy page says Edith collects nothing, has no telemetry, and that nothing is shared
because nothing is collected. The licensing backend stores:

- A persistent hardware UUID.
- The Mac hostname when supplied.
- License label and license association.
- First-seen and last-seen timestamps.
- IP addresses in hosting or security logs.
- Repeated verification and download activity.

A hardware identifier and its associated activation history can be personal data or
pseudonymous personal data. Hashing it does not automatically make it anonymous.

#### Required solution

- Update the privacy policy before public licensing begins.
- Disclose each licensing field, purpose, processor, retention period, and deletion path.
- Remove hostname collection unless customers need it in a device-management portal.
- Stop storing raw `IOPlatformUUID`.
- Minimize request logs and redact credentials.
- Publish a retention schedule for devices, activation events, security events, and failed
  requests.
- Provide a support path for access and deletion requests where required.

### P0: The terms contradict machine enforcement

The terms state:

> One license covers one person, on any number of their own Macs.

The database defines `max_machines` with a default of one, and activation rejects a new Mac
after that limit is reached. A customer can therefore be promised unlimited personally
owned Macs while the service enforces one Mac.

#### Required business rule

Use the allowance attached to the purchased plan:

- Individual plan: one active Mac.
- Personal plan: three active Macs.
- Power plan: five active Macs.
- Custom plan: an explicitly approved allowance within the configured custom ceiling.

Every plan includes:

- A visible device list.
- Self-service deactivation.
- Unlimited legitimate transfers.
- A reasonable transfer cooldown or abuse threshold.
- A support override for lost or broken Macs.
- One license per person for teams unless a team plan explicitly uses named or concurrent
  seats.

The same rule must appear in the checkout, receipt email, terms, activation screen,
settings, support documentation, license creation defaults, and backend policy.

The general terms should not hard-code one allowance. They should state that the purchased
plan defines the maximum number of active Macs. Each checkout plan and order confirmation
must display its exact allowance.

### P0: Perpetual-use language conflicts with recurring online enforcement

The terms promise use "for as long as you like." The implementation requires a fresh
receipt every 30 days for the helper to start normally. A permanent loss of the licensing
service could prevent a paying customer from using much of the product after a future
restart.

#### Required solution

Choose and document one of these models:

1. **Perpetual ownership with periodic abuse checks:** the customer owns the purchased
   version permanently, the app receives a long-lived signed ownership entitlement, and
   online checks control updates, transfers, and fraud revocation.
2. **Renewable online lease:** the entire product requires periodic verification and the
   terms clearly state the connection and grace-period requirements.
3. **Subscription:** continued use depends on an active billing entitlement, with a clearly
   stated offline grace period.

For Edith's current one-time-purchase positioning, the first model offers the clearest
customer promise. If stronger revocation is required, use a 14-day entitlement lease plus
a soft grace period up to 30 days, keep data export and license recovery available, and
publish a business-continuity commitment. A final perpetual unlock build or escrow plan
should exist if the licensing service is ever discontinued.

### P0: Expired receipts weaken revocation and create inconsistent behavior

An expired receipt becomes `needsRefresh`. The main app starts before verification and a
network failure does not re-gate it. A user can deliberately block the licensing host after
activation. The helper rejects an expired receipt only when it starts, so the main app and
helper can reach different licensing decisions.

#### Required solution

- Define a single signed entitlement state consumed by both processes.
- Define a bounded offline grace period.
- Track the last trusted server time and compare wall-clock movement with monotonic uptime.
- Treat time rollback as a risk signal.
- Recheck long-running helper processes when entitlements expire.
- Enter a limited recovery mode after grace instead of producing inconsistent behavior.
- Preserve access to local data, export, settings, purchase recovery, and support.

### P0: Production release hardening is not mandatory

The build scripts can fall back to ad hoc, self-signed, or development identities. The
release process does not currently prove that every public artifact has:

- A Developer ID Application signature.
- Hardened Runtime enabled.
- A secure timestamp.
- A successful Apple notarization result.
- A stapled notarization ticket.
- Strict verification of every nested executable and framework.

#### Required solution

- Separate development builds from production release builds.
- Make a production build fail unless a Developer ID Application identity is present.
- Sign all nested code inside-out with Hardened Runtime and secure timestamps.
- Notarize the final DMG with `notarytool`.
- Wait for notarization success and staple the ticket.
- Verify the app and helper with strict `codesign` checks.
- Verify Gatekeeper acceptance with `spctl`.
- Preserve Sparkle signing as an independent update-integrity layer.
- Produce and retain release provenance, checksums, and an artifact manifest.

### P0: Rate limiting is process-local

The activation and verification limiter uses an in-memory JavaScript `Map`. On a serverless
platform, each instance has separate state and cold starts erase that state. It is not a
reliable control against key guessing, API scripting, credential stuffing, or denial of
service.

#### Required solution

- Use Redis, Upstash, Vercel Firewall, or another distributed edge-backed limiter.
- Rate-limit by IP, route, keyed license digest, device ID, and failure class.
- Apply exponential backoff to repeated failures.
- Return generic errors that do not reveal whether a specific key exists.
- Alert on high failure rates, many device identities, unusual geography, and repeated seat
  exhaustion.
- Ensure trusted proxy configuration prevents callers from choosing the IP value used by
  the limiter.

### P0: Local deactivation does not release a seat

The Deactivate button deletes local Keychain state but does not delete or revoke the
machine record on the server. Customers replacing a Mac can permanently consume seats and
require manual database intervention.

#### Required solution

- Add an authenticated server-side device deactivation endpoint.
- Free the seat only after a valid device credential or verified customer recovery flow.
- Add a customer portal showing active devices and recent activity.
- Support "deactivate all devices" through email verification and stronger rate limits.
- Keep an audit event when a device is removed.
- Allow a support override with an operator audit trail.

## High-priority findings

### P1: The full license key is a reusable bearer credential

The full purchase key is stored in Postgres and Keychain and is repeatedly sent to verify,
download, and update endpoints. A database leak, proxy log, support capture, local Keychain
compromise, or accidental diagnostic log can expose a credential that remains valid until
the whole license is disabled.

#### Required solution

- Use the purchase key only for initial activation and explicit recovery.
- Store a keyed HMAC of the key for lookup, using a server-held pepper.
- Store only a non-sensitive suffix separately for support display.
- Issue a unique opaque refresh credential per activated device.
- Use short-lived access tokens for verification, downloads, and appcast access.
- Rotate and revoke device credentials without rotating the customer's purchase key.
- Redact authorization headers and license material from every log and error report.

Random license keys have high entropy, so a keyed deterministic HMAC is suitable for
database lookup and protects against an isolated database leak. Password hashing alone is
not the right lookup design for these random identifiers.

### P1: Raw hardware UUID is not proof of device identity

`IOPlatformUUID` is convenient and stable for honest clients, but the server accepts the
value supplied by the client. It cannot prove that the request originated on that physical
Mac. A modified client can supply any UUID. Repair, virtualization, future macOS changes,
and cloned environments can also produce support problems.

#### Required solution

- Generate an installation key pair during activation.
- Prefer a non-exportable Secure Enclave P-256 private key on supported Macs.
- Use a device-only Keychain key as the compatibility fallback.
- Store the public key, random device ID, status, and activation timestamps on the server.
- Require a signed server challenge for refresh, deactivation, and protected downloads.
- Treat a product-scoped hardware digest as a secondary risk signal, not the credential.
- Never use hostname as an authentication factor.

Proof of possession does not make the client unpatchable. It prevents simple credential
copying and lets the server verify that later requests possess the private key created at
activation.

### P1: Signing-key rotation is not designed

Receipts contain no schema version or key identifier, and the client trusts one public key.
Rotating the private key currently requires a coordinated client release and server change
with no clean overlap period.

#### Required solution

Every signed entitlement should include:

- Schema version.
- Signing key ID.
- License ID.
- Device ID and device public-key fingerprint.
- Product and plan.
- Feature entitlements.
- Issue, not-before, and expiry times.
- Policy version.
- Unique receipt ID.

The app should trust a small set of current and next public keys. Private signing keys
should live in a managed KMS or HSM when the selected algorithm and deployment allow it.
Maintain a documented overlap, rotation, compromise, and emergency-revocation procedure.

### P1: License status is too simple

The database exposes only an `active` boolean. A commercial licensing service needs to
distinguish business states and apply different recovery rules.

#### Required solution

Use explicit statuses such as:

- Active.
- Expired.
- Refunded.
- Chargeback.
- Suspended for review.
- Compromised and reissued.
- Manually revoked.
- Migrated.

Store a reason, effective time, actor, and audit event for every transition. Do not reveal
detailed fraud or risk reasons to the client.

### P1: Gated downloads do not prevent redistribution by themselves

Once an authorized customer downloads a DMG, they can copy it. Protected download URLs
reduce anonymous distribution and make updates controllable, but the application gate and
entitlement design remain the primary enforcement boundary.

#### Required solution

- Keep official assets gated with short-lived device access tokens.
- Maintain Developer ID signing and notarization so modified copies lose official trust.
- Optionally watermark customer-specific downloads only if the privacy, support, cache, and
  build-complexity costs are justified.
- Do not treat a private GitHub release or hidden API path as a security boundary.

## Threat model

| Threat | Current protection | Remaining risk | Target control |
|---|---|---|---|
| Customer shares an untouched key | Machine limit | Shared seats and support burden | Device portal, clear policy, anomaly rules |
| Customer shares the official DMG | Activation gate | Binary remains available for analysis | Signed entitlement, notarization, recurring checks |
| Receipt copied to another Mac | Machine UUID match | UUID spoofing in a modified client | Device key proof of possession |
| Local preference edited | Signed receipt gate | Binary branch can be patched | Distributed checks and server authorization |
| Licensing host blocked | Background verification | Expired receipt can still start main app | Explicit grace and limited recovery mode |
| System clock rolled back | Receipt expiry | Local time can be manipulated | Trusted-time anchor and rollback detection |
| Activation API scripted | Basic validation and local limiter | Distributed abuse bypass | Distributed rate limits and anomaly detection |
| License database leaked | Database access controls | Plaintext keys become reusable | Keyed HMAC storage and device credentials |
| Signing private key stolen | Server environment secrecy | Attacker can mint valid receipts | KMS/HSM, rotation, audit, incident plan |
| Binary patched | Multiple local gates | Determined attacker controls process | Hardened release, integrity checks, server value |
| Modified build redistributed | Apple signature is invalidated | Users can bypass Gatekeeper manually | Notarization, education, fast update cadence |
| Vendor service outage | Expired receipt fallback | Inconsistent behavior and customer lockout | Grace policy and business-continuity plan |

## Industry solution options

### Keygen

Keygen supports device activation limits, entitlements, signed offline license files,
private software distribution, Sparkle-oriented Mac delivery, managed cloud hosting, and a
self-hosted Community Edition.

**Best fit:** an independent Mac product that wants to stop owning licensing infrastructure
without giving up direct distribution.

**Caveats:** vendor dependency, integration work, and usage-based cloud pricing. Self-hosting
restores control but also restores infrastructure and security responsibility.

### Cryptlex

Cryptlex provides a native licensing library, multiple device fingerprints, signed and
encrypted local state, periodic synchronization, VM detection, offline activation,
entitlements, portals, and release management.

**Best fit:** products that value packaged client enforcement and offline licensing more
than minimal platform cost.

**Caveats:** monthly cost, SDK integration, native-library lifecycle, and vendor lock-in.
Its published Starter plan was $100 per month for 1,000 active activations when this review
was written.

### LicenseSpring

LicenseSpring supports node-locked, floating, metered, user-based, offline, and air-gapped
licensing with customer and reseller portals.

**Best fit:** later-stage B2B or enterprise editions with complex entitlements, offline
customers, floating seats, SSO, or reseller workflows.

**Caveats:** more platform and commercial process than Edith currently requires, with
sales-led pricing.

### Lemon Squeezy License API

Lemon Squeezy can generate license keys and activate, validate, and deactivate instances.
It also acts as merchant of record for checkout, taxes, refunds, and chargebacks.

**Best fit:** commerce and simple licensing for an independent software business.

**Caveats:** its license API is not a complete cryptographic offline-entitlement,
proof-of-possession, anti-tamper, or native client-hardening system. Use it for commerce and
provisioning, not as Edith's only security layer.

### Mac App Store and StoreKit

StoreKit `AppTransaction` provides Apple-signed purchase information and device verification
for App Store distribution.

**Best fit:** applications compatible with App Sandbox and App Store review requirements.

**Caveats:** Edith's helper, clipboard monitoring, global shortcuts, local file access,
screen-related features, and other broad integrations may make sandboxing difficult. A
separate feasibility spike is required before choosing this path.

### Thales Sentinel LDK

Sentinel offers software, cloud, and physical hardware licensing, including stronger
hardware-key models and commercial anti-reversing technology.

**Best fit:** expensive enterprise, industrial, engineering, or regulated products where
hardware dongles and licensing runtimes are acceptable.

**Caveats:** cost, integration complexity, runtime dependencies, support burden, and poor
fit for a consumer Mac utility.

## Commercial plan and payment architecture

### Sources of truth

The system has four different configuration layers with distinct responsibilities:

1. **Payment price:** identifies what the customer paid for.
2. **Plan catalog:** maps a trusted external price ID to an internal plan and allowance.
3. **License snapshot:** records the allowance granted to that specific purchase.
4. **Deployment ceiling:** prevents invalid plan or override values from entering the
   system.

The activation client is never a source of truth for any of these values.

### Environment configuration

Use an environment variable as the standard-plan safety ceiling:

```text
LICENSE_STANDARD_MAX_MACHINES_CAP=5
```

Keep future custom allowances disabled or constrained initially:

```text
LICENSE_CUSTOM_MAX_MACHINES_CAP=5
```

When custom contracts are introduced, the custom ceiling can be raised deliberately without
changing standard plans. The standard and custom ceilings must be positive integers.

Useful version 2 configuration includes:

```text
LICENSE_STANDARD_MAX_MACHINES_CAP=5
LICENSE_CUSTOM_MAX_MACHINES_CAP=5
LICENSE_ENTITLEMENT_TTL_DAYS=30
LICENSE_OFFLINE_GRACE_DAYS=30
LICENSE_ACCESS_TOKEN_TTL_MINUTES=30
LICENSE_SIGNING_ACTIVE_KEY_ID=<key-id>
LICENSE_KEY_LOOKUP_PEPPER=<secret>
PAYMENT_WEBHOOK_SECRET=<secret>
```

Environment variables are deployment controls, not per-customer entitlements. Do not define
one environment variable for every plan and do not let the client infer allowance from an
environment value.

Lowering a ceiling below an active plan or existing custom license must fail deployment
validation. It must never silently reduce a customer's purchased allowance. A ceiling
reduction requires an explicit data migration and customer-policy decision.

### Plan catalog

The trusted server maps external payment price IDs to internal plans:

| Payment price | Internal plan | Machine allowance |
|---|---|---:|
| Provider price for Individual | `individual_1` | 1 |
| Provider price for Personal | `personal_3` | 3 |
| Provider price for Power | `power_5` | 5 |

Store the exact external IDs in a restricted `plans` table seeded by migration. Do not add
a public plan-write endpoint. Plan changes use a reviewed migration or authenticated
operator workflow with an audit event. A checkout request may choose a published price ID,
but the server resolves the plan from its own mapping after receiving a verified payment
event.

At service startup, CI validation, and license issuance:

- Every active plan has a recognized provider and external price ID.
- Every standard allowance is an integer from one through the standard ceiling.
- No two active plans claim the same provider price unless an explicit migration permits it.
- Custom plans cannot be created through the public checkout path.
- Unknown or inactive prices fail closed and alert operators.

Do not silently clamp an allowance. If a plan says ten while the ceiling is five, license
generation must fail. Silent clamping can charge a customer for one entitlement and deliver
another.

Postgres `CHECK` constraints cannot read a deployment environment variable. Use database
constraints for structural invariants such as positive integer allowances, and enforce the
configurable standard and custom ceilings in the service, CI plan-catalog validation, and
operator workflow. If a static absolute database ceiling is added as a final safety layer,
set it above foreseeable custom contracts and change it only through a migration.

### Payment webhook flow

Licenses are generated from verified, idempotent payment events:

1. The customer completes checkout for a published price.
2. The payment provider sends a signed webhook.
3. The webhook endpoint verifies the signature against the raw request body.
4. The endpoint validates the provider event type and required identifiers.
5. A unique provider event ID prevents replay and duplicate processing.
6. The server maps the trusted external price ID to an internal plan.
7. The plan allowance is validated against the deployment ceiling.
8. One database transaction records the payment event, customer reference, license, and
   entitlement snapshot.
9. The generated purchase key is delivered once through the provider email, Edith email,
   or customer portal.
10. Retries return the original processing result rather than issuing another license.

The browser success page may show purchase status, but it must not mint a license or submit
its own machine allowance. Browser redirects can be forged or replayed.

### Payment event behavior

Map provider events into explicit license transitions:

| Payment event | License action |
|---|---|
| Successful one-time purchase | Create active license with plan snapshot |
| Successful subscription renewal | Extend subscription entitlement |
| Upgrade | Increase allowance and refresh entitlements |
| Scheduled downgrade | Record pending lower allowance |
| Refund | Apply the documented refund revocation policy |
| Chargeback | Suspend or revoke with a recoverable review path |
| Subscription cancellation | Keep active through paid-through date |
| Subscription expiration | Expire after paid-through date and grace policy |
| Repurchase or dispute reversal | Restore or reissue according to audit history |

Every transition records the provider event, previous status, new status, effective time,
and reason. Webhook handlers must be idempotent and safe when events arrive out of order.

### Plan upgrades

For an upgrade from one to three or five Macs:

- Increase the stored license allowance immediately after the verified payment event.
- Preserve every existing device.
- Issue a refreshed signed entitlement.
- Allow new activations up to the new limit.
- Show the updated allowance in the app and portal.

### Plan downgrades

For a downgrade from five to three or one Mac:

- Never deactivate devices randomly.
- Record the lower pending allowance and its effective time.
- Preserve existing devices during the documented transition period.
- Block new activations while active devices exceed the new allowance.
- Ask the customer to choose which devices to remove.
- Apply the new allowance after the device count is compliant or the documented deadline is
  reached.

One-time purchases normally do not downgrade. This flow mainly applies to subscriptions,
order corrections, or negotiated migrations.

### Custom allowances

Custom allowances use a privileged server or operator workflow, never a public activation
parameter. A custom license records:

- Base plan or contract reference.
- Explicit allowance override.
- Configured custom ceiling at validation time.
- Reason for the override.
- Order, agreement, or support reference.
- Operator or automated trusted actor.
- Timestamp and audit event.

Every custom allowance must satisfy:

```text
1 <= custom allowance <= LICENSE_CUSTOM_MAX_MACHINES_CAP
```

If custom licenses later need more than the standard five-device limit, raise only the
custom ceiling and preserve the standard ceiling.

### Seat counting and concurrency

The activation transaction must serialize seat decisions per license. The current advisory
transaction lock is a useful foundation. Version 2 should count only active device records,
not deactivated or replaced records.

The invariant is:

```text
active device count <= effective license allowance
```

During a scheduled downgrade, an explicit over-allowance state may exist temporarily. In
that state, existing selected devices continue under the transition policy, but no new
device can activate.

### Terms and checkout contract

The terms should use plan-based language instead of promising unlimited Macs or naming one
fixed allowance:

> A personal license may be active on the number of Macs included with the purchased plan.
> The applicable allowance is shown at checkout and in the order confirmation. Active Macs
> may be replaced through the device-management service, subject to reasonable safeguards
> against abuse. Team or company use requires the applicable user or team licenses unless
> the order states otherwise.

Each checkout card, order confirmation, purchase email, activation response, app settings
screen, and customer portal must show the exact purchased allowance.

The new database fields should not use a generic machine-count default. License issuance
must explicitly copy the validated plan allowance into the non-null entitlement snapshot.
This prevents a missing mapping from silently issuing a one-Mac license.

## Genuine-customer experience

### First activation

1. The customer purchases a plan.
2. The customer downloads the official notarized installer.
3. The customer enters the purchase key once or opens a verified activation link.
4. Edith creates its device ID and device key pair automatically.
5. The server registers the device within the purchased allowance.
6. Edith stores its credentials and starts immediately.

Normal customers should not need to understand device fingerprints, receipts, tokens,
Secure Enclave, or refresh schedules.

### Routine operation

- Refresh entitlements silently in the background.
- Refresh every 12 hours with randomized timing to avoid synchronized traffic.
- Do not show transient networking errors.
- Do not require a login on every launch.
- Do not require the purchase key after successful activation.
- Do not interrupt local features during a short server outage.

### Device-limit experience

When the allowance is full, the activation UI should show:

- The purchased plan.
- The number of active Macs allowed.
- A link to manage devices.
- A one-click path to remove an old Mac.
- A support recovery path for a lost or broken device.

It must not expose device names or purchase information until the customer has verified
ownership of the license.

### Offline experience

For the current one-time-purchase positioning:

- Use a 30-day renewable entitlement.
- Add a 30-day network-failure grace period.
- Retry silently throughout the normal entitlement period.
- Show no warning for temporary outages.
- Show a non-blocking warning only near the end of grace.
- Enter license recovery mode only after grace is exhausted.

Recovery mode keeps local data, settings, export, purchase recovery, and support available.
It never deletes data, corrupts files, or hides the reason for recovery.

### Risk-based responses

| Risk state | Customer response |
|---|---|
| Normal device and activity | Silent approval |
| New Mac within allowance | Normal activation |
| Device limit reached | Device-management flow |
| Unusual device churn | Purchase-email verification |
| Repeated invalid keys | Server delay with generic error |
| Copied device credential | Reject and rotate affected credentials |
| Confirmed revoked purchase | Clear purchase-status and recovery screen |
| Invalid app signature | Offer the official notarized installer |
| Licensing service outage | Continue through the published grace policy |

Risk signals should cause proportionate verification. They should not create unexplained
permanent bans for genuine customers.

## Recommended solution

### Preferred managed stack

- **Commerce:** Lemon Squeezy or another provider with signed, idempotent webhooks.
- **Licensing:** Keygen Cloud, with self-hosted Keygen CE evaluated as an exit path.
- **Higher client-resilience alternative:** Cryptlex.
- **Plans:** trusted one, three, and five-Mac plan mappings with entitlement snapshots.
- **Safety ceiling:** standard and custom environment caps validated by the server.
- **Distribution:** Developer ID, Hardened Runtime, notarized DMG, and Sparkle.
- **Customer identity:** verified purchase email or account plus active device list.
- **Device identity:** installation key pair and proof-of-possession challenges.
- **Offline entitlement:** signed, versioned, time-bounded license document.
- **Protected assets:** short-lived device access tokens.
- **Recovery:** self-service device transfers and audited support override.
- **Monitoring:** distributed rate limits, security events, and anomaly detection.

This option removes a large amount of high-risk licensing operations while preserving
Edith's direct Mac distribution and local-first product design.

### Custom version 2 architecture

If the custom service remains, use this protocol:

1. A verified commerce webhook maps the purchased price to a trusted plan.
2. The server validates the plan against the deployment ceiling and creates an idempotent
   license entitlement snapshot.
3. The customer receives a high-entropy purchase key or signs in through a verified
   purchase flow.
4. Edith generates a random device ID and P-256 key pair.
5. The private key remains in Secure Enclave where supported, with a device-only Keychain
   fallback.
6. Edith submits the purchase proof, device ID, public key, app version, and optional
   customer-selected device name.
7. The server consumes or validates the purchase proof, enforces the stored plan allowance,
   and records the device public key.
8. The server returns a signed entitlement, opaque device refresh credential, and short
   access token.
9. Edith stores the device credentials using explicit Keychain accessibility settings.
10. A refresh begins with a server nonce. Edith signs the nonce and request context using
    the device private key.
11. The server verifies proof of possession, license status, device status, app version,
    transfer policy, and risk signals.
12. The server returns a new signed entitlement and rotated device credential.
13. Downloads and appcast requests use short-lived access tokens rather than the purchase
    key.
14. Deactivation requires device proof or a verified customer recovery flow and frees the
    seat.
15. Plan upgrades, downgrades, refunds, and chargebacks are applied only through trusted
    payment or operator events.

## Proposed data model

### Plans

- Stable internal plan ID.
- Customer-facing name.
- Payment provider.
- External product and price IDs.
- Standard machine allowance.
- Billing model for one-time purchase or subscription.
- Active state.
- Created and updated times.

### Licenses

- License ID.
- Keyed purchase-key digest.
- Display suffix.
- Payment customer, order, and subscription references.
- Product and plan ID.
- Purchased machine-allowance snapshot.
- Optional custom machine override.
- Pending downgrade allowance and effective time.
- Status and status reason.
- Created, updated, and expiry times.
- Maintenance or update entitlement window.
- Policy version.

### Devices

- Device ID.
- License ID.
- Public key and public-key fingerprint.
- Optional product-scoped hardware digest.
- Optional customer-selected device name.
- Status.
- First activation, last verification, and deactivation times.
- Credential generation and rotation state.
- Last app version.

### Payment events

- Provider event ID with a unique constraint.
- Provider and event type.
- Payment customer, order, subscription, product, and price references.
- Raw-body integrity digest where useful for audit without retaining sensitive payloads.
- Processing state.
- Associated license ID.
- Received, processed, and effective times.
- Redacted error details.

### Device credentials

- Credential ID.
- Device ID.
- Keyed refresh-token digest.
- Generation number.
- Issued, rotated, expired, and revoked times.
- Revocation reason.

### Activation challenges

- Challenge ID.
- License or device lookup reference.
- Random nonce digest or protected nonce.
- Intended operation.
- Expiry time.
- Consumed time.
- Attempt count.

### Security events

- Event ID and type.
- License and device references.
- Coarsened or appropriately retained network context.
- Timestamp.
- Risk result.
- Actor for customer, operator, webhook, or automated actions.
- Redacted metadata with no license keys, refresh credentials, or private data not required
  for the investigation.

## Version 2 API contracts

All version 2 endpoints use HTTPS, `Cache-Control: no-store`, strict request schemas,
distributed rate limiting, bounded body sizes, generic authentication failures, and
credential-redacted logs.

### Activation challenge

`POST /api/v2/activation/challenge`

```json
{
  "licenseKey": "EDITH-XXXX-XXXX-XXXX-XXXX",
  "deviceId": "random-device-id",
  "devicePublicKey": "base64url-p256-public-key"
}
```

Successful response:

```json
{
  "challengeId": "challenge-id",
  "nonce": "base64url-random-nonce",
  "expiresAt": 1784462400
}
```

The response must not reveal the customer's plan or devices before activation proof is
complete.

### Activate device

`POST /api/v2/activation`

```json
{
  "licenseKey": "EDITH-XXXX-XXXX-XXXX-XXXX",
  "challengeId": "challenge-id",
  "deviceId": "random-device-id",
  "devicePublicKey": "base64url-p256-public-key",
  "signature": "base64url-challenge-signature",
  "appVersion": "1.0.0",
  "deviceName": "Pulkit's MacBook Pro"
}
```

Successful response:

```json
{
  "ok": true,
  "planId": "personal_3",
  "machinesUsed": 1,
  "maxMachines": 3,
  "entitlement": "signed-entitlement",
  "refreshCredential": "opaque-device-refresh-credential",
  "accessToken": "short-lived-access-token",
  "accessTokenExpiresAt": 1784460600
}
```

The server verifies that the challenge is unexpired, unconsumed, bound to the submitted
key and public key context, and signed by the submitted device private key. It then acquires
the per-license transaction lock before counting and inserting the device.

### Machine-limit response

```json
{
  "error": "machine_limit_reached",
  "machinesUsed": 3,
  "maxMachines": 3,
  "deviceManagementUrl": "https://edith.example/account/devices"
}
```

Return plan counts only after valid license ownership is established. Unknown, malformed,
or guessed keys receive a generic invalid-credential response.

### Refresh challenge

`POST /api/v2/devices/refresh/challenge`

```json
{
  "deviceId": "random-device-id",
  "refreshCredential": "opaque-device-refresh-credential"
}
```

### Refresh entitlement

`POST /api/v2/devices/refresh`

```json
{
  "deviceId": "random-device-id",
  "challengeId": "challenge-id",
  "signature": "base64url-challenge-signature",
  "appVersion": "1.0.0"
}
```

Successful refresh rotates the refresh credential and returns a new signed entitlement and
access token. The previous credential remains valid only for a short replay-safe overlap if
required for retry reliability.

### Deactivate current device

`POST /api/v2/devices/deactivate`

The request uses a device challenge signature. Successful deactivation revokes device
credentials, marks the device inactive, frees the seat, and creates an audit event.

### Protected downloads and appcast

Use:

```text
Authorization: Bearer <short-lived-access-token>
```

Do not send the purchase key or raw hardware UUID in download and update headers.

### Payment webhook

`POST /api/v2/payments/<provider>/webhook`

The endpoint reads the raw body, verifies the provider signature, records the unique event
ID, resolves the trusted price mapping, and applies the license transition transactionally.
No public request field can override `planId`, `maxMachines`, license status, or custom
allowance.

## Signed entitlement contract

The signed entitlement should include:

```json
{
  "version": 2,
  "keyId": "licensing-key-2026-01",
  "receiptId": "unique-receipt-id",
  "licenseId": "license-id",
  "deviceId": "device-id",
  "deviceKeyThumbprint": "sha256-public-key-thumbprint",
  "productId": "edith",
  "planId": "personal_3",
  "maxMachines": 3,
  "features": ["edith-core"],
  "issuedAt": 1784460000,
  "notBefore": 1784460000,
  "expiresAt": 1787052000,
  "policyVersion": 2
}
```

The signature covers the exact serialized payload. The client verifies the expected
algorithm, key ID, signature, product, device ID, device key thumbprint, issue window,
expiry, and policy version before trusting any field.

The plan allowance is included for customer display and audit. The server remains
authoritative for activation counting.

## Anti-tamper and crack-resistance strategy

Client resilience should be added in this order:

1. **Authentic production builds:** Developer ID, Hardened Runtime, notarization, stapling,
   strict verification, and signed updates.
2. **Server authority:** short-lived access tokens, device status, entitlement policy, and
   abuse decisions remain server-side.
3. **Proof of possession:** device private keys make copied credentials less useful.
4. **Distributed enforcement:** check entitlements at several high-value feature entry
   points in both the main app and helper.
5. **Runtime integrity:** validate the expected code signature and designated requirement
   before sensitive operations.
6. **Protected resources:** keep high-value rule data or service-backed functionality
   encrypted or server-delivered when product design permits.
7. **Release diversity:** change internal check locations and representations over time so
   one patch does not survive indefinitely.
8. **Selective obfuscation:** consider commercial Swift or native protection only after
   the preceding controls are complete.
9. **Authorized testing:** commission black-box license bypass and tamper-resistance reviews
   before launch and after material licensing changes.

Anti-debugging, VM detection, obfuscation, and RASP can raise attacker cost, but they can
also cause false positives, crash-reporting difficulty, accessibility problems, security
research friction, and support overhead. They must never replace server-side authorization,
cryptographic verification, secure releases, or customer recovery.

## Privacy requirements

The public privacy documentation should accurately state:

- Which licensing identifiers are collected.
- Whether the identifier is random, hardware-derived, or cryptographic.
- Why it is required.
- When activation and verification occur.
- Which processors receive the requests.
- What IP or security logging occurs.
- How long each class of data is retained.
- Whether device names are optional.
- How a customer removes a device or requests deletion.
- Which records must be retained for fraud, accounting, or legal reasons.
- That local product data remains local and is separate from licensing metadata.

Data minimization should be the default. Edith does not need a hostname to enforce a seat,
and the server does not need a raw hardware UUID when a random device key can establish
proof of possession.

## Operational security requirements

### Secrets

- Store signing keys in KMS or HSM-backed custody where feasible.
- Separate licensing receipt keys from Sparkle update keys.
- Use different credentials for development, preview, and production.
- Rotate database, GitHub, webhook, and signing credentials on a documented schedule.
- Restrict production access by role and retain operator audit events.

### Database

- Encrypt storage and backups.
- Use least-privilege database roles.
- Protect migrations and administrative scripts.
- Test restore procedures.
- Monitor unusual reads and bulk exports.
- Never place production license keys in test or preview environments.

### Webhooks and billing

- Verify every commerce webhook signature.
- Make webhook processing idempotent.
- Record event IDs to prevent replay.
- Model refunds, chargebacks, cancellations, and re-purchases explicitly.
- Delay destructive fraud action where an automated false positive could lock out a paying
  customer.

### Monitoring and incident response

- Alert on signing errors and unexpected receipt volume.
- Alert on activation spikes, geographic anomalies, and repeated device churn.
- Maintain runbooks for database compromise, purchase-key leaks, signing-key compromise,
  vendor outage, and malicious release publication.
- Support forced credential rotation without requiring every customer to buy again.
- Practice a signing-key rotation before it is needed in an emergency.

## Repository implementation map

The names below are proposed module boundaries. Final names should follow the repository's
existing conventions.

### Web and licensing service

- `apps/web/lib/schema.ts`: add plans, payment events, device credentials, challenges,
  license status fields, entitlement snapshots, and device public keys.
- `apps/web/drizzle/`: add forward-only migrations and backfills.
- `apps/web/lib/plans.ts`: trusted price-to-plan catalog and ceiling validation.
- `apps/web/lib/license-key.ts`: key generation, normalization, keyed lookup digest, and
  redacted display.
- `apps/web/lib/device-auth.ts`: P-256 public-key validation and challenge verification.
- `apps/web/lib/entitlement.ts`: version 2 payload construction, signing, and key IDs.
- `apps/web/lib/access-token.ts`: short-lived download and appcast authorization.
- `apps/web/lib/ratelimit.ts`: replace process memory with a distributed implementation.
- `apps/web/lib/payments/`: provider adapters, signature verification, price mapping, and
  idempotent event handling.
- `apps/web/app/api/v2/activation/`: challenge and activation routes.
- `apps/web/app/api/v2/devices/`: refresh and deactivation routes.
- `apps/web/app/api/v2/payments/`: provider webhook routes.
- `apps/web/app/api/v2/download/` and appcast route: bearer-token authorization.
- Customer account pages: license recovery, active-device list, and transfers.

### macOS shared licensing layer

- `DeviceIdentity.swift`: random device ID, P-256 key creation, Secure Enclave support, and
  Keychain fallback.
- `LicenseEntitlement.swift`: version 2 decoding and signature validation.
- `LicenseCredentialStore.swift`: purchase, refresh, access, and entitlement storage with
  explicit accessibility.
- `LicenseClient.swift`: challenge, activation, refresh, deactivation, and token exchange.
- `LicenseCoordinator.swift`: one state machine shared by the main app and helper.
- `LicenseRiskState.swift`: valid, refresh-needed, grace, recovery, revoked, and integrity
  states.
- Activation and settings UI: plan allowance, device count, recovery, and deactivation.
- Sparkle integration: short-lived bearer access without exposing the purchase key.

### Release pipeline

- Production build script: require Developer ID and Hardened Runtime.
- Release workflow: timestamp, notarize, staple, and verify every artifact.
- CI: reject production configuration that permits ad hoc signing.
- CI: validate plan catalog values against configured ceilings.
- CI: scan logs and fixtures for full license-key patterns and private credentials.

## Version 1 to version 2 migration

The migration should avoid forcing every existing customer to reactivate on one day.

### Database preparation

1. Add version 2 tables and nullable columns without removing version 1 fields.
2. Create a `legacy` plan for each distinct existing machine allowance or map existing
   values to the new standard plans when the commercial entitlement is known.
3. Copy each existing `max_machines` value into the license entitlement snapshot.
4. Create keyed purchase-key digests while plaintext keys are still available.
5. Verify every generated digest before switching lookups.
6. Add payment and customer references where known.

### Dual-protocol client rollout

1. Ship a client that can read version 1 and version 2 receipts.
2. Keep the existing receipt verification key trusted during the migration window.
3. On the next successful verification, create a device key pair and register it through a
   migration endpoint.
4. Issue a version 2 entitlement and device refresh credential.
5. Store the version 2 state before deleting version 1 local state.
6. Roll back safely to version 1 state if registration is interrupted.

### Server cutover

1. Support both lookup paths while clients migrate.
2. Stop creating new version 1 licenses first.
3. Move protected downloads and appcast access to short-lived bearer tokens.
4. Stop accepting full purchase keys in download headers after the adoption threshold and
   communicated deadline.
5. Remove raw hardware UUID collection after migrated devices have cryptographic identity.
6. Remove plaintext key columns only after all lookups use digests, support tools are
   updated, and encrypted backup retention is addressed.
7. Retire version 1 receipt issuance after supported clients have migrated.

### Migration safety

- Never delete a working version 1 credential until version 2 storage succeeds.
- Preserve the purchased machine allowance exactly.
- Do not infer a lower plan from current device usage.
- Make migration activation idempotent.
- Maintain an audited support recovery path.
- Test upgrade from every supported released Edith version.

## Required test matrix

### Plan and payment tests

- Each trusted price produces the correct one, three, or five-Mac snapshot.
- Unknown and inactive prices fail without creating a license.
- A plan above the standard ceiling fails and alerts.
- A custom override above the custom ceiling fails.
- Replayed payment events return the original license result.
- Concurrent duplicate webhooks create one license.
- Out-of-order renewal, cancellation, and refund events produce the correct final state.
- Upgrade increases allowance without disturbing existing devices.
- Downgrade never chooses devices for the customer.
- Lowering environment ceilings below active entitlements fails validation.

### Activation and device tests

- Activation succeeds at each plan allowance.
- The next distinct device is rejected at the limit.
- Re-activating the same device is idempotent.
- Concurrent final-seat activations produce only one success.
- Invalid challenge, signature, public key, and expired nonce fail.
- A consumed challenge cannot be replayed.
- A copied refresh credential fails without the device private key.
- Deactivation frees exactly one seat and revokes its credentials.
- Lost-device recovery requires verified ownership.
- Device names are never returned before ownership verification.

### Entitlement and time tests

- Valid signatures and fields succeed.
- Unknown algorithms and signing key IDs fail.
- Wrong product, device, or public-key thumbprint fails.
- Future not-before time fails.
- Expiry enters grace consistently in both processes.
- Wall-clock rollback becomes a risk state.
- Temporary network failure remains silent.
- Exhausted grace enters recovery without deleting data.

### Release and tamper tests

- Production release fails without Developer ID.
- Main app, helper, frameworks, and DMG pass strict signature checks.
- Notarization and stapling are verified.
- Modifying a sealed resource invalidates integrity checks.
- Re-signing with another identity is detected by the designated requirement.
- Modified builds cannot obtain protected server tokens.

### Privacy and logging tests

- No complete purchase key appears in logs.
- No refresh credential or access token appears in logs.
- Payment payloads are redacted according to retention rules.
- Raw hardware UUID and hostname are absent from version 2 requests unless an explicitly
  approved optional field is enabled.
- Customer deletion and device-removal workflows affect the documented records.

## Implementation plan

### Phase 0: Commercial consistency and release safety

Complete before public sales:

- Add the confirmed one, three, and five-Mac plan catalog.
- Add and validate the standard and custom machine-ceiling configuration.
- Align terms, checkout, UI, license defaults, and backend enforcement.
- Choose perpetual, lease, or subscription semantics.
- Document online verification and offline grace.
- Correct the privacy policy and data inventory.
- Remove unnecessary hostname and raw hardware-identifier storage.
- Enforce Developer ID signing, Hardened Runtime, timestamps, notarization, and stapling.
- Replace process-local rate limiting.
- Add real server-side deactivation and an operator recovery tool.
- Add production log redaction tests.

### Phase 1: Credential and entitlement redesign

- Select Keygen, Cryptlex, or the custom version 2 architecture.
- Integrate signed, idempotent commerce webhooks and trusted price mappings.
- Add plans, payment events, allowance snapshots, and custom-override audit fields.
- Add device key pairs and challenge signatures.
- Migrate plaintext keys to keyed digests.
- Issue per-device refresh credentials and short-lived access tokens.
- Add versioned signed entitlements and multi-key verification.
- Implement trusted-time and explicit grace behavior.
- Give both Edith processes one consistent entitlement decision.

### Phase 2: Customer and operator workflows

- Build a device-management portal.
- Add transfers, deactivate-all recovery, and support override.
- Add license status transitions and audit history.
- Add anomaly monitoring and incident alerts.
- Publish licensing, privacy, recovery, and service-availability documentation.

### Phase 3: Resilience testing and hardening

- Add code-signature checks around high-value paths.
- Strip unnecessary release symbols and diagnostic strings.
- Evaluate selective obfuscation after measuring the residual risk.
- Test blocked networking, copied Keychain items, clock rollback, VM cloning, API scripting,
  key leaks, stolen refresh credentials, patched gates, and modified distributions.
- Retest legitimate offline, repair, migration, reinstall, refund, and device-loss scenarios.
- Arrange an independent authorized security assessment.

## Launch acceptance criteria

The licensing system should not be considered launch-ready until:

- Terms, checkout promises, seat limits, and backend behavior match.
- Trusted payment prices produce exactly the intended one, three, or five-Mac entitlement.
- No public API can choose or increase a machine allowance.
- Plan and custom allowances cannot exceed their configured ceilings.
- Webhook replay cannot create duplicate licenses.
- Privacy documentation lists all licensing data and processors.
- A customer can replace a lost Mac without database intervention.
- Production artifacts cannot be released without Developer ID, Hardened Runtime,
  notarization, and stapling.
- Rate limits work across all production instances.
- Purchase keys never appear in application, proxy, hosting, or support logs.
- A database-only compromise does not reveal usable purchase keys.
- Device credentials can be individually revoked and rotated.
- Signing keys can rotate with an overlap window.
- Both app processes enforce the same expiry and grace decision.
- Service outage behavior matches the paid license promise.
- Refund, chargeback, transfer, and compromise flows are tested.
- Security alerts and response runbooks are operational.
- An authorized tamper test has been completed and remediated according to the agreed threat
  model.

## Open business decisions

- Are team licenses per named user, per device, or concurrent?
- Is the product perpetual, subscription-based, or perpetual with a paid update window?
- What offline period is contractually guaranteed?
- Does the application remain usable if Edith's licensing company or service closes?
- Is verified email acceptable, or must activation remain account-free?
- What monthly licensing-platform cost is acceptable?
- Which payment provider will issue the authoritative webhook events?
- When may the custom machine ceiling exceed five?
- Is a Mac App Store edition worth a sandbox feasibility study?
- Which future premium capabilities can remain server-authorized without weakening Edith's
  local-first privacy position?

## Recommendation

For the current product and business stage, use:

1. A payment provider with signed, idempotent webhooks for checkout, tax, refunds,
   chargebacks, upgrades, and purchase events.
2. Trusted standard plans for one, three, and five active Macs, with validated standard and
   custom deployment ceilings.
3. A plan allowance snapshot on every license and a privileged, audited custom override.
4. Keygen for licenses, device activations, signed offline entitlements, customer device
   management, and gated distribution, or the complete custom version 2 protocol in this
   document.
5. Direct Developer ID distribution with Hardened Runtime, notarization, stapling, and
   Sparkle.
6. Device key proof of possession instead of raw UUID authentication.
7. Silent background refresh, generous offline grace, and self-service transfers.
8. A documented perpetual-use and offline-continuity policy that matches the terms.

Choose Cryptlex instead of Keygen if packaged client protection, VM detection, and its
native offline workflow are worth the additional cost and native dependency.

If vendor cost is currently unacceptable, retain the Ed25519 foundation but complete Phase
0 and the custom version 2 credential protocol before treating the system as a serious
commercial licensing boundary.

## References

- [Apple: Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: Configuring the Hardened Runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime/)
- [Apple: AppTransaction](https://developer.apple.com/documentation/StoreKit/AppTransaction)
- [Apple: Protecting keys with the Secure Enclave](https://developer.apple.com/documentation/Security/protecting-keys-with-the-secure-enclave)
- [Apple: SecCodeCheckValidity](https://developer.apple.com/documentation/security/seccodecheckvalidity%28_%3A_%3A_%3A%29)
- [OWASP: Resilience against reverse engineering and tampering](https://mas.owasp.org/MASVS/11-MASVS-RESILIENCE/)
- [Keygen: Offline licensing](https://keygen.sh/docs/api/cryptography/)
- [Keygen: Licensing Mac applications](https://keygen.sh/for-mac-apps/)
- [Keygen: Pricing and self-hosting](https://keygen.sh/pricing/)
- [Cryptlex: Node-locked licensing](https://cryptlex.com/docs/node-locked-licenses/overview)
- [Cryptlex: Pricing](https://cryptlex.com/pricing)
- [LicenseSpring: License activation types](https://docs.licensespring.com/license-entitlements/license-activation-types)
- [Lemon Squeezy: License API](https://docs.lemonsqueezy.com/api/license-api)
- [Lemon Squeezy: Pricing](https://www.lemonsqueezy.com/pricing)
- [Thales: Sentinel LDK](https://docs.sentinel.thalesgroup.com/softwareandservices/ldk/)
- [European Commission: Application of the GDPR](https://commission.europa.eu/law/law-topic/data-protection/information-business-and-organisations/application-gdpr_en)
