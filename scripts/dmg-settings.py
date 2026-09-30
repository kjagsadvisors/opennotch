# dmgbuild settings for the OpenNotch disk image (used by scripts/release.sh):
#   dmgbuild -s scripts/dmg-settings.py -D app=<OpenNotch.app> -D background=<png> "OpenNotch" out.dmg
# Writes Finder's window layout directly, so it works headless (no Finder scripting).
import os

app = defines["app"]
name = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}

# Matches scripts/make-dmg-background.swift: icons centred at x=165/495, y=210 in a 660x400 window.
background = defines["background"]
window_rect = ((200, 140), (660, 400))
icon_locations = {name: (165, 210), "Applications": (495, 210)}
icon_size = 112
text_size = 13
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
arrange_by = None
