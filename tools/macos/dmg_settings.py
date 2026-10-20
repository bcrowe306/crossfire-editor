# dmgbuild settings for the editor's disk image (task macos:dmg):
#   dmgbuild -s tools/macos/dmg_settings.py -D app="dist/macos/Crossfire Editor.app" "Crossfire Editor" out.dmg
# The window shows the app and a link to /Applications to drag it onto.
# Reference: https://dmgbuild.readthedocs.io/en/latest/settings.html
import os.path

# `defines` comes from dmgbuild's -D options
application = defines.get("app", "dist/macos/Crossfire Editor.app")  # noqa: F821
appname = os.path.basename(application)

format = "UDZO"  # zlib-compressed, read-only
# The mounted volume's icon: the app's
icon = os.path.join(application, "Contents", "Resources", "Crossfire.icns")
filesystem = "HFS+"
size = None  # as big as the contents need
files = [application]
symlinks = {"Applications": "/Applications"}

# The window's background: an arrow from the app to Applications (tools/macos/make_dmg_background.sh;
# 1x and 2x in one TIFF), its size the window's
background = defines.get("background", "assets/dmg/background.tiff")  # noqa: F821
window_rect = ((200, 120), (600, 320))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 96
text_size = 13
icon_locations = {
    appname: (150, 150),
    "Applications": (450, 150),
}
