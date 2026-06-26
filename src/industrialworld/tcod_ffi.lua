--- libtcod FFI bindings for LuaJIT.
---
--- Declares the libtcod C API types and functions via ffi.cdef, then
--- returns ffi.C so callers can invoke C functions directly. The safe
--- RAII wrappers live in `industrialworld.tcod`.
---
--- Because the host executable is linked with `-Wl,-export_dynamic`,
--- every libtcod symbol is visible to dlsym() and thus resolvable
--- through ffi.C — no separate shared object needs to be dlopen'd.

local ffi = require("ffi")

ffi.cdef([[
/* ── Color types ─────────────────────────────────────────────────── */

typedef struct TCOD_ColorRGB {
    uint8_t r, g, b;
} TCOD_color_t;

typedef struct TCOD_ColorRGBA {
    uint8_t r, g, b, a;
} TCOD_ColorRGBA;

/* ── Enums ───────────────────────────────────────────────────────── */

typedef enum TCOD_bkgnd_flag_t {
    TCOD_BKGND_NONE,
    TCOD_BKGND_SET,
    TCOD_BKGND_MULTIPLY,
    TCOD_BKGND_LIGHTEN,
    TCOD_BKGND_DARKEN,
    TCOD_BKGND_SCREEN,
    TCOD_BKGND_COLOR_DODGE,
    TCOD_BKGND_COLOR_BURN,
    TCOD_BKGND_ADD,
    TCOD_BKGND_ADDA,
    TCOD_BKGND_BURN,
    TCOD_BKGND_OVERLAY,
    TCOD_BKGND_ALPH,
    TCOD_BKGND_DEFAULT
} TCOD_bkgnd_flag_t;

typedef enum TCOD_alignment_t {
    TCOD_LEFT,
    TCOD_RIGHT,
    TCOD_CENTER
} TCOD_alignment_t;

typedef enum TCOD_renderer_t {
    TCOD_RENDERER_GLSL,
    TCOD_RENDERER_OPENGL,
    TCOD_RENDERER_SDL,
    TCOD_RENDERER_SDL2,
    TCOD_RENDERER_OPENGL2,
    TCOD_RENDERER_XTERM = 5
} TCOD_renderer_t;

typedef enum TCOD_Error {
    TCOD_E_OK = 0,
    TCOD_E_ERROR = -1,
    TCOD_E_INVALID_ARGUMENT = -2,
    TCOD_E_OUT_OF_MEMORY = -3,
    TCOD_E_REQUIRES_ATTENTION = -4,
    TCOD_E_WARN = 1
} TCOD_Error;

typedef enum TCOD_event_t {
    TCOD_EVENT_NONE = 0,
    TCOD_EVENT_KEY_PRESS = 1,
    TCOD_EVENT_KEY_RELEASE = 2,
    TCOD_EVENT_KEY = 3,
    TCOD_EVENT_MOUSE_MOVE = 4,
    TCOD_EVENT_MOUSE_PRESS = 8,
    TCOD_EVENT_MOUSE_RELEASE = 16,
    TCOD_EVENT_MOUSE = 28,
    TCOD_EVENT_FINGER_MOVE = 32,
    TCOD_EVENT_FINGER_PRESS = 64,
    TCOD_EVENT_FINGER_RELEASE = 128,
    TCOD_EVENT_FINGER = 224,
    TCOD_EVENT_ANY = 255
} TCOD_event_t;

typedef enum TCOD_keycode_t {
    TCODK_NONE,
    TCODK_ESCAPE,
    TCODK_BACKSPACE,
    TCODK_TAB,
    TCODK_ENTER,
    TCODK_SHIFT,
    TCODK_CONTROL,
    TCODK_ALT,
    TCODK_PAUSE,
    TCODK_CAPSLOCK,
    TCODK_PAGEUP,
    TCODK_PAGEDOWN,
    TCODK_END,
    TCODK_HOME,
    TCODK_UP,
    TCODK_LEFT,
    TCODK_RIGHT,
    TCODK_DOWN,
    TCODK_PRINTSCREEN,
    TCODK_INSERT,
    TCODK_DELETE,
    TCODK_LWIN,
    TCODK_RWIN,
    TCODK_APPS,
    TCODK_0, TCODK_1, TCODK_2, TCODK_3, TCODK_4,
    TCODK_5, TCODK_6, TCODK_7, TCODK_8, TCODK_9,
    TCODK_KP0, TCODK_KP1, TCODK_KP2, TCODK_KP3, TCODK_KP4,
    TCODK_KP5, TCODK_KP6, TCODK_KP7, TCODK_KP8, TCODK_KP9,
    TCODK_KPADD, TCODK_KPSUB, TCODK_KPDIV, TCODK_KPMUL, TCODK_KPDEC, TCODK_KPENTER,
    TCODK_F1, TCODK_F2, TCODK_F3, TCODK_F4, TCODK_F5, TCODK_F6,
    TCODK_F7, TCODK_F8, TCODK_F9, TCODK_F10, TCODK_F11, TCODK_F12,
    TCODK_NUMLOCK, TCODK_SCROLLLOCK, TCODK_SPACE, TCODK_CHAR
} TCOD_keycode_t;

/* ── Console ─────────────────────────────────────────────────────── */

typedef struct TCOD_ConsoleTile {
    int ch;
    TCOD_ColorRGBA fg;
    TCOD_ColorRGBA bg;
} TCOD_ConsoleTile;

struct TCOD_Console;

typedef struct TCOD_Console TCOD_Console;

typedef struct TCOD_Context TCOD_Context;
typedef struct TCOD_Tileset TCOD_Tileset;

/* ── Context params ──────────────────────────────────────────────── */

typedef struct TCOD_ContextParams {
    int tcod_version;
    int window_x, window_y;
    int pixel_width, pixel_height;
    int columns, rows;
    int renderer_type;
    TCOD_Tileset *tileset;
    int vsync;
    int sdl_window_flags;
    const char *window_title;
    int argc;
    const char *const *argv;
    void (*cli_output)(void *userdata, const char *output);
    void *cli_userdata;
    bool window_xy_defined;
    TCOD_Console *console;
} TCOD_ContextParams;

/* ── Key / mouse event structs ──────────────────────────────────── */

typedef struct TCOD_key_t {
    TCOD_keycode_t vk;
    char c;
    char text[32];
    bool pressed;
    bool lalt, lctrl, lmeta;
    bool ralt, rctrl, rmeta;
    bool shift;
} TCOD_key_t;

typedef struct TCOD_mouse_t {
    int x, y;
    int dx, dy;
    int cx, cy;
    int dcx, dcy;
    bool lbutton, rbutton, mbutton;
    bool lbutton_pressed, rbutton_pressed, mbutton_pressed;
    bool wheel_up, wheel_down;
} TCOD_mouse_t;

/* ── Error handling ──────────────────────────────────────────────── */

const char *TCOD_get_error(void);
TCOD_Error TCOD_set_error(const char *msg);

/* ── Lifecycle ───────────────────────────────────────────────────── */

void TCOD_quit(void);

/* ── Console API ─────────────────────────────────────────────────── */

TCOD_Console *TCOD_console_new(int w, int h);
int TCOD_console_get_width(const TCOD_Console *con);
int TCOD_console_get_height(const TCOD_Console *con);
void TCOD_console_set_key_color(TCOD_Console *con, TCOD_color_t col);
void TCOD_console_blit(
    const TCOD_Console *src, int xSrc, int ySrc, int wSrc, int hSrc,
    TCOD_Console *dst, int xDst, int yDst,
    float foreground_alpha, float background_alpha);
void TCOD_console_delete(TCOD_Console *console);

void TCOD_console_clear(TCOD_Console *con);

void TCOD_console_set_default_background(TCOD_Console *con, TCOD_color_t col);
void TCOD_console_set_default_foreground(TCOD_Console *con, TCOD_color_t col);

void TCOD_console_set_char_background(TCOD_Console *con, int x, int y, TCOD_color_t col, TCOD_bkgnd_flag_t flag);
void TCOD_console_set_char_foreground(TCOD_Console *con, int x, int y, TCOD_color_t col);
void TCOD_console_set_char(TCOD_Console *con, int x, int y, int c);
void TCOD_console_put_char(TCOD_Console *con, int x, int y, int c, TCOD_bkgnd_flag_t flag);
void TCOD_console_put_char_ex(TCOD_Console *con, int x, int y, int c, TCOD_color_t fore, TCOD_color_t back);

TCOD_color_t TCOD_console_get_char_background(const TCOD_Console *con, int x, int y);
TCOD_color_t TCOD_console_get_char_foreground(const TCOD_Console *con, int x, int y);

int TCOD_console_put_rgb(
    TCOD_Console *con, int x, int y, int ch,
    const TCOD_ColorRGBA *fg, const TCOD_ColorRGBA *bg,
    TCOD_bkgnd_flag_t flag);

void TCOD_console_print(TCOD_Console *con, int x, int y, const char *fmt, ...);
int TCOD_console_print_rect(TCOD_Console *con, int x, int y, int w, int h, const char *fmt, ...);

/* ── Tileset API ────────────────────────────────────────────────── */

TCOD_Tileset *TCOD_tileset_new(int tile_width, int tile_height);
void TCOD_tileset_delete(TCOD_Tileset *tileset);
TCOD_Tileset *TCOD_tileset_load(
    const char *filename, int columns, int rows, int n, const int *charmap);
TCOD_Tileset *TCOD_load_bdf(const char *path);

/* ── Context API ─────────────────────────────────────────────────── */

TCOD_Error TCOD_context_new(const TCOD_ContextParams *params, TCOD_Context **out);
void TCOD_context_delete(TCOD_Context *context);
TCOD_Error TCOD_context_present(TCOD_Context *context, const TCOD_Console *console, const void *viewport);
TCOD_Error TCOD_context_save_screenshot(TCOD_Context *context, const char *filename);
TCOD_Error TCOD_context_change_tileset(TCOD_Context *self, TCOD_Tileset *tileset);
TCOD_Error TCOD_context_recommended_console_size(
    TCOD_Context *context, float magnification, int *columns, int *rows);

/* ── Event API ──────────────────────────────────────────────────── */

TCOD_event_t TCOD_sys_wait_for_event(int eventMask, TCOD_key_t *key, TCOD_mouse_t *mouse, bool flush);
TCOD_event_t TCOD_sys_check_for_event(int eventMask, TCOD_key_t *key, TCOD_mouse_t *mouse);
]])

return ffi.C
