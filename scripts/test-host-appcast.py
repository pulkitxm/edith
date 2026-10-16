import argparse
import base64
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

from verify_shipping_host import run

parser = argparse.ArgumentParser()
parser.add_argument('bundle', type=Path)
parser.add_argument('sparkle', type=Path)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='edith-synthetic-appcast-') as temporary:
    root = Path(temporary)
    app = root / 'Edith.app'
    run('ditto', str(args.bundle.resolve()), str(app))
    key = root / 'synthetic.key'
    key.write_bytes(base64.b64encode(bytes(32)))
    public = run('xcrun', 'swift', '-e', 'import CryptoKit; import Foundation; let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 32)); print(key.publicKey.rawRepresentation.base64EncodedString())').strip()
    plist_path = app / 'Contents/Info.plist'
    plist = plistlib.loads(plist_path.read_bytes())
    plist.update(SUPublicEDKey=public, CFBundleShortVersionString='1.2.3', CFBundleVersion='123')
    plist_path.write_bytes(plistlib.dumps(plist))
    run('codesign', '--force', '--sign', '-', str(app))
    archives = root / 'archives'
    archives.mkdir()
    dmg = archives / 'Edith.dmg'
    run('python3', 'scripts/package-host-dmg.py', str(app), str(dmg))
    tool = args.sparkle.resolve() / 'generate_appcast'
    run(str(tool), '--ed-key-file', str(key), '--download-url-prefix', 'https://github.com/synthetic/fixture/releases/download/v1.2.3/', str(archives))
    xml_path = archives / 'appcast.xml'
    xml = xml_path.read_text()
    assert 'https://github.com/synthetic/fixture/releases/download/v1.2.3/Edith.dmg' in xml
    signature = re.search(r'sparkle:edSignature="([^\"]+)"', xml).group(1)
    run(str(args.sparkle.resolve() / 'sign_update'), '--verify', '--ed-key-file', str(key), str(dmg), signature)
    assert '<sparkle:version>123</sparkle:version>' in xml
    assert '<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>' in xml
    assert int(re.search(r'length="(\d+)"', xml).group(1)) == dmg.stat().st_size
    print(json.dumps({'syntheticSignedAppcast': 'verified', 'releaseVersion': '1.2.3', 'build': '123', 'archiveBytes': dmg.stat().st_size}))
