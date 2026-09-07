import os
import shutil
import subprocess
import sys


def copy_fixture_file(source, destination):
    if sys.platform != 'darwin':
        return shutil.copy2(source, destination)
    if os.path.isdir(destination):
        destination = os.path.join(destination, os.path.basename(source))
    subprocess.run(
        ['/bin/cp', '-c', '-p', os.path.abspath(source), os.path.abspath(destination)],
        check=True, timeout=120)
    return destination
