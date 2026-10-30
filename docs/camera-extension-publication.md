# Camera package publication

The Extensions workflow packages Camera inside a containing host signed with the imported `MACOS_CERT_P12` Developer ID Application identity, then notarizes the package with `NOTARY_KEY`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`. It never substitutes ad hoc signing for a release. Development checks use a separate synthetic test identity and do not activate anything.

Camera ships with the `obs` carrier transport (`systemExtensionCarrier.transport` in `Extensions/manifest.json`). The carrier relays frames to the OBS virtual camera, so the package contains no system extension, needs no provisioning profiles and requests no system extension entitlement. Publication needs no repository secrets beyond the signing and notarization ones above.

## Native transport

The native transport, which installs Edith's own `com.pulkit.edith.camera` system extension, is not published. Building it for release requires `CAMERA_SIGN_TEAM` plus two provisioning profile files passed to `scripts/build-camera-carrier.mjs`:

- `CAMERA_CARRIER_PROFILE`: authorizes `com.pulkit.edith.cameraCarrier`, the system extension installation entitlement and the shared `<team>.com.pulkit.edith.camera` application group.
- `CAMERA_EXTENSION_PROFILE`: authorizes `com.pulkit.edith.camera` and the same application group.

Both profiles must be unexpired Developer ID profiles that belong to the host's signing team and include its certificate; a device-restricted development profile does not authorize installation on customer Macs. `make camera-profiles` uses the signed-in Xcode account and the configured `EDITH_TEAM_ID` and `EDITH_SIGN_IDENTITY` to request them. It does not install or activate Camera. The Extensions workflow does not supply these profiles, so switching Camera to the native transport also needs workflow changes.

After publishing, download Camera through a production host signed by the same team and verify the package and contained signatures. Camera activation, frame delivery and removal must then be tested on a Mac with synthetic media.
