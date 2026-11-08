#pragma once

// On-screen controls for a touch screen (the iOS app, host/ios/): a PS2 controller drawn over the game's picture while no game
// controller is connected. A finger that lands on a button presses it (and whatever button it slides onto); a finger that lands
// anywhere else becomes a stick, centred where it landed: the left half of the screen the left stick, the right half the right one.
// A MENU button opens the quick menu (quick save and load). The controls are a picture made here on the CPU and laid over the game's
// picture by the WebGPU present pass (runtime/src/gs/gpu/overlay.hpp, set_touch_overlay); the game never sees it.
//
// On a PC, PS2_TOUCH=1 shows the controls and lets the left mouse button act as one finger (to try the layout).

#include <SDL.h>

#include <cstdint>
#include <functional>

namespace touchpad {

void set_visible(bool visible);  // shown or not (hidden: every finger is let go)
bool visible();
// SDL_FINGERDOWN / SDL_FINGERMOTION / SDL_FINGERUP; width and height: the window in pixels. True when the event was for the controls.
bool finger_event(const SDL_Event &e, int width, int height);
// the mouse as one finger (PC test only). True when the event was for the controls.
bool mouse_event(const SDL_Event &e, int width, int height);
// what the controls hold now: buttons as the pad sends them (window.cpp's Button bits), sticks 0..255 (0x80 the middle)
void read(std::uint16_t &pressed, std::uint8_t &lx, std::uint8_t &ly, std::uint8_t &rx, std::uint8_t &ry);
bool take_menu_tap();  // true once after a tap on MENU
void release_all();
// The picture of the controls for a window of width x height pixels, made again when something changed; `set` gets it (rgba, width,
// height at a fraction of the window's size, straight alpha) or nullptr when the controls are hidden.
void paint(int width, int height, const std::function<void(const std::uint32_t *, int, int)> &set);

}  // namespace touchpad
