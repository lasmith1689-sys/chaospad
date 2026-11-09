# Runtime source

[exoteric33/ps2-native-recomp](https://github.com/exoteric33/ps2-native-recomp) (MIT, see LICENSE) at commit `3a7f1fb346026047b7c69de01ae6b4f7de92b846`,
with my changes for the iPhone app:

- `CMakeLists.txt`: an iOS app target (`CMAKE_SYSTEM_NAME=iOS`), SDL2 compiled from source, `PS2_NO_LIVE`.
- `runtime/src/{ee_live,vu_live,live_build}.cpp`: `PS2_NO_LIVE` leaves out live compiling (no compiler on a phone).
- `runtime/src/disc.cpp` + `scripts/mksparse.py`: sparse disc images (the disc without unused files).
- `runtime/src/gs/gpu/gpu.cpp`, `overlay.hpp`: a second overlay for the touch controls.
- `host/touchpad.{hpp,cpp}`: on-screen controls; `host/window.cpp`: touch, UIKit Metal view, app lifecycle.
- `host/main.cpp`, `host/ios/`: the app's start (folders, disc from the Background Assets pack, log), Info.plist.
- `host/quickmenu.{hpp,cpp}`: the menu font for other pictures, a Brightness entry (`keymap.cpp`: keys.ini `brightness`;
  `runtime/src/gs/gpu/blit.wgsl`: the boost as a power curve in the present pass).
- `host/window.cpp`: `PS2_SCALE_DEFAULT`, a game's default inner resolution when keys.ini has none.
- `host/ios/ios_app.mm`: the game folder's `host.txt` (host options such as `--widescreen`, and environment defaults).
