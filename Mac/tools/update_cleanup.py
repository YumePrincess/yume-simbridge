"""Remove only SimHub-owned installation leftovers, under an exclusive lock."""
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import re
import shutil


@contextmanager
def update_workspace(path):
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path, 0o700)
    with (path/'.install.lock').open('a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield path


def clean_workspace(workspace, keep=()):
    keep = {Path(path).absolute() for path in keep}
    for path in workspace.iterdir():
        if path.is_symlink() or path.absolute() in keep:
            continue
        # Includes TemporaryDirectory names used by the previous installer.
        if path.is_dir() and re.fullmatch(r'(?:tmp[a-z0-9_]{8}|simhub-update-[a-z0-9_]+)', path.name):
            shutil.rmtree(path)
        elif path.is_file() and re.fullmatch(r'Yume SIM Hub [0-9.]+ Build [0-9]+\.(?:zip|dmg)', path.name):
            path.unlink()


def clean_installation(destination):
    # Only call after verifying/installing the destination successfully. Failed
    # upgrades retain the previous bundle for rollback.
    for path in destination.parent.iterdir():
        if (not path.is_symlink() and path.is_dir()
                and re.fullmatch(r'\.simhub-(?:install|previous)-[0-9a-f-]{36}\.app', path.name)):
            shutil.rmtree(path)


if __name__ == '__main__':
    import argparse
    import subprocess
    parser = argparse.ArgumentParser()
    parser.add_argument('--destination', required=True)
    args = parser.parse_args()
    destination = Path(args.destination).absolute()
    if destination.name != 'Yume SIM Hub.app':
        raise SystemExit('Unexpected application destination')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict',
                    '-R', '=identifier "zone.yume.simhub"', str(destination)], check=True, capture_output=True)
    try:
        with update_workspace(Path.home()/'Library/Application Support/YumeSimHub/Updates') as workspace:
            clean_workspace(workspace)
            clean_installation(destination)
    except BlockingIOError:
        pass  # An active installer owns its temporary files.
