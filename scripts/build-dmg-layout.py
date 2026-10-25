#!/usr/bin/env python3
"""Persist Finder geometry without opening Finder or changing desktop settings."""
import json
from pathlib import Path
import sys
from ds_store import DSStore
from mac_alias import Alias, Bookmark
from PIL import Image


def write_layout(mount, app_name):
    layout = json.loads((Path(__file__).with_name('dmg-layout.json')).read_text())
    width, height = layout['canvas']
    x, y = layout['window_origin']
    background = mount / '.background/background.tiff'
    with Image.open(background) as image:
        if image.size != (width, height):
            raise ValueError('DMG background and window content dimensions differ')
    with DSStore.open(str(mount / '.DS_Store'), 'w+') as store:
        store['.']['vSrn'] = ('long', 1)
        store['.']['icvl'] = ('type', b'icnv')
        store['.']['pBBk'] = Bookmark.for_file(str(background))
        store['.']['bwsp'] = {
            'ShowStatusBar': False, 'ShowToolbar': False, 'ShowPathbar': False, 'ShowTabView': False,
            'ShowSidebar': False, 'SidebarWidth': 0, 'ContainerShowSidebar': False,
            'WindowBounds': '{{%d, %d}, {%d, %d}}' % (x, y, width, height + layout['titlebar_height']),
            'PreviewPaneVisibility': False,
        }
        store['.']['icvp'] = {
            'viewOptionsVersion': 1, 'backgroundType': 2,
            'backgroundColorRed': 0.06, 'backgroundColorGreen': 0.09, 'backgroundColorBlue': 0.16,
            'backgroundImageAlias': Alias.for_file(str(background)).to_bytes(),
            'iconSize': float(layout['icon_size']), 'textSize': float(layout['text_size']),
            'arrangeBy': 'none', 'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'gridSpacing': 64.0,
            'labelOnBottom': True, 'showIconPreview': True, 'showItemInfo': False,
            'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
        }
        store[app_name]['Iloc'] = tuple(layout['app_position'])
        store['Applications']['Iloc'] = tuple(layout['applications_position'])
    with DSStore.open(str(mount / '.DS_Store'), 'r') as store:
        assert store[app_name]['Iloc'] == tuple(layout['app_position'])
        assert store['Applications']['Iloc'] == tuple(layout['applications_position'])
        assert not store['.']['bwsp']['ShowToolbar']


if __name__ == '__main__':
    write_layout(Path(sys.argv[1]), sys.argv[2])
