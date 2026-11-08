#include "touchpad.hpp"

#include "quickmenu.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace touchpad {
namespace {

// the pad's button bits, as host/window.cpp sends them to the game
enum : std::uint32_t {
    kSelect = 1u << 0, kL3 = 1u << 1, kR3 = 1u << 2, kStart = 1u << 3,
    kUp = 1u << 4, kRight = 1u << 5, kDown = 1u << 6, kLeft = 1u << 7,
    kL2 = 1u << 8, kR2 = 1u << 9, kL1 = 1u << 10, kR1 = 1u << 11,
    kTriangle = 1u << 12, kCircle = 1u << 13, kCross = 1u << 14, kSquare = 1u << 15,
    kMenu = 1u << 16,  // the quick menu, not a pad button
};

enum class Shape { Face, Pill, Arrow };
enum class Symbol { None, Triangle, Circle, Cross, Square };

struct Control {
    std::uint32_t mask;
    Shape shape;
    float x, y;    // centre, window pixels
    float w, h;    // Face: w is the radius; Pill and Arrow: the box
    float angle;   // Arrow: 0 up, 90 right, 180 down, 270 left
    const char *label;
    Symbol symbol;
    std::uint32_t rgb;  // 0xRRGGBB
};

struct Layout {
    std::vector<Control> controls;
    float u = 1.0f, width = 0.0f, height = 0.0f, stick = 0.0f;  // u: a hundredth of the height; stick: a stick's reach
};

// Sizes in hundredths of the screen's height (u). Landscape iPhone: the Dynamic Island and the rounded corners sit at the left and
// right edges, so nothing comes closer than about 14u to them at mid height.
Layout make_layout(float W, float H) {
    Layout l;
    const float u = H / 100.0f;
    l.u = u;
    l.width = W;
    l.height = H;
    l.stick = 14.0f * u;
    const float fx = W - 34.0f * u, fy = H - 33.0f * u, d = 12.5f * u, r = 7.0f * u;
    l.controls.push_back({kTriangle, Shape::Face, fx, fy - d, r, r, 0, nullptr, Symbol::Triangle, 0x40E2A0});
    l.controls.push_back({kCross, Shape::Face, fx, fy + d, r, r, 0, nullptr, Symbol::Cross, 0x7CB2E8});
    l.controls.push_back({kSquare, Shape::Face, fx - d, fy, r, r, 0, nullptr, Symbol::Square, 0xFF69F8});
    l.controls.push_back({kCircle, Shape::Face, fx + d, fy, r, r, 0, nullptr, Symbol::Circle, 0xFF6666});
    const float sw = 20.0f * u, sh = 10.0f * u;
    l.controls.push_back({kL1, Shape::Pill, 18.0f * u, 11.0f * u, sw, sh, 0, "L1", Symbol::None, 0xFFFFFF});
    l.controls.push_back({kL2, Shape::Pill, 18.0f * u, 24.0f * u, sw, sh, 0, "L2", Symbol::None, 0xFFFFFF});
    l.controls.push_back({kR1, Shape::Pill, W - 18.0f * u, 11.0f * u, sw, sh, 0, "R1", Symbol::None, 0xFFFFFF});
    l.controls.push_back({kR2, Shape::Pill, W - 18.0f * u, 24.0f * u, sw, sh, 0, "R2", Symbol::None, 0xFFFFFF});
    const float th = 7.5f * u;
    l.controls.push_back({kSelect, Shape::Pill, W * 0.5f - 25.0f * u, 6.5f * u, 20.0f * u, th, 0, "SELECT", Symbol::None, 0xFFFFFF});
    l.controls.push_back({kMenu, Shape::Pill, W * 0.5f, 6.5f * u, 17.0f * u, th, 0, "MENU", Symbol::None, 0xF0C86E});
    l.controls.push_back({kStart, Shape::Pill, W * 0.5f + 25.0f * u, 6.5f * u, 20.0f * u, th, 0, "START", Symbol::None, 0xFFFFFF});
    const float dx = W * 0.5f - 33.0f * u, dy = H - 18.0f * u, a = 7.5f * u, b = 7.5f * u;
    l.controls.push_back({kUp, Shape::Arrow, dx, dy - a, b, b, 0, nullptr, Symbol::None, 0xFFFFFF});
    l.controls.push_back({kRight, Shape::Arrow, dx + a, dy, b, b, 90, nullptr, Symbol::None, 0xFFFFFF});
    l.controls.push_back({kDown, Shape::Arrow, dx, dy + a, b, b, 180, nullptr, Symbol::None, 0xFFFFFF});
    l.controls.push_back({kLeft, Shape::Arrow, dx - a, dy, b, b, 270, nullptr, Symbol::None, 0xFFFFFF});
    l.controls.push_back({kL3, Shape::Pill, W * 0.5f - 9.0f * u, H - 9.0f * u, 14.0f * u, th, 0, "L3", Symbol::None, 0xFFFFFF});
    l.controls.push_back({kR3, Shape::Pill, W * 0.5f + 9.0f * u, H - 9.0f * u, 14.0f * u, th, 0, "R3", Symbol::None, 0xFFFFFF});
    return l;
}

enum class Role { Buttons, LeftStick, RightStick, None };
struct Finger {
    Role role;
    float ox, oy, x, y;  // where the stick is centred (its origin follows a finger that goes past the reach), and the finger
};

std::map<SDL_FingerID, Finger> g_fingers;
bool g_visible = false;
bool g_menu_tap = false;
Layout g_layout;
int g_layout_w = 0, g_layout_h = 0;
std::uint64_t g_painted = ~0ull;
std::vector<std::uint32_t> g_pixels;
constexpr SDL_FingerID kMouseFinger = -77;

const Layout &layout(int width, int height) {
    if (width != g_layout_w || height != g_layout_h) {
        g_layout = make_layout(static_cast<float>(width), static_cast<float>(height));
        g_layout_w = width;
        g_layout_h = height;
    }
    return g_layout;
}

bool over(const Control &c, float x, float y, float slack) {
    if (c.shape == Shape::Face) {
        const float r = c.w * slack;
        return (x - c.x) * (x - c.x) + (y - c.y) * (y - c.y) <= r * r;
    }
    return std::fabs(x - c.x) <= c.w * 0.5f * slack && std::fabs(y - c.y) <= c.h * 0.5f * slack;
}

const Control *hit(const Layout &l, float x, float y, float slack) {
    const Control *best = nullptr;
    float best_d = 1e30f;
    for (const Control &c : l.controls) {
        if (!over(c, x, y, slack)) continue;
        const float d = (x - c.x) * (x - c.x) + (y - c.y) * (y - c.y);
        if (d < best_d) best = &c, best_d = d;
    }
    return best;
}

bool stick_taken(Role role) {
    for (const auto &[id, f] : g_fingers)
        if (f.role == role) return true;
    return false;
}

void finger_down(SDL_FingerID id, float x, float y) {
    const Layout &l = g_layout;
    Finger f{Role::None, x, y, x, y};
    if (const Control *c = hit(l, x, y, 1.15f)) {
        if (c->mask == kMenu) g_menu_tap = true;
        else f.role = Role::Buttons;
    } else {
        const Role side = x < l.width * 0.5f ? Role::LeftStick : Role::RightStick;
        if (!stick_taken(side)) f.role = side;
    }
    g_fingers[id] = f;
}

void finger_move(SDL_FingerID id, float x, float y) {
    auto it = g_fingers.find(id);
    if (it == g_fingers.end()) return;
    Finger &f = it->second;
    f.x = x;
    f.y = y;
    if (f.role == Role::LeftStick || f.role == Role::RightStick) {
        const float dx = x - f.ox, dy = y - f.oy, dist = std::sqrt(dx * dx + dy * dy), reach = g_layout.stick;
        if (dist > reach) {  // the stick's centre follows the finger, so turning back acts at once
            f.ox = x - dx / dist * reach;
            f.oy = y - dy / dist * reach;
        }
    }
}

std::uint8_t level(float offset, float reach) {
    const float v = std::clamp(offset / reach, -1.0f, 1.0f);
    return static_cast<std::uint8_t>(std::clamp(128.0f + v * 127.5f, 0.0f, 255.0f));
}

// --- drawing: straight-alpha RGBA, red in the low byte ---

struct Canvas {
    std::vector<std::uint32_t> &px;
    int w, h;
    float s;  // picture pixels per window pixel

    void blend(int x, int y, std::uint32_t rgb, float a) {
        if (a <= 0.0f || x < 0 || y < 0 || x >= w || y >= h) return;
        a = std::min(a, 1.0f);
        std::uint32_t &d = px[static_cast<std::size_t>(y) * w + x];
        const float da = static_cast<float>(d >> 24) / 255.0f, oa = a + da * (1.0f - a);
        if (oa <= 0.0f) return;
        std::uint32_t out = static_cast<std::uint32_t>(oa * 255.0f + 0.5f) << 24;
        for (int k = 0; k < 3; ++k) {
            const float sc = static_cast<float>((rgb >> (16 - 8 * k)) & 255u), dc = static_cast<float>((d >> (8 * k)) & 255u);
            out |= static_cast<std::uint32_t>(std::clamp((sc * a + dc * da * (1.0f - a)) / oa, 0.0f, 255.0f) + 0.5f) << (8 * k);
        }
        d = out;
    }
    // runs `coverage(x, y)` (window pixels, the pixel's centre) over a box around cx, cy of half size rx, ry
    template <class F>
    void shade(float cx, float cy, float rx, float ry, std::uint32_t rgb, float alpha, F coverage) {
        const int x0 = std::max(0, static_cast<int>((cx - rx) * s) - 1), x1 = std::min(w - 1, static_cast<int>((cx + rx) * s) + 1);
        const int y0 = std::max(0, static_cast<int>((cy - ry) * s) - 1), y1 = std::min(h - 1, static_cast<int>((cy + ry) * s) + 1);
        for (int y = y0; y <= y1; ++y)
            for (int x = x0; x <= x1; ++x) {
                const float c = coverage((static_cast<float>(x) + 0.5f) / s, (static_cast<float>(y) + 0.5f) / s);
                if (c > 0.0f) blend(x, y, rgb, c * alpha);
            }
    }
    float aa(float distance) const { return std::clamp(0.5f - distance * s, 0.0f, 1.0f); }  // distance in window pixels, < 0 inside
    void disc(float cx, float cy, float r, std::uint32_t rgb, float alpha) {
        shade(cx, cy, r + 2.0f / s, r + 2.0f / s, rgb, alpha, [&](float x, float y) { return aa(std::hypot(x - cx, y - cy) - r); });
    }
    void ring(float cx, float cy, float r, float thick, std::uint32_t rgb, float alpha) {
        shade(cx, cy, r + thick + 2.0f / s, r + thick + 2.0f / s, rgb, alpha,
              [&](float x, float y) { return aa(std::fabs(std::hypot(x - cx, y - cy) - r) - thick * 0.5f); });
    }
    static float box_distance(float x, float y, float cx, float cy, float hw, float hh, float radius) {
        const float qx = std::fabs(x - cx) - (hw - radius), qy = std::fabs(y - cy) - (hh - radius);
        return std::hypot(std::max(qx, 0.0f), std::max(qy, 0.0f)) + std::min(std::max(qx, qy), 0.0f) - radius;
    }
    void box(float cx, float cy, float bw, float bh, float radius, std::uint32_t rgb, float alpha) {
        shade(cx, cy, bw * 0.5f + 2.0f / s, bh * 0.5f + 2.0f / s, rgb, alpha,
              [&](float x, float y) { return aa(box_distance(x, y, cx, cy, bw * 0.5f, bh * 0.5f, radius)); });
    }
    void box_line(float cx, float cy, float bw, float bh, float radius, float thick, std::uint32_t rgb, float alpha) {
        shade(cx, cy, bw * 0.5f + thick + 2.0f / s, bh * 0.5f + thick + 2.0f / s, rgb, alpha,
              [&](float x, float y) { return aa(std::fabs(box_distance(x, y, cx, cy, bw * 0.5f, bh * 0.5f, radius)) - thick * 0.5f); });
    }
    static float segment_distance(float x, float y, float ax, float ay, float bx, float by) {
        const float px = x - ax, py = y - ay, dx = bx - ax, dy = by - ay;
        const float t = std::clamp((px * dx + py * dy) / std::max(dx * dx + dy * dy, 1e-6f), 0.0f, 1.0f);
        return std::hypot(px - dx * t, py - dy * t);
    }
    // a closed or open line through points (window pixels)
    void lines(const std::vector<float> &p, bool closed, float thick, std::uint32_t rgb, float alpha) {
        float minx = 1e30f, miny = 1e30f, maxx = -1e30f, maxy = -1e30f;
        for (std::size_t i = 0; i < p.size(); i += 2) minx = std::min(minx, p[i]), maxx = std::max(maxx, p[i]), miny = std::min(miny, p[i + 1]), maxy = std::max(maxy, p[i + 1]);
        const std::size_t n = p.size() / 2;
        shade((minx + maxx) * 0.5f, (miny + maxy) * 0.5f, (maxx - minx) * 0.5f + thick + 2.0f / s, (maxy - miny) * 0.5f + thick + 2.0f / s, rgb, alpha,
              [&](float x, float y) {
                  float d = 1e30f;
                  for (std::size_t i = 0; i + (closed ? 0 : 1) < n; ++i) {
                      const std::size_t j = (i + 1) % n;
                      d = std::min(d, segment_distance(x, y, p[2 * i], p[2 * i + 1], p[2 * j], p[2 * j + 1]));
                  }
                  return aa(d - thick * 0.5f);
              });
    }
    // a filled triangle
    void triangle(float ax, float ay, float bx, float by, float cx, float cy, std::uint32_t rgb, float alpha) {
        const float mx = (std::min({ax, bx, cx}) + std::max({ax, bx, cx})) * 0.5f, my = (std::min({ay, by, cy}) + std::max({ay, by, cy})) * 0.5f;
        const float rx = (std::max({ax, bx, cx}) - std::min({ax, bx, cx})) * 0.5f + 2.0f / s, ry = (std::max({ay, by, cy}) - std::min({ay, by, cy})) * 0.5f + 2.0f / s;
        // signed distances to the three edges: inside, all have the same sign (whichever way the corners go round)
        const auto edge = [](float x, float y, float x0, float y0, float x1, float y1) {
            const float ex = x1 - x0, ey = y1 - y0, len = std::max(std::hypot(ex, ey), 1e-6f);
            return ((x - x0) * ey - (y - y0) * ex) / len;
        };
        shade(mx, my, rx, ry, rgb, alpha, [&](float x, float y) {
            const float e1 = edge(x, y, ax, ay, bx, by), e2 = edge(x, y, bx, by, cx, cy), e3 = edge(x, y, cx, cy, ax, ay);
            return aa(std::min(std::max({e1, e2, e3}), std::max({-e1, -e2, -e3})));
        });
    }
    void label(float cx, float cy, float height, const char *text, std::uint32_t rgb) {
        const int scale = std::max(1, static_cast<int>(height * s * 0.42f / 8.0f + 0.5f));
        const std::string line = text;
        const int tw = quickmenu::text_width(line, scale), th = 7 * scale;
        const int x = static_cast<int>(cx * s) - tw / 2, y = static_cast<int>(cy * s) - th / 2;
        const std::uint32_t color = ((rgb >> 16) & 255u) | (rgb & 0xFF00u) | ((rgb & 255u) << 16) | (235u << 24);
        quickmenu::Picture view;  // the font is drawn straight into this picture (pixel art: no blending needed)
        view.width = w;
        view.height = h;
        view.rgba.swap(px);
        quickmenu::draw_text(view, x, y, scale, line, color);
        view.rgba.swap(px);
    }
};

std::uint64_t mix(std::uint64_t h, std::uint64_t v) { return (h ^ v) * 0x100000001B3ull; }

void draw(Canvas &c, const Layout &l, std::uint32_t pressed) {
    const float u = l.u;
    for (const Control &k : l.controls) {
        const bool on = (pressed & k.mask) != 0;
        const float fill = on ? 0.42f : 0.26f;
        const std::uint32_t fill_rgb = on ? 0xFFFFFF : 0x101418;
        switch (k.shape) {
        case Shape::Face: {
            c.disc(k.x, k.y, k.w, fill_rgb, fill);
            c.ring(k.x, k.y, k.w, 0.45f * u, 0xFFFFFF, 0.42f);
            const float g = k.w * 0.45f, t = 0.7f * u;
            if (k.symbol == Symbol::Triangle) c.lines({k.x, k.y - g, k.x + g * 0.95f, k.y + g * 0.62f, k.x - g * 0.95f, k.y + g * 0.62f}, true, t, k.rgb, 0.92f);
            if (k.symbol == Symbol::Circle) c.ring(k.x, k.y, g * 0.85f, t, k.rgb, 0.92f);
            if (k.symbol == Symbol::Cross) {
                c.lines({k.x - g * 0.8f, k.y - g * 0.8f, k.x + g * 0.8f, k.y + g * 0.8f}, false, t, k.rgb, 0.92f);
                c.lines({k.x + g * 0.8f, k.y - g * 0.8f, k.x - g * 0.8f, k.y + g * 0.8f}, false, t, k.rgb, 0.92f);
            }
            if (k.symbol == Symbol::Square) c.box_line(k.x, k.y, g * 1.5f, g * 1.5f, 0.0f, t, k.rgb, 0.92f);
            break;
        }
        case Shape::Pill:
            c.box(k.x, k.y, k.w, k.h, k.h * 0.5f, fill_rgb, fill);
            c.box_line(k.x, k.y, k.w, k.h, k.h * 0.5f, 0.4f * u, 0xFFFFFF, 0.42f);
            if (k.label) c.label(k.x, k.y, k.h, k.label, k.rgb);
            break;
        case Shape::Arrow: {
            c.box(k.x, k.y, k.w, k.h, 1.2f * u, fill_rgb, fill);
            c.box_line(k.x, k.y, k.w, k.h, 1.2f * u, 0.4f * u, 0xFFFFFF, 0.42f);
            const float rad = k.angle * 3.14159265f / 180.0f, sn = std::sin(rad), cs = std::cos(rad), g = k.w * 0.28f;
            const auto at = [&](float px, float py, float &ox, float &oy) { ox = k.x + px * cs - py * sn; oy = k.y + px * sn + py * cs; };
            float ax, ay, bx, by, cx, cy;
            at(0, -g, ax, ay);
            at(g, g * 0.7f, bx, by);
            at(-g, g * 0.7f, cx, cy);
            c.triangle(ax, ay, bx, by, cx, cy, 0xFFFFFF, 0.85f);
            break;
        }
        }
    }
    // the sticks: where a finger holds one, its reach and knob; else a faint hint of where to put a thumb
    bool left = false, right = false;
    for (const auto &[id, f] : g_fingers) {
        if (f.role != Role::LeftStick && f.role != Role::RightStick) continue;
        (f.role == Role::LeftStick ? left : right) = true;
        c.disc(f.ox, f.oy, l.stick, 0x101418, 0.22f);
        c.ring(f.ox, f.oy, l.stick, 0.45f * u, 0xFFFFFF, 0.45f);
        c.disc(f.x, f.y, l.stick * 0.45f, 0xFFFFFF, 0.45f);
    }
    if (!left) {
        c.ring(30.0f * u, l.height - 32.0f * u, l.stick, 0.35f * u, 0xFFFFFF, 0.16f);
        c.label(30.0f * u, l.height - 32.0f * u, 7.0f * u, "MOVE", 0xFFFFFF);
    }
    if (!right) {
        c.ring(l.width * 0.5f + 32.0f * u, l.height * 0.45f, l.stick, 0.35f * u, 0xFFFFFF, 0.16f);
        c.label(l.width * 0.5f + 32.0f * u, l.height * 0.45f, 7.0f * u, "LOOK", 0xFFFFFF);
    }
}

}  // namespace

void set_visible(bool on) {
    if (on == g_visible) return;
    g_visible = on;
    release_all();
}

bool visible() { return g_visible; }

bool finger_event(const SDL_Event &e, int width, int height) {
    if (e.type != SDL_FINGERDOWN && e.type != SDL_FINGERMOTION && e.type != SDL_FINGERUP) return false;
    if (!g_visible) return false;
    layout(width, height);
    const float x = e.tfinger.x * static_cast<float>(width), y = e.tfinger.y * static_cast<float>(height);
    if (e.type == SDL_FINGERDOWN) finger_down(e.tfinger.fingerId, x, y);
    else if (e.type == SDL_FINGERMOTION) finger_move(e.tfinger.fingerId, x, y);
    else g_fingers.erase(e.tfinger.fingerId);
    return true;
}

bool mouse_event(const SDL_Event &e, int width, int height) {
    if (!g_visible || (e.type != SDL_MOUSEBUTTONDOWN && e.type != SDL_MOUSEBUTTONUP && e.type != SDL_MOUSEMOTION)) return false;
    if (e.type == SDL_MOUSEMOTION ? e.motion.which == SDL_TOUCH_MOUSEID : e.button.which == SDL_TOUCH_MOUSEID) return false;
    layout(width, height);
    // (window coordinates of the mouse are in points; the window's pixels can be more)
    int ww = 1, wh = 1;
    SDL_GetWindowSize(SDL_GetWindowFromID(e.type == SDL_MOUSEMOTION ? e.motion.windowID : e.button.windowID), &ww, &wh);
    const float sx = static_cast<float>(width) / static_cast<float>(std::max(ww, 1)), sy = static_cast<float>(height) / static_cast<float>(std::max(wh, 1));
    if (e.type == SDL_MOUSEBUTTONDOWN && e.button.button == SDL_BUTTON_LEFT) finger_down(kMouseFinger, e.button.x * sx, e.button.y * sy);
    else if (e.type == SDL_MOUSEMOTION && (e.motion.state & SDL_BUTTON_LMASK)) finger_move(kMouseFinger, e.motion.x * sx, e.motion.y * sy);
    else if (e.type == SDL_MOUSEBUTTONUP && e.button.button == SDL_BUTTON_LEFT) g_fingers.erase(kMouseFinger);
    return true;
}

void read(std::uint16_t &pressed, std::uint8_t &lx, std::uint8_t &ly, std::uint8_t &rx, std::uint8_t &ry) {
    if (!g_visible) return;
    for (const auto &[id, f] : g_fingers) {
        switch (f.role) {
        case Role::Buttons:
            if (const Control *c = hit(g_layout, f.x, f.y, 1.0f); c && c->mask != kMenu) pressed |= static_cast<std::uint16_t>(c->mask);
            break;
        case Role::LeftStick:
            lx = level(f.x - f.ox, g_layout.stick);
            ly = level(f.y - f.oy, g_layout.stick);
            break;
        case Role::RightStick:
            rx = level(f.x - f.ox, g_layout.stick);
            ry = level(f.y - f.oy, g_layout.stick);
            break;
        case Role::None: break;
        }
    }
}

bool take_menu_tap() {
    const bool tapped = g_menu_tap;
    g_menu_tap = false;
    return tapped;
}

void release_all() {
    g_fingers.clear();
    g_menu_tap = false;
}

void paint(int width, int height, const std::function<void(const std::uint32_t *, int, int)> &set) {
    if (!g_visible || width <= 0 || height <= 0) {
        if (g_painted != 0) set(nullptr, 0, 0);
        g_painted = 0;
        return;
    }
    const Layout &l = layout(width, height);
    std::uint16_t pressed = 0;
    std::uint8_t lx = 0x80, ly = 0x80, rx = 0x80, ry = 0x80;
    read(pressed, lx, ly, rx, ry);
    // what the picture shows: made again only when that changes (a stick knob moved by a few pixels of the picture)
    std::uint64_t key = 0xCBF29CE484222325ull;
    key = mix(key, static_cast<std::uint64_t>(width) << 32 | static_cast<std::uint32_t>(height));
    key = mix(key, pressed);
    for (const auto &[id, f] : g_fingers) {
        if (f.role != Role::LeftStick && f.role != Role::RightStick) continue;
        const float q = l.u * 0.5f;
        key = mix(key, static_cast<std::uint64_t>(f.role == Role::LeftStick ? 1 : 2));
        for (float v : {f.ox, f.oy, f.x, f.y}) key = mix(key, static_cast<std::uint64_t>(static_cast<std::int64_t>(v / q)));
    }
    if (key == g_painted) return;
    g_painted = key;
    // half the window's resolution (filtered when stretched back): a quarter of the pixels to make and to upload
    const int pw = std::max(1, width / 2), ph = std::max(1, height / 2);
    g_pixels.assign(static_cast<std::size_t>(pw) * ph, 0u);
    Canvas c{g_pixels, pw, ph, static_cast<float>(pw) / static_cast<float>(width)};
    draw(c, l, pressed);
    set(g_pixels.data(), pw, ph);
}

}  // namespace touchpad
