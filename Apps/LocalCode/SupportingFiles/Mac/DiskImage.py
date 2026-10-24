# dmgbuild settings for Local Code's Developer ID disk image. Scripts/mac_release.sh runs dmgbuild
# from the repository root and passes the stapled app as `-D app=<path>`. The background comes
# from Scripts/dmg_background.swift, which places its art around the icon positions below.
import os.path

application = defines["app"]
appname = os.path.basename(application)

format = "ULFO"
files = [application]
symlinks = {"Applications": "/Applications"}
# Finder already hides ".app"; hide_extensions would add a Finder info attribute to the signed app,
# which strict signature checks reject.
icon = "Apps/LocalCode/SupportingFiles/Mac/macOS.icns"
background = "Apps/LocalCode/SupportingFiles/Mac/DiskImageBackground.tiff"

# The size includes the title bar, 32 pt on macOS 26 and later, leaving 660x420 pt for the art.
window_rect = ((200, 120), (660, 452))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
icon_size = 128
text_size = 13
icon_locations = {appname: (170, 250), "Applications": (490, 250)}
