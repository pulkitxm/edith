import argparse
from pathlib import Path
import subprocess
import tempfile
import time

from verify_shipping_host import inspect_host, run

parser = argparse.ArgumentParser()
parser.add_argument('bundle', type=Path)
parser.add_argument('destination', type=Path)
args = parser.parse_args()
inspect_host(args.bundle, release=True)
destination = args.destination.resolve()
destination.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='edith-dmg-') as temporary:
    root = Path(temporary)
    run('ditto', str(args.bundle.resolve()), str(root / 'Edith.app'))
    (root / 'Applications').symlink_to('/Applications')
    kilobytes = int(run('du', '-Ask', str(root)).split()[0])
    destination.unlink(missing_ok=True)
    run('hdiutil', 'create', '-volname', 'Edith', '-fs', 'HFS+', '-size', f'{kilobytes + kilobytes // 4 + 65536}k', '-srcfolder', str(root), '-format', 'ULMO', str(destination))
    try:
        for attempt in range(5):
            try:
                run('hdiutil', 'verify', str(destination))
                break
            except subprocess.CalledProcessError:
                if attempt == 4:
                    raise
                time.sleep(2)
        mounted = root / 'mounted'
        mounted.mkdir()
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mounted), str(destination))
        try:
            assert (mounted / 'Applications').readlink() == Path('/Applications')
            inspect_host(mounted / 'Edith.app', release=True)
        finally:
            run('hdiutil', 'detach', str(mounted))
    finally:
        subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister', '-u', str(root / 'Edith.app')], capture_output=True)
print('Verified empty-host DMG: ' + destination.name)
