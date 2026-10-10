# Camera package publication

The Extensions workflow packages Camera around a frozen production host signed with the imported `MACOS_CERT_P12` identity. It derives `CAMERA_SIGN_TEAM` from that host's signature and passes the matching profiles to the carrier builder. It never substitutes ad hoc signing for a release. Development checks use a separate synthetic test identity and do not activate the system extension.

Publication requires two repository secrets containing base64-encoded CMS provisioning profiles:

- `CAMERA_CARRIER_PROVISIONING_PROFILE`: authorizes `com.pulkit.edith.cameraCarrier`, the system extension installation entitlement and the shared `<team>.com.pulkit.edith.camera` application group.
- `CAMERA_EXTENSION_PROVISIONING_PROFILE`: authorizes `com.pulkit.edith.camera` and the same application group.

Both profiles must be unexpired, belong to the host's signing team, include the imported certificate and permit the build Mac when device restrictions apply. The workflow writes private profile files into its temporary directory, validates their metadata before packaging, and removes them with the frozen host at job completion. Missing secrets fail with their exact names.

`make camera-profiles` uses the existing signed-in Xcode account and configured `EDITH_TEAM_ID` and `EDITH_SIGN_IDENTITY` to request the carrier and provider profiles. It does not install or activate Camera. Local preparation can also receive existing files through `CAMERA_CARRIER_PROFILE` and `CAMERA_EXTENSION_PROFILE`.

Apple Development signing can satisfy the marketplace's same-team signature check, but a device-restricted development profile does not authorize installation on arbitrary customer Macs. General distribution requires an appropriate distribution signing identity and profiles. Notarization additionally requires the workflow's `NOTARY_KEY`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` credentials. A successful package build alone does not establish Gatekeeper acceptance or Camera activation on another Mac.

After a real workflow publishes all packages and the signed catalog, verify the public catalog signature against the configured public key, download Camera through a production host signed by the same team, and verify the package and contained signatures. Camera activation, user approval, frame delivery and removal must then be tested on an authorized Mac with synthetic media. These OS operations are separate from the build fixtures.
