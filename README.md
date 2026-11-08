# ChaosPad

My personal, native iPhone/iPad build of **Tom Clancy's Splinter Cell: Chaos Theory (USA, SLUS-21137)**, single player.
Nothing is emulated on the main processor: the game's code runs as native ARM64 code on the phone.

- **Runtime:** [exoteric33/ps2-native-recomp](https://github.com/exoteric33/ps2-native-recomp) (MIT), vendored in
  `runtime/` with my iOS port (see `runtime/UPSTREAM.md`): an app target, the graphics chip on Metal through wgpu-native,
  SDL2 for the window, sound and controllers, on-screen touch controls, and no live compiling (`PS2_NO_LIVE`).
- **Game code:** the game program (`SC3_OFF.ELF`) recompiled to C++ and its VU1 microprograms compiled ahead of time, both
  generated on my PC from my own disc. They arrive in the encrypted game input; nothing of the game is in this repository.

## How a build happens

`.github/workflows/testflight.yml` (run by hand) decrypts my game input (release `game-input`, key in the `GAME_KEY`
secret) inside the Mac runner and builds the app (`.github/scripts/build-ios.sh`).

- `simulator`: builds for the iOS Simulator and runs it there, optionally with the disc image (`simulator-check.sh`).
- `testflight`: builds for the device and uploads it with Apple's cloud signing (`testflight.sh`).
- `assetpacks`: the trimmed disc image (`sc3.sparse`, encrypted chunks in release `disc-input`) becomes the Apple-hosted
  asset pack `sc3disc`, which the phone downloads with the app (`asset-packs.sh`, the downloader extension in `ios/`).

Secrets: `GAME_KEY`, `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`.

## On the phone

- The game's disc arrives with the app (asset pack). A disc image (`.iso`) copied into the app's folder in the Files app
  is used instead, if there is one.
- Touch controls show while no game controller is connected; MENU opens the quick menu (quick save and quick load).
- The app's folder (Files app, On My iPhone, ChaosPad) holds the memory card (`card1.ps2`), quick saves, `log.txt` (the
  last run, `log-prev.txt` the one before) and an optional `env.txt` of `KEY=VALUE` lines, e.g. `PS2_SCALE=2`.

Never commit the game, the disc image, or generated code.
