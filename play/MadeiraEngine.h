#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

// Runs a Windows program with Madeira's engine in MacShack Play, drawing into `layer` (Play's own, on screen).
// `request`: run (an exe in Madeira's arm64ec-windows such as cube-x64.exe, a Z:\ path, or with `game` the exe's path in
// the game's folder), game + gameDir (a Steam game's folder name and where it is: linked into the prefix at
// C:\Program Files (x86)\Steam\steamapps\common\<game>), steamAppID, prefix (default Documents/wine), args, screen
// ("960x540"; games 1408x648), fpsMode, hud (Metal's HUD on the layer), jitMB (MacShack points its JIT helper at this
// pid first; default 384, games 896), seconds (of frames; default 20, games until they exit). Returns a report when
// the program exits, after `seconds` of frames, or after 2 min without a frame. Blocks; call off the main thread.
NSString *MadeiraEngineRun(NSDictionary *request, CAMetalLayer *layer);

// One controller as Windows' XInput sees it (the layout of Madeira's struct winios_gamepad, v0.1.1): XINPUT_GAMEPAD_*
// button bits, sticks -32767...32767 with +y up, triggers 0...255.
typedef struct {
    uint32_t packet;   // set by MadeiraEnginePad: it advances only when the state changes
    uint16_t buttons;
    uint8_t left_trigger, right_trigger;
    int16_t lx, ly, rx, ry;
    uint8_t connected;
    uint8_t reserved[3];
} ShackPadState;
_Static_assert(sizeof(ShackPadState) == 20, "winios_gamepad layout");

// Input for the engine: a touch (phase 0 down, 1 move, 2 up; x, y 0...1 across the program's image) and pad `index`'s
// state (NULL: disconnected). Dropped until the engine is loaded; MadeiraEnginePad says whether it was taken.
void MadeiraEngineTouch(NSInteger phase, double x, double y);
BOOL MadeiraEnginePad(NSInteger index, const ShackPadState *_Nullable state);

// Call first in main(): holds the low address space the engine's JIT pool needs until MadeiraEngineRun asks for the pool.
void MadeiraEngineHoldPoolSpace(void);

// Windows/engine in the App Group (MacShack's Set up Windows games, host/WindowsKit.swift): the engine and the files it
// reads beside it, laid out as Madeira's app bundle has them. nil without the App Group.
NSString *_Nullable MadeiraEngineDirectory(void);

NS_ASSUME_NONNULL_END
