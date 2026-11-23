#!/usr/bin/env python3
"""Prune older generated packages only after their replacements are complete."""
import argparse
from pathlib import Path
import re


def clean(directory, build, kind):
    pattern = (r'Yume SIM(?:Bridge| Hub) [0-9.]+ Build ([0-9]+)\.(?:dmg|zip)(?:\.sha256)?'
               if kind == 'mac' else r'luci-app-yume-sim(?:bridge|hub)_[0-9.]+-([0-9]+)_[a-zA-Z0-9_-]+\.ipk(?:\.sha256)?')
    for path in Path(directory).iterdir():
        match = re.fullmatch(pattern, path.name)
        if match and int(match[1]) < build and path.is_file() and not path.is_symlink():
            path.unlink()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', required=True)
    parser.add_argument('--build', required=True, type=int)
    parser.add_argument('--kind', required=True, choices=['mac', 'openwrt'])
    args = parser.parse_args()
    clean(args.directory, args.build, args.kind)
