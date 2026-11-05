# Camera package publication

The Extensions workflow packages Camera inside a containing host signed with the imported `MACOS_CERT_P12` Developer ID Application identity, then notarizes the package with `NOTARY_KEY`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`. It never substitutes ad hoc signing for a release. Development checks use a separate synthetic test identity and do not activate anything.

The package contains `CameraCarrier.app` (`com.pulkit.edith.cameraCarrier`), which embeds Edith's own `com.pulkit.edith.camera` CoreMediaIO system extension under `Contents/Library/SystemExtensions`. Both bundles run the frozen Edith host executable and load their `cameraCarrier` and `cameraProvider` role payloads from `Contents/PlugIns`. The carrier holds the System Extension install entitlement; the provider is sandboxed. Both join the `<team>.com.pulkit.edith.camera` application group, which also prefixes the provider's CoreMediaIO Mach service.

## Provisioning profiles

Publishing requires two repository secrets containing base64-encoded Developer ID provisioning profiles:

- `CAMERA_CARRIER_PROVISIONING_PROFILE`: authorizes `com.pulkit.edith.cameraCarrier` with the System Extension capability.
- `CAMERA_EXTENSION_PROVISIONING_PROFILE`: authorizes `com.pulkit.edith.camera`.

Both must be unexpired Developer ID profiles that belong to the host's signing team and include its certificate. A device-restricted development profile does not authorize installation on other Macs. The workflow decodes them into its temporary directory, derives `CAMERA_SIGN_TEAM` from the signing identity, and `scripts/build-camera-carrier.mjs` validates each profile before embedding it. A missing secret fails the build with its name.

To create them, register both identifiers on the Apple Developer site under Certificates, Identifiers & Profiles, enable System Extension on the carrier identifier, then create a Developer ID profile for each with the Developer ID Application certificate. Store them with `base64 -i <file> | gh secret set <name>`.

After publishing, download Camera through a production host signed by the same team and verify the package and contained signatures. Camera activation, frame delivery and removal must then be tested on a Mac with synthetic media.
