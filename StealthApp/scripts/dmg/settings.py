"""Finder installation layout; loaded by dmgbuild with -D stage=... ."""
from pathlib import Path

stage = Path(defines["stage"])
files = [str(stage / name) for name in (
    "LiveCopilot.app", "Install - 安装说明.txt", "LICENSE.txt", "ReleaseInfo.txt"
)]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
filesystem = "HFS+"
background = str(stage / ".artwork" / "background.png")
window_rect = ((180, 180), (760, 580))
default_view = "icon-view"
show_toolbar = show_status_bar = show_sidebar = show_pathbar = show_tab_view = False
show_icon_preview = show_item_info = False
include_icon_view_settings = True
arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
hide_extensions = ["LiveCopilot.app"]
icon_locations = {
    "Applications": (180, 205),
    "LiveCopilot.app": (580, 205),
    "Install - 安装说明.txt": (190, 382),
    "LICENSE.txt": (380, 382),
    "ReleaseInfo.txt": (570, 382),
}
