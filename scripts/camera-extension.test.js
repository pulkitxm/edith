import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

function python(source) {
  const result = Bun.spawnSync(["python3", "-B", "-c", source], {
    stdout: "pipe",
    stderr: "pipe",
    timeout: 15000,
  });
  expect(result.stderr.toString()).toBe("");
  expect(result.exitCode).toBe(0);
  return JSON.parse(result.stdout.toString());
}

const buildScript = readFileSync("build.sh", "utf8");

test("the camera extension plist names a CoreMediaIO system extension per slot", () => {
  const result = python(`import json
from scripts.camera_extension import info
production = info('com.pulkit.edith', '1.2.3', '456', 'TEAM123')
development = info('com.pulkit.edith.dev.virtual-camera', '1.2.3', '456', '')
print(json.dumps(dict(production=production, development=development)))`);
  expect(result.production.CFBundleIdentifier).toBe("com.pulkit.edith.camera");
  expect(result.production.CFBundleExecutable).toBe("com.pulkit.edith.camera");
  expect(result.production.CFBundlePackageType).toBe("SYSX");
  expect(result.production.CFBundleDisplayName).toBe("Edith Camera");
  expect(result.production.CFBundleVersion).toBe("456");
  expect(result.production.CFBundleShortVersionString).toBe("1.2.3");
  expect(result.production.LSMinimumSystemVersion).toBe("14.0");
  expect(result.production.CMIOExtension).toEqual({
    CMIOExtensionMachServiceName: "TEAM123.com.pulkit.edith.camera",
  });
  expect(result.production.NSSystemExtensionUsageDescription).toContain(
    "Edith Camera",
  );
  expect(result.development.CFBundleIdentifier).toBe(
    "com.pulkit.edith.dev.virtual-camera.camera",
  );
  expect(result.development.CFBundleDisplayName).toBe(
    "Edith Camera (virtual-camera)",
  );
  expect(result.development.CMIOExtension.CMIOExtensionMachServiceName).toBe(
    "com.pulkit.edith.dev.virtual-camera.camera",
  );
});

test("the extension is sandboxed and its app group matches the mach service", () => {
  const result = python(`import json
from scripts.camera_extension import extension_entitlements, app_entitlements
print(json.dumps(dict(
    team=extension_entitlements('com.pulkit.edith', 'TEAM123'),
    adhoc=extension_entitlements('com.pulkit.edith', ''),
    app=app_entitlements('com.pulkit.edith', 'TEAM123'))))`);
  expect(result.team).toEqual({
    "com.apple.security.app-sandbox": true,
    "com.apple.security.application-groups": [
      "TEAM123.com.pulkit.edith.camera",
    ],
  });
  expect(result.adhoc).toEqual({ "com.apple.security.app-sandbox": true });
  expect(result.app).toEqual({
    "com.apple.developer.system-extension.install": true,
    "com.apple.application-identifier": "TEAM123.com.pulkit.edith",
    "com.apple.developer.team-identifier": "TEAM123",
  });
});

test("provisioning profiles must match the app, team, entitlement and date", () => {
  const result = python(`import datetime, json
from scripts.camera_extension import check_profile
now = datetime.datetime(2026, 9, 26, tzinfo=datetime.timezone.utc)
later = datetime.datetime(2027, 1, 1, tzinfo=datetime.timezone.utc)
earlier = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
entitlement = 'com.apple.developer.system-extension.install'
def profile(app, team='TEAM123', expiry=later, grants=True):
    entitlements = {'com.apple.application-identifier': app}
    if grants:
        entitlements[entitlement] = True
    return {'Entitlements': entitlements, 'TeamIdentifier': [team], 'ExpirationDate': expiry}
print(json.dumps(dict(
    valid=check_profile(profile('TEAM123.com.pulkit.edith'), 'com.pulkit.edith', 'TEAM123', entitlement, now),
    wildcard=check_profile(profile('TEAM123.com.pulkit.*', grants=False), 'com.pulkit.edith.camera', 'TEAM123', None, now),
    wrongApp=check_profile(profile('TEAM123.com.other'), 'com.pulkit.edith', 'TEAM123', entitlement, now),
    wrongTeam=check_profile(profile('TEAM123.com.pulkit.edith', team='OTHER'), 'com.pulkit.edith', 'TEAM123', entitlement, now),
    missing=check_profile(profile('TEAM123.com.pulkit.edith', grants=False), 'com.pulkit.edith', 'TEAM123', entitlement, now),
    expired=check_profile(profile('TEAM123.com.pulkit.edith', expiry=earlier), 'com.pulkit.edith', 'TEAM123', entitlement, now))))`);
  expect(result.valid).toEqual([]);
  expect(result.wildcard).toEqual([]);
  expect(result.wrongApp).toEqual([
    "profile is for TEAM123.com.other, not TEAM123.com.pulkit.edith",
  ]);
  expect(result.wrongTeam).toEqual([
    "profile belongs to another team than TEAM123",
  ]);
  expect(result.missing).toEqual([
    "profile does not grant com.apple.developer.system-extension.install",
  ]);
  expect(result.expired).toEqual(["profile expired on 2026-01-01"]);
});

test("build.sh embeds the extension and signs it before the app", () => {
  const assemble = buildScript.indexOf(
    'CAMERA="$APP/Contents/Library/SystemExtensions/$CAMERA_IDENTIFIER.systemextension"',
  );
  const thin = buildScript.indexOf('lipo "$binary" -thin arm64');
  const helper = buildScript.indexOf('sign "$HELPER"');
  const camera = buildScript.indexOf(
    'sign "$CAMERA" "$CAMERA_ENTITLEMENTS" "$CAMERA_RUNTIME"',
  );
  const app = buildScript.indexOf('sign "$APP" "$APP_ENTITLEMENTS"');
  expect(assemble).toBeGreaterThan(-1);
  expect(thin).toBeGreaterThan(assemble);
  expect(camera).toBeGreaterThan(helper);
  expect(app).toBeGreaterThan(camera);
  expect(buildScript).toContain('CAMERA_IDENTIFIER="$APP_IDENTIFIER.camera"');
  expect(buildScript).toContain(
    'cp "$EDITH_APP_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"',
  );
  expect(buildScript).toContain(
    'cp "$EDITH_CAMERA_PROVISIONING_PROFILE" "$CAMERA/Contents/embedded.provisionprofile"',
  );
});

test("the install entitlement is only added with a verified profile", () => {
  const profileBlock = buildScript.slice(
    buildScript.indexOf('APP_ENTITLEMENTS=""'),
    buildScript.indexOf('sign "$APP" "$APP_ENTITLEMENTS"'),
  );
  expect(profileBlock).toContain(
    'if [ -n "${EDITH_APP_PROVISIONING_PROFILE:-}" ]; then',
  );
  expect(profileBlock).toContain(
    "com.apple.developer.system-extension.install",
  );
  expect(profileBlock.indexOf("camera_extension.py profile")).toBeLessThan(
    profileBlock.indexOf("camera_extension.py app-entitlements"),
  );
});

test("profiles must include this Mac and the signing certificate", () => {
  const result = python(`import datetime, hashlib, json
from scripts.camera_extension import check_profile
now = datetime.datetime(2026, 9, 26, tzinfo=datetime.timezone.utc)
later = datetime.datetime(2027, 1, 1, tzinfo=datetime.timezone.utc)
cert = b'certificate-der'
digest = hashlib.sha1(cert).hexdigest().upper()
def profile(devices=None, all_devices=False):
    value = {'Entitlements': {'com.apple.application-identifier': 'TEAM123.com.pulkit.edith'},
             'TeamIdentifier': ['TEAM123'], 'ExpirationDate': later, 'DeveloperCertificates': [cert]}
    if devices is not None:
        value['ProvisionedDevices'] = devices
    if all_devices:
        value['ProvisionsAllDevices'] = True
    return value
print(json.dumps(dict(
    included=check_profile(profile(['MAC-1']), 'com.pulkit.edith', 'TEAM123', None, now, 'MAC-1', [digest.lower()]),
    otherMac=check_profile(profile(['MAC-2']), 'com.pulkit.edith', 'TEAM123', None, now, 'MAC-1', [digest]),
    allDevices=check_profile(profile([], True), 'com.pulkit.edith', 'TEAM123', None, now, 'MAC-1', [digest]),
    otherCert=check_profile(profile(['MAC-1']), 'com.pulkit.edith', 'TEAM123', None, now, 'MAC-1', ['00' * 20]),
    noChecks=check_profile(profile(['MAC-2']), 'com.pulkit.edith', 'TEAM123', None, now))))`);
  expect(result.included).toEqual([]);
  expect(result.otherMac).toEqual(["profile does not include this Mac"]);
  expect(result.allDevices).toEqual([]);
  expect(result.otherCert).toEqual([
    "profile does not include the signing certificate",
  ]);
  expect(result.noChecks).toEqual([]);
});

test("discovery prefers an exact, valid, longest-lived profile", () => {
  const result = python(`import datetime, json, os, plistlib, tempfile
from scripts.camera_extension import find_profile
now = datetime.datetime(2026, 9, 26, tzinfo=datetime.timezone.utc)
def date(year):
    return datetime.datetime(year, 1, 1, tzinfo=datetime.timezone.utc)
with tempfile.TemporaryDirectory() as folder:
    def save(name, app, expiry, grants=True, devices=('MAC-1',)):
        entitlements = {'com.apple.application-identifier': app}
        if grants:
            entitlements['com.apple.developer.system-extension.install'] = True
        with open(os.path.join(folder, name), 'wb') as handle:
            plistlib.dump({'Entitlements': entitlements, 'TeamIdentifier': ['TEAM123'],
                'ExpirationDate': expiry, 'ProvisionedDevices': list(devices)}, handle)
    save('wildcard.provisionprofile', 'TEAM123.*', date(2030))
    save('short.provisionprofile', 'TEAM123.com.pulkit.edith', date(2027))
    save('long.provisionprofile', 'TEAM123.com.pulkit.edith', date(2028))
    save('expired.provisionprofile', 'TEAM123.com.pulkit.edith', date(2025))
    save('other-mac.provisionprofile', 'TEAM123.com.pulkit.edith', date(2031), devices=('MAC-9',))
    save('no-entitlement.provisionprofile', 'TEAM123.com.pulkit.edith', date(2032), grants=False)
    with open(os.path.join(folder, 'broken.provisionprofile'), 'w') as handle:
        handle.write('not a plist')
    decode = lambda path: plistlib.load(open(path, 'rb'))
    entitlement = 'com.apple.developer.system-extension.install'
    found = find_profile('com.pulkit.edith', 'TEAM123', entitlement, [folder], decode, now, 'MAC-1')
    camera = find_profile('com.pulkit.edith.camera', 'TEAM123', None, [folder], decode, now, 'MAC-1')
    none = find_profile('com.other.app', 'OTHER', None, [folder], decode, now, 'MAC-1')
    print(json.dumps(dict(found=os.path.basename(found), camera=os.path.basename(camera), none=none)))`);
  expect(result.found).toBe("long.provisionprofile");
  expect(result.camera).toBe("wildcard.provisionprofile");
  expect(result.none).toBeNull();
});

test("the profile project asks Xcode for both identifiers and capabilities", () => {
  const result = python(`import json, os, plistlib, tempfile
from scripts.camera_extension import write_project
with tempfile.TemporaryDirectory() as folder:
    project = write_project(folder, 'com.pulkit.edith', 'TEAM123')
    text = open(os.path.join(project, 'project.pbxproj')).read()
    app = plistlib.load(open(os.path.join(folder, 'App.entitlements'), 'rb'))
    camera = plistlib.load(open(os.path.join(folder, 'Camera.entitlements'), 'rb'))
    source = open(os.path.join(folder, 'App.swift')).read()
    print(json.dumps(dict(text=text, app=app, camera=camera, source=source, name=os.path.basename(project))))`);
  expect(result.name).toBe("EdithProfiles.xcodeproj");
  expect(result.text).toContain(
    "PRODUCT_BUNDLE_IDENTIFIER = com.pulkit.edith;",
  );
  expect(result.text).toContain(
    "PRODUCT_BUNDLE_IDENTIFIER = com.pulkit.edith.camera;",
  );
  expect(result.text).toContain("DEVELOPMENT_TEAM = TEAM123;");
  expect(result.text).toContain("ProvisioningStyle = Automatic;");
  expect(result.app).toEqual({
    "com.apple.developer.system-extension.install": true,
  });
  expect(result.camera["com.apple.security.application-groups"]).toEqual([
    "TEAM123.com.pulkit.edith.camera",
  ]);
  expect(result.source).toContain("@main");
});

test("build.sh looks for profiles only when installing locally", () => {
  const discovery = buildScript.slice(
    buildScript.indexOf('if [ "$INSTALL" = 1 ] && [ -n "$TEAM_ID" ]; then'),
    buildScript.indexOf(
      'CAMERA_ENTITLEMENTS="$DERIVED/EdithCamera.entitlements"',
    ),
  );
  expect(discovery).toContain(
    ': "${EDITH_APP_PROVISIONING_PROFILE:=$(python3 scripts/camera_extension.py find',
  );
  expect(discovery).toContain(
    ': "${EDITH_CAMERA_PROVISIONING_PROFILE:=$(python3 scripts/camera_extension.py find',
  );
  expect(discovery).toContain('"$SIGN_IDENTITY"');
  expect(buildScript.indexOf("camera_extension.py find")).toBeLessThan(
    buildScript.indexOf("camera_extension.py profile"),
  );
  const makefile = readFileSync("Makefile", "utf8");
  expect(makefile).toContain(
    "camera-profiles:\n\t./scripts/camera-profiles.sh",
  );
  const profiles = readFileSync("scripts/camera-profiles.sh", "utf8");
  expect(profiles).toContain("-allowProvisioningUpdates");
  expect(profiles).toContain("-allowProvisioningDeviceRegistration");
  expect(profiles).toContain("signing_keychain_close");
});
