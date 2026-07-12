# iPhone External-Display + Touchscreen-Trackpad Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a wired USB-C monitor is connected to an iPhone, the game moves fullscreen onto the monitor and the phone's touchscreen becomes a relative-motion trackpad driving the game's virtual cursor; disconnecting reverses everything mid-game.

**Architecture:** A new ObjC++ display manager (`iOSExternalDisplay.mm`) in the GameEngineDevice iOS platform layer watches SDL display hot-plug events, migrates the SDL window's underlying `UIWindow` between screens (the CAMetalLayer survives, so DXVK sees only a resize), creates a UIKit trackpad window on the phone, and synthesizes relative SDL mouse events that the existing virtual-cursor path in `SDL3Mouse` consumes unchanged.

**Tech Stack:** C++/Objective-C++ (UIKit), SDL3, DXVK/MoltenVK, CMake preset `ios-vulkan`, Zero Hour (`z_generals`) target only.

**Spec:** `docs/superpowers/specs/2026-07-11-iphone-external-display-trackpad-design.md`

---

## Prerequisites and context for the implementer

- **Build command** (used as the verification step in every task):
  ```bash
  cmake --preset ios-vulkan          # only needed once, or after CMakeLists changes
  cmake --build build/ios-vulkan --target z_generals -j
  ```
  Expected: `z_generals` links with no new errors. Requires `VULKAN_SDK` pointing at a LunarG SDK with the iOS MoltenVK xcframework (see the `ios-vulkan` preset description in `CMakePresets.json`).
- **Device packaging** (for on-device validation tasks):
  ```bash
  ./scripts/build/ios/package-ios-zh.sh --dev --install
  ```
- **Why no unit tests in this plan:** the repo has no test harness for the iOS platform layer, and every piece of this feature is coupled to UIKit/SDL/hardware (screens, touches, a Vulkan swapchain). Following repo convention (see `docs/DEV_BLOG/2026-07-DIARY.md`), verification is compile-clean builds plus on-device validation checklists. Tasks that need physical hardware (iPhone 15+, USB-C monitor) are marked **[HARDWARE CHECKPOINT]** — stop and ask the user to run them; do not claim them done.
- **This feature builds on the uncommitted 2026-07-11 iPad pointer-lock work** in `SDL3Mouse.{h,cpp}` (virtual cursor `m_RelativePointerX/Y`, W3D ANI cursor rendering, the relative-motion branch in `translateEvent`). That work must be present in the working tree. Do not modify its logic except where a task explicitly says so.
- **How the existing relative path consumes events** (`GeneralsMD/Code/GameEngineDevice/Source/SDL3Device/GameClient/SDL3Mouse.cpp`, `translateEvent`): an event whose `which` (mouse ID) is neither `SDL_TOUCH_MOUSEID` nor `SDL_PEN_MOUSEID`, arriving while `SDL_GetWindowRelativeMouseMode(m_Window)` is true (always true on iOS — `init()` sets it), takes the virtual-cursor branch: motion events accumulate `xrel/yrel` through `scaleMouseDelta` into `m_RelativePointerX/Y`; button/wheel events are positioned at the virtual cursor. **Therefore: synthesized trackpad events use `which = 0` and only need `xrel/yrel` filled for motion.** The `pollSDL3Events` filter in `SDL3GameEngine.cpp` only drops `which == SDL_TOUCH_MOUSEID`, so `which = 0` passes through.

---

### Task 1: Scaffolding — new files, CMake registration, engine hooks

**Files:**
- Create: `GeneralsMD/Code/GameEngineDevice/Include/SDL3Device/iOSExternalDisplay.h`
- Create: `GeneralsMD/Code/GameEngineDevice/Source/SDL3Device/iOSExternalDisplay.mm`
- Modify: `GeneralsMD/Code/GameEngineDevice/CMakeLists.txt` (the `else()` platform branch around line 203)
- Modify: `GeneralsMD/Code/GameEngineDevice/Source/SDL3GameEngine.cpp`
- Modify: `GeneralsMD/Code/Main/SDL3Main.cpp`

- [ ] **Step 1: Create the public header**

`GeneralsMD/Code/GameEngineDevice/Include/SDL3Device/iOSExternalDisplay.h`:

```cpp
// GeneralsX @feature 11/07/2026 External-display + touchscreen-trackpad mode for iPhone.
// The game window migrates to a wired USB-C monitor and the phone screen
// becomes a relative-motion trackpad feeding the SDL3Mouse virtual cursor.
#pragma once

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

struct SDL_Window;

// Call once from SDL3Main after the SDL window exists (before engine init).
// Reads config and performs the launch-time external-display check.
void GXExternalDisplay_Startup(SDL_Window* window);

// Call once per engine frame (SDL3GameEngine::update). Applies pending
// migrations at a frame boundary so no GPU work is in flight mid-move.
void GXExternalDisplay_Poll(void);

// Signal from the SDL event loop that the display set changed
// (SDL_EVENT_DISPLAY_ADDED / SDL_EVENT_DISPLAY_REMOVED).
void GXExternalDisplay_NotifyDisplayChange(void);

// True while the game window lives on an external screen and the phone
// touchscreen acts as a trackpad.
bool GXExternalDisplay_TrackpadActive(void);

#endif // TARGET_OS_IPHONE
```

- [ ] **Step 2: Create the stub implementation**

`GeneralsMD/Code/GameEngineDevice/Source/SDL3Device/iOSExternalDisplay.mm` (fleshed out in Tasks 2–6; this compiles standalone):

```objc
// GeneralsX @feature 11/07/2026 External-display + touchscreen-trackpad mode for iPhone.
#include "SDL3Device/iOSExternalDisplay.h"

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

#import <UIKit/UIKit.h>
#include <SDL3/SDL.h>
#include <cstdio>

namespace {

SDL_Window* s_gameWindow = nullptr;
bool s_trackpadActive = false;
bool s_pendingCheck = false;
Uint64 s_lastDisplayEventTicks = 0;

// Debounce rapid plug/unplug: act only after the display set is stable.
const Uint64 DISPLAY_SETTLE_MS = 500;

} // anonymous namespace

void GXExternalDisplay_Startup(SDL_Window* window)
{
	s_gameWindow = window;
	s_pendingCheck = true;
	s_lastDisplayEventTicks = 0; // launch check runs immediately, no settle delay
	fprintf(stderr, "INFO: GXExternalDisplay startup (screens=%lu)\n",
	        (unsigned long)[UIScreen screens].count);
}

void GXExternalDisplay_NotifyDisplayChange(void)
{
	s_pendingCheck = true;
	s_lastDisplayEventTicks = SDL_GetTicks();
}

void GXExternalDisplay_Poll(void)
{
	if (!s_pendingCheck || !s_gameWindow) {
		return;
	}
	if (s_lastDisplayEventTicks != 0 &&
	    (SDL_GetTicks() - s_lastDisplayEventTicks) < DISPLAY_SETTLE_MS) {
		return; // let rapid plug/unplug settle
	}
	s_pendingCheck = false;
	// Migration logic lands in Task 2.
}

bool GXExternalDisplay_TrackpadActive(void)
{
	return s_trackpadActive;
}

#endif // TARGET_OS_IPHONE
```

- [ ] **Step 3: Register the file in CMake**

In `GeneralsMD/Code/GameEngineDevice/CMakeLists.txt`, inside the existing `else()` branch (the non-WIN32 list that appends `Source/SDL3GameEngine.cpp` etc., around line 203), add after the `list(APPEND ...)` block:

```cmake
    # GeneralsX @feature 11/07/2026 iPhone external-display + trackpad platform layer (ObjC++)
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        enable_language(OBJCXX)
        list(APPEND GAMEENGINEDEVICE_SRC
            Source/SDL3Device/iOSExternalDisplay.mm
        )
        # The C++ precompiled header does not apply to ObjC++ translation units.
        set_source_files_properties(Source/SDL3Device/iOSExternalDisplay.mm
            PROPERTIES SKIP_PRECOMPILE_HEADERS ON)
    endif()
```

And after the `if(SAGE_USE_SDL3)` link block near the bottom of the file, add:

```cmake
# GeneralsX @feature 11/07/2026 Direct UIKit use by the iOS external-display layer.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    target_link_libraries(z_gameenginedevice PUBLIC "-framework UIKit")
endif()
```

(SDL already links UIKit transitively; this makes our direct dependency explicit.)

- [ ] **Step 4: Hook the engine loop**

In `GeneralsMD/Code/GameEngineDevice/Source/SDL3GameEngine.cpp`:

Add the include next to the other SDL3Device includes at the top:

```cpp
#include "SDL3Device/iOSExternalDisplay.h"
```

In `pollSDL3Events()`, add new cases inside the existing `switch (event.type)` (place them next to the other `#if TARGET_OS_IPHONE` cases):

```cpp
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
			case SDL_EVENT_DISPLAY_ADDED:
			case SDL_EVENT_DISPLAY_REMOVED:
				// GeneralsX @feature 11/07/2026 External monitor hot-plug; applied at
				// the frame boundary by GXExternalDisplay_Poll().
				GXExternalDisplay_NotifyDisplayChange();
				break;
#endif
```

In `SDL3GameEngine::update()`, inside the existing `#if TARGET_OS_IPHONE` block, apply pending migrations at the frame boundary — after the pause check so we never migrate while backgrounded (iOS owns the layer then):

```cpp
	if (iosShouldPauseRendering()) {
		SDL_Delay(50);
		return;
	}
	// Frame boundary and foregrounded: safe point to move the window between
	// screens — no GPU work is in flight.
	GXExternalDisplay_Poll();
```

- [ ] **Step 5: Hook startup in SDL3Main**

In `GeneralsMD/Code/Main/SDL3Main.cpp`: add `#include "SDL3Device/iOSExternalDisplay.h"` next to the other includes. Then, inside the existing `#if TARGET_OS_IPHONE` block that injects `-xres/-yres` (right after `ApplicationHWnd = (HWND)TheSDL3Window;` and **before** `SDL_GetWindowSizeInPixels` is consulted), add:

```cpp
		// GeneralsX @feature 11/07/2026 If a wired monitor is already attached at
		// launch, move the window there BEFORE deriving -xres/-yres so the game
		// resolution matches the monitor, not the phone.
		GXExternalDisplay_Startup(TheSDL3Window);
		GXExternalDisplay_Poll();
		SDL_SyncWindow(TheSDL3Window);
```

- [ ] **Step 6: Build**

Run: `cmake --preset ios-vulkan && cmake --build build/ios-vulkan --target z_generals -j`
Expected: clean link. If `enable_language(OBJCXX)` fails under the preset, fall back to compiling the file as C++ with ObjC++ flags: remove `enable_language` and add `set_source_files_properties(Source/SDL3Device/iOSExternalDisplay.mm PROPERTIES LANGUAGE CXX COMPILE_OPTIONS "-xobjective-c++")`.

- [ ] **Step 7: Commit**

```bash
git add GeneralsMD/Code/GameEngineDevice/Include/SDL3Device/iOSExternalDisplay.h \
        GeneralsMD/Code/GameEngineDevice/Source/SDL3Device/iOSExternalDisplay.mm \
        GeneralsMD/Code/GameEngineDevice/CMakeLists.txt \
        GeneralsMD/Code/GameEngineDevice/Source/SDL3GameEngine.cpp \
        GeneralsMD/Code/Main/SDL3Main.cpp
git commit -m "ios: scaffold external-display platform layer (hooks, CMake, ObjC++)"
```

---

### Task 2: Spike — migrate the SDL window between screens (the load-bearing risk)

The spec's risk #1: prove the `UIWindow` migration keeps DXVK presenting before building anything else on top.

**Files:**
- Modify: `GeneralsMD/Code/GameEngineDevice/Source/SDL3Device/iOSExternalDisplay.mm`

- [ ] **Step 1: Implement screen selection and migration**

Replace the anonymous namespace contents and `GXExternalDisplay_Poll` in `iOSExternalDisplay.mm` with:

```objc
namespace {

SDL_Window* s_gameWindow = nullptr;
bool s_trackpadActive = false;
bool s_pendingCheck = false;
Uint64 s_lastDisplayEventTicks = 0;
UIWindow* s_trackpadWindow = nil;   // created in Task 4

const Uint64 DISPLAY_SETTLE_MS = 500;

UIWindow* gameUIWindow(void)
{
	if (!s_gameWindow) {
		return nil;
	}
	return (__bridge UIWindow*)SDL_GetPointerProperty(
		SDL_GetWindowProperties(s_gameWindow),
		SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
}

// Policy (config override lands in Task 6): pick the first non-main screen.
UIScreen* desiredExternalScreen(void)
{
	for (UIScreen* screen in [UIScreen screens]) {
		if (screen != [UIScreen mainScreen]) {
			return screen;
		}
	}
	return nil;
}

// Move the SDL window's UIWindow to `screen`. The CAMetalLayer inside SDL's
// view hierarchy survives the move, so DXVK experiences it as a resize, not a
// surface loss. SDL picks up the new size through its view-controller layout
// callbacks and emits SDL_EVENT_WINDOW_RESIZED.
bool migrateGameWindowToScreen(UIScreen* screen)
{
	UIWindow* window = gameUIWindow();
	if (!window || !screen) {
		return false;
	}
	window.screen = screen;
	window.frame = screen.bounds;
	[window setNeedsLayout];
	[window layoutIfNeeded];
	int pw = 0, ph = 0;
	SDL_SyncWindow(s_gameWindow);
	SDL_GetWindowSizeInPixels(s_gameWindow, &pw, &ph);
	fprintf(stderr, "INFO: GXExternalDisplay migrated window to %s screen, drawable %dx%d\n",
	        (screen == [UIScreen mainScreen]) ? "main" : "external", pw, ph);
	return true;
}

void enterExternalMode(UIScreen* screen)
{
	if (!migrateGameWindowToScreen(screen)) {
		fprintf(stderr, "WARNING: GXExternalDisplay migration failed; staying on phone screen\n");
		return;
	}
	s_trackpadActive = true;
	// Trackpad window creation lands in Task 4; resolution change in Task 3.
}

void leaveExternalMode(void)
{
	migrateGameWindowToScreen([UIScreen mainScreen]);
	s_trackpadActive = false;
	// Trackpad window teardown lands in Task 4; resolution change in Task 3.
}

} // anonymous namespace
```

And the poll body:

```objc
void GXExternalDisplay_Poll(void)
{
	if (!s_pendingCheck || !s_gameWindow) {
		return;
	}
	if (s_lastDisplayEventTicks != 0 &&
	    (SDL_GetTicks() - s_lastDisplayEventTicks) < DISPLAY_SETTLE_MS) {
		return;
	}
	s_pendingCheck = false;

	UIScreen* external = desiredExternalScreen();
	if (external && !s_trackpadActive) {
		enterExternalMode(external);
	} else if (!external && s_trackpadActive) {
		leaveExternalMode();
	}
}
```

(`GXExternalDisplay_Startup` and `GXExternalDisplay_NotifyDisplayChange` stay as in Task 1.)

- [ ] **Step 2: Build**

Run: `cmake --build build/ios-vulkan --target z_generals -j`
Expected: clean link.

- [ ] **Step 3: Commit**

```bash
git add GeneralsMD/Code/GameEngineDevice/Source/SDL3Device/iOSExternalDisplay.mm
git commit -m "ios: spike — migrate game UIWindow between phone and external screen"
```

- [ ] **Step 4: [HARDWARE CHECKPOINT] Validate the spike on device**

Ask the user to run `./scripts/build/ios/package-ios-zh.sh --dev --install` on an iPhone 15+ and verify with a USB-C monitor:
1. Launch with monitor attached → game renders on the monitor (stderr log shows the external drawable size).
2. Launch without, plug in mid-menu → game moves to the monitor and keeps rendering (no DXVK crash/black screen).
3. Unplug → game returns to the phone screen and keeps rendering.

**Do not proceed to Task 3 until this passes.** If DXVK dies on migration, the fallback strategy to investigate is recreating the swapchain via a forced `SDL_EVENT_WINDOW_RESIZED`/display-mode reset after the move — record findings in the diary either way.

---

### Task 3: Game resolution follows the active screen

**Files:**
- Modify: `GeneralsMD/Code/GameEngineDevice/Source/SDL3Device/iOSExternalDisplay.mm`

- [ ] **Step 1: Add the engine resolution-change helper**

This reuses the exact runtime recipe from `GeneralsMD/Code/GameEngine/Source/GameClient/GUI/GUICallbacks/Menus/OptionsMenu.cpp:862-890` (the options-screen apply path). Add these includes at the top of `iOSExternalDisplay.mm` (mirror OptionsMenu.cpp if any header name differs):

```cpp
#include "Common/GlobalData.h"
#include "GameClient/Display.h"
#include "GameClient/InGameUI.h"
#include "GameClient/Mouse.h"
#include "GameClient/Shell.h"
#include "GameClient/HeaderTemplate.h"
#include "GameClient/View.h"
```

Add to the anonymous namespace:

```cpp
// Re-derive the game's internal resolution from the current drawable and apply
// it through the engine's runtime display-mode path (same recipe as the
// options screen). No-op before the engine exists: the launch path derives
// -xres/-yres in SDL3Main from the already-migrated window instead.
void applyGameResolutionFromWindow(void)
{
	if (!TheDisplay || !TheWritableGlobalData || !s_gameWindow) {
		return;
	}
	int pw = 0, ph = 0;
	SDL_GetWindowSizeInPixels(s_gameWindow, &pw, &ph);
	if (pw <= 0 || ph <= 0) {
		return;
	}
	Int xres = pw & ~1; // keep it even, matching the SDL3Main launch path
	Int yres = ph;
	if (xres == (Int)TheDisplay->getWidth() && yres == (Int)TheDisplay->getHeight()) {
		return;
	}
	if (!TheDisplay->setDisplayMode(xres, yres, 32, TheDisplay->getWindowed())) {
		fprintf(stderr, "WARNING: GXExternalDisplay setDisplayMode(%d,%d) failed\n", xres, yres);
		return;
	}
	TheWritableGlobalData->m_xResolution = xres;
	TheWritableGlobalData->m_yResolution = yres;
	TheHeaderTemplateManager->onResolutionChanged();
	TheMouse->onResolutionChanged();
	TheShell->recreateWindowLayouts();
	TheInGameUI->recreateControlBar();
	TheInGameUI->refreshCustomUiResources();
	TheTacticalView->setCameraHeightAboveGroundLimitsToDefault();
	TheTacticalView->setZoomToMax();
	fprintf(stderr, "INFO: GXExternalDisplay game resolution now %dx%d\n", xres, yres);
}
```

- [ ] **Step 2: Call it from both mode transitions**

In `enterExternalMode`, after `s_trackpadActive = true;`, and in `leaveExternalMode`, after `s_trackpadActive = false;`, add:

```cpp
	applyGameResolutionFromWindow();
```

- [ ] **Step 3: Build**

Run: `cmake --build build/ios-vulkan --target z_generals -j`
Expected: clean link. If a `GameClient/...` include name is wrong, take the correct one from the includes of `OptionsMenu.cpp`.

- [ ] **Step 4: Commit**

```bash
git add GeneralsMD/Code/GameEngineDevice/Source/SDL3Device/iOSExternalDisplay.mm
git commit -m "ios: re-derive game resolution when the active screen changes"
```

---

### Task 4: Trackpad window and relative input synthesis

**Files:**
- Modify: `GeneralsMD/Code/GameEngineDevice/Source/SDL3Device/iOSExternalDisplay.mm`

- [ ] **Step 1: Add the SDL event synthesis helper**

Add to the anonymous namespace (above the view class). Note `which = 0`: the global/indirect mouse ID routes these through `SDL3Mouse`'s relative virtual-cursor branch (see "Prerequisites").

```cpp
// Trackpad feel constants (tuned on device; keep them together).
const float TRACKPAD_SENSITIVITY = 2.5f;   // phone points -> game-window points
const Uint64 TAP_MAX_MS = 250;             // press shorter than this = tap
const float TAP_SLOP_PT = 8.0f;            // movement below this keeps a tap a tap
const Uint64 TAP_LINK_MS = 300;            // tap-then-press window for drag / double-click
const Uint64 TRACKPAD_LONG_PRESS_MS = 600; // stationary hold = right click
const float PINCH_WHEEL_STEP_RATIO = 0.06f;

void pushRelativeMouse(Uint32 type, float dx = 0.0f, float dy = 0.0f,
                       Uint8 button = 0, float wheelY = 0.0f, Uint8 clicks = 1)
{
	if (!s_gameWindow) {
		return;
	}
	const SDL_WindowID windowID = SDL_GetWindowID(s_gameWindow);
	SDL_Event ev;
	SDL_zero(ev);
	ev.type = type;
	switch (type) {
		case SDL_EVENT_MOUSE_MOTION:
			ev.motion.windowID = windowID;
			ev.motion.which = 0; // indirect-pointer ID -> virtual-cursor branch
			ev.motion.xrel = dx;
			ev.motion.yrel = dy;
			break;
		case SDL_EVENT_MOUSE_BUTTON_DOWN:
		case SDL_EVENT_MOUSE_BUTTON_UP:
			ev.button.windowID = windowID;
			ev.button.which = 0;
			ev.button.button = button;
			ev.button.down = (type == SDL_EVENT_MOUSE_BUTTON_DOWN);
			ev.button.clicks = clicks;
			break;
		case SDL_EVENT_MOUSE_WHEEL:
			ev.wheel.windowID = windowID;
			ev.wheel.which = 0;
			ev.wheel.x = 0.0f;
			ev.wheel.y = wheelY;
			break;
	}
	SDL_PushEvent(&ev);
}
```

- [ ] **Step 2: Add the trackpad view**

ObjC classes cannot live inside a C++ namespace, so ordering within the file matters: close the anonymous namespace after `pushRelativeMouse` (Step 1), put the `GXTrackpadView` class at file scope, then reopen `namespace { ... }` for Step 3's `createTrackpadWindow` (which instantiates the view). The final layout is: `namespace { state + helpers + pushRelativeMouse }` → `GXTrackpadView` → `namespace { createTrackpadWindow + destroyTrackpadWindow + enter/leave + resolution helper }` → the four `GXExternalDisplay_*` functions. Gesture vocabulary per the spec: move = cursor, tap = left click (double-tap aware), tap-then-drag = LMB drag, long-press = right click, two-finger drag = scroll (RMB drag, matching the absolute translator's camera-pan mapping), pinch = zoom (wheel).

```objc
@interface GXTrackpadView : UIView
@end

@implementation GXTrackpadView {
	// One-finger state
	UITouch* _finger1;
	CGPoint _f1Prev;
	CGPoint _f1Down;
	Uint64 _f1DownTicks;
	float _f1TotalMove;
	BOOL _dragging;       // LMB held (tap-then-drag)
	BOOL _longPressFired;
	NSTimer* _longPressTimer;
	// Tap-sequence state (double-click and tap-then-drag linking)
	Uint64 _lastTapTicks;
	// Two-finger state
	UITouch* _finger2;
	CGPoint _f2Prev;
	BOOL _panning;        // RMB held
	float _pinchDist;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	if ((self = [super initWithFrame:frame])) {
		self.multipleTouchEnabled = YES;
		self.backgroundColor = [UIColor blackColor];
	}
	return self;
}

- (void)cancelLongPress
{
	[_longPressTimer invalidate];
	_longPressTimer = nil;
}

- (void)longPressFired
{
	_longPressTimer = nil;
	if (_finger1 && !_dragging && !_panning && !_longPressFired) {
		_longPressFired = YES;
		_lastTapTicks = 0;
		pushRelativeMouse(SDL_EVENT_MOUSE_BUTTON_DOWN, 0, 0, SDL_BUTTON_RIGHT);
		pushRelativeMouse(SDL_EVENT_MOUSE_BUTTON_UP, 0, 0, SDL_BUTTON_RIGHT);
	}
}

- (CGFloat)pinchDistance
{
	CGPoint a = [_finger1 locationInView:self];
	CGPoint b = [_finger2 locationInView:self];
	const CGFloat dx = a.x - b.x, dy = a.y - b.y;
	return sqrt(dx * dx + dy * dy);
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
	for (UITouch* touch in touches) {
		if (!_finger1) {
			_finger1 = touch;
			_f1Prev = _f1Down = [touch locationInView:self];
			_f1DownTicks = SDL_GetTicks();
			_f1TotalMove = 0.0f;
			_longPressFired = NO;
			// Tap-then-press within the link window starts an LMB drag
			// (band select) instead of a fresh tap.
			if (_lastTapTicks != 0 && (_f1DownTicks - _lastTapTicks) <= TAP_LINK_MS) {
				_dragging = YES;
				_lastTapTicks = 0;
				pushRelativeMouse(SDL_EVENT_MOUSE_BUTTON_DOWN, 0, 0, SDL_BUTTON_LEFT);
			} else {
				_dragging = NO;
				[self cancelLongPress];
				_longPressTimer = [NSTimer scheduledTimerWithTimeInterval:TRACKPAD_LONG_PRESS_MS / 1000.0
					target:self selector:@selector(longPressFired) userInfo:nil repeats:NO];
			}
		} else if (!_finger2 && !_panning) {
			// Second finger: end any drag, start a camera scroll (RMB drag,
			// same mapping as the absolute translator's two-finger pan).
			_finger2 = touch;
			_f2Prev = [touch locationInView:self];
			[self cancelLongPress];
			_lastTapTicks = 0;
			if (_dragging) {
				pushRelativeMouse(SDL_EVENT_MOUSE_BUTTON_UP, 0, 0, SDL_BUTTON_LEFT);
				_dragging = NO;
			}
			_panning = YES;
			_pinchDist = [self pinchDistance];
			pushRelativeMouse(SDL_EVENT_MOUSE_BUTTON_DOWN, 0, 0, SDL_BUTTON_RIGHT);
		}
		// Third and later fingers: ignored.
	}
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
	if (![touches containsObject:_finger1] &&
	    (!_finger2 || ![touches containsObject:_finger2])) {
		return;
	}
	if (_panning) {
		// Centroid delta scrolls the camera; pinch steps the wheel.
		CGPoint p1 = [_finger1 locationInView:self];
		CGPoint p2 = [_finger2 locationInView:self];
		const float dx = (float)((p1.x - _f1Prev.x) + (p2.x - _f2Prev.x)) * 0.5f;
		const float dy = (float)((p1.y - _f1Prev.y) + (p2.y - _f2Prev.y)) * 0.5f;
		_f1Prev = p1;
		_f2Prev = p2;
		if (dx != 0.0f || dy != 0.0f) {
			pushRelativeMouse(SDL_EVENT_MOUSE_MOTION,
			                  dx * TRACKPAD_SENSITIVITY, dy * TRACKPAD_SENSITIVITY);
		}
		const float dist = (float)[self pinchDistance];
		if (_pinchDist > 1.0f) {
			const float ratio = dist / _pinchDist;
			if (ratio > 1.0f + PINCH_WHEEL_STEP_RATIO) {
				pushRelativeMouse(SDL_EVENT_MOUSE_WHEEL, 0, 0, 0, 1.0f);
				_pinchDist = dist;
			} else if (ratio < 1.0f - PINCH_WHEEL_STEP_RATIO) {
				pushRelativeMouse(SDL_EVENT_MOUSE_WHEEL, 0, 0, 0, -1.0f);
				_pinchDist = dist;
			}
		}
		return;
	}
	if (_finger1 && [touches containsObject:_finger1]) {
		CGPoint p = [_finger1 locationInView:self];
		const float dx = (float)(p.x - _f1Prev.x);
		const float dy = (float)(p.y - _f1Prev.y);
		_f1Prev = p;
		_f1TotalMove += fabsf(dx) + fabsf(dy);
		if (_f1TotalMove >= TAP_SLOP_PT) {
			[self cancelLongPress];
		}
		if (dx != 0.0f || dy != 0.0f) {
			pushRelativeMouse(SDL_EVENT_MOUSE_MOTION,
			                  dx * TRACKPAD_SENSITIVITY, dy * TRACKPAD_SENSITIVITY);
		}
	}
}

- (void)endFinger1:(BOOL)cancelled
{
	[self cancelLongPress];
	const Uint64 now = SDL_GetTicks();
	if (_dragging) {
		pushRelativeMouse(SDL_EVENT_MOUSE_BUTTON_UP, 0, 0, SDL_BUTTON_LEFT);
		_dragging = NO;
	} else if (!cancelled && !_longPressFired &&
	           (now - _f1DownTicks) <= TAP_MAX_MS && _f1TotalMove < TAP_SLOP_PT) {
		// Tap = click at the virtual cursor. Second tap inside the link
		// window is a double-click (the cursor did not move, so no radius
		// check is needed).
		const bool isDouble = (_lastTapTicks != 0 && (now - _lastTapTicks) <= TAP_LINK_MS);
		const Uint8 clicks = isDouble ? 2 : 1;
		pushRelativeMouse(SDL_EVENT_MOUSE_BUTTON_DOWN, 0, 0, SDL_BUTTON_LEFT, 0.0f, clicks);
		pushRelativeMouse(SDL_EVENT_MOUSE_BUTTON_UP, 0, 0, SDL_BUTTON_LEFT, 0.0f, clicks);
		_lastTapTicks = isDouble ? 0 : now;
	} else {
		_lastTapTicks = 0;
	}
	_finger1 = nil;
	_longPressFired = NO;
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
	for (UITouch* touch in touches) {
		if (touch == _finger2 || (touch == _finger1 && _panning)) {
			// Either pan finger lifting ends the scroll.
			pushRelativeMouse(SDL_EVENT_MOUSE_BUTTON_UP, 0, 0, SDL_BUTTON_RIGHT);
			_panning = NO;
			_finger1 = nil;
			_finger2 = nil;
			_lastTapTicks = 0;
		} else if (touch == _finger1) {
			[self endFinger1:NO];
		}
	}
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
	for (UITouch* touch in touches) {
		if (touch == _finger2 || (touch == _finger1 && _panning)) {
			pushRelativeMouse(SDL_EVENT_MOUSE_BUTTON_UP, 0, 0, SDL_BUTTON_RIGHT);
			_panning = NO;
			_finger1 = nil;
			_finger2 = nil;
			_lastTapTicks = 0;
		} else if (touch == _finger1) {
			[self endFinger1:YES];
		}
	}
}

@end
```

- [ ] **Step 3: Add the trackpad surface (window + hints) and wire it into the mode transitions**

Add to the anonymous namespace:

```objc
void createTrackpadWindow(void)
{
	if (s_trackpadWindow) {
		return;
	}
	UIScreen* phone = [UIScreen mainScreen];
	s_trackpadWindow = [[UIWindow alloc] initWithFrame:phone.bounds];
	s_trackpadWindow.screen = phone;
	UIViewController* vc = [[UIViewController alloc] init];
	GXTrackpadView* pad = [[GXTrackpadView alloc] initWithFrame:phone.bounds];
	pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	// Minimal affordance: faint hint text, dimmed screen to save battery.
	UILabel* hint = [[UILabel alloc] initWithFrame:pad.bounds];
	hint.autoresizingMask = pad.autoresizingMask;
	hint.text = @"trackpad — tap to click · tap-drag to select · hold for right click\n"
	            @"two fingers to scroll · pinch to zoom";
	hint.numberOfLines = 0;
	hint.textAlignment = NSTextAlignmentCenter;
	hint.font = [UIFont systemFontOfSize:14];
	hint.textColor = [UIColor colorWithWhite:0.35 alpha:1.0];
	hint.userInteractionEnabled = NO;
	[pad addSubview:hint];
	vc.view = pad;
	s_trackpadWindow.rootViewController = vc;
	s_trackpadWindow.windowLevel = UIWindowLevelNormal;
	[s_trackpadWindow makeKeyAndVisible];
	[UIScreen mainScreen].brightness = 0.25; // dim; iOS restores on app exit
}

void destroyTrackpadWindow(void)
{
	if (!s_trackpadWindow) {
		return;
	}
	s_trackpadWindow.hidden = YES;
	s_trackpadWindow = nil;
}
```

In `enterExternalMode`, after `s_trackpadActive = true;` add `createTrackpadWindow();`. In `leaveExternalMode`, after `s_trackpadActive = false;` add `destroyTrackpadWindow();`. (Keep `applyGameResolutionFromWindow()` as the last call in both.)

- [ ] **Step 4: Build**

Run: `cmake --build build/ios-vulkan --target z_generals -j`
Expected: clean link.

- [ ] **Step 5: Commit**

```bash
git add GeneralsMD/Code/GameEngineDevice/Source/SDL3Device/iOSExternalDisplay.mm
git commit -m "ios: phone-screen trackpad window driving the virtual cursor"
```

---

### Task 5: Cursor visibility and gesture-translator guard

Two integration details in existing files.

**Files:**
- Modify: `GeneralsMD/Code/GameEngineDevice/Source/SDL3Device/GameClient/SDL3Mouse.cpp` (the in-flight `draw()` implementation)
- Modify: `GeneralsMD/Code/GameEngineDevice/Source/SDL3GameEngine.cpp`

- [ ] **Step 1: Draw the game cursor when the trackpad drives it**

`SDL3Mouse::draw()` currently gates on `SDL_HasMouse()` — correct for iPad pointer lock, but with a trackpad and *no* physical mouse attached, `SDL_HasMouse()` is false and the cursor would never render. In `SDL3Mouse.cpp`, add the include near the other SDL3Device includes:

```cpp
#include "SDL3Device/iOSExternalDisplay.h"
```

and change the gate in `draw()`:

```cpp
	if (SDL_HasMouse() && m_IsVisible)
```

to:

```cpp
	// GeneralsX @feature 11/07/2026 The external-display trackpad drives the
	// virtual cursor without any mouse device attached.
	if ((SDL_HasMouse() || GXExternalDisplay_TrackpadActive()) && m_IsVisible)
```

- [ ] **Step 2: Keep the absolute gesture translator out of trackpad mode**

Touches on the phone land in the UIKit trackpad window, so SDL should never see finger events while migrated — but belt-and-braces (matching the file's existing style): in `SDL3GameEngine.cpp`, `pollSDL3Events()`, at the top of the `SDL_EVENT_FINGER_*` case block, add:

```cpp
				case SDL_EVENT_FINGER_DOWN:
				case SDL_EVENT_FINGER_MOTION:
				case SDL_EVENT_FINGER_UP:
				case SDL_EVENT_FINGER_CANCELED:
					// GeneralsX @feature 11/07/2026 In trackpad mode the phone's
					// touches belong to the UIKit trackpad window; any stray SDL
					// finger event must not double-drive the cursor.
					if (GXExternalDisplay_TrackpadActive()) {
						break;
					}
					if (TheMouse && m_SDLWindow) {
```

- [ ] **Step 3: Build**

Run: `cmake --build build/ios-vulkan --target z_generals -j`
Expected: clean link.

- [ ] **Step 4: Commit**

```bash
git add GeneralsMD/Code/GameEngineDevice/Source/SDL3Device/GameClient/SDL3Mouse.cpp \
        GeneralsMD/Code/GameEngineDevice/Source/SDL3GameEngine.cpp
git commit -m "ios: render game cursor in trackpad mode; guard finger translator"
```

---

### Task 6: Config override and AirPlay filtering

**Files:**
- Modify: `GeneralsMD/Code/GameEngineDevice/Source/SDL3Device/iOSExternalDisplay.mm`
- Modify: `ios/config/Options.ini`

- [ ] **Step 1: Read `GX_EXTERNAL_DISPLAY` from Options.ini**

The game's working directory on iOS is `<bundle>/GameData` (set in `SDL3Main.cpp`), where `ios/config/Options.ini` is staged by the packaging script. Add to the anonymous namespace:

```cpp
enum class ExternalDisplayPolicy { Wired, Any, Off };

// GX_EXTERNAL_DISPLAY = wired (default) | any | off
// Tiny standalone parse; runs once at startup, before the engine's own
// preferences machinery exists.
ExternalDisplayPolicy readExternalDisplayPolicy(void)
{
	ExternalDisplayPolicy policy = ExternalDisplayPolicy::Wired;
	FILE* f = fopen("Options.ini", "r");
	if (!f) {
		return policy;
	}
	char line[256];
	while (fgets(line, sizeof(line), f)) {
		char key[64] = {0}, value[64] = {0};
		if (sscanf(line, " %63[^= \t] = %63s", key, value) == 2 &&
		    strcmp(key, "GX_EXTERNAL_DISPLAY") == 0) {
			if (strcasecmp(value, "off") == 0)  policy = ExternalDisplayPolicy::Off;
			else if (strcasecmp(value, "any") == 0) policy = ExternalDisplayPolicy::Any;
			else policy = ExternalDisplayPolicy::Wired;
		}
	}
	fclose(f);
	return policy;
}

ExternalDisplayPolicy s_policy = ExternalDisplayPolicy::Wired;
```

In `GXExternalDisplay_Startup`, before setting `s_pendingCheck`, add:

```cpp
	s_policy = readExternalDisplayPolicy();
```

(Add `#include <cstring>` and `#include <strings.h>` at the top if not already present.)

- [ ] **Step 2: Apply the policy in screen selection**

Replace `desiredExternalScreen()`:

```objc
// iOS has no public wired-vs-AirPlay API. Heuristic: AirPlay-to-Apple-TV
// screens report the .tv interface idiom in their trait collection; wired
// USB-C/HDMI displays do not. Third-party AirPlay receivers may slip through
// — GX_EXTERNAL_DISPLAY=off is the escape hatch (and =any embraces AirPlay).
UIScreen* desiredExternalScreen(void)
{
	if (s_policy == ExternalDisplayPolicy::Off) {
		return nil;
	}
	for (UIScreen* screen in [UIScreen screens]) {
		if (screen == [UIScreen mainScreen]) {
			continue;
		}
		if (s_policy == ExternalDisplayPolicy::Wired &&
		    screen.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomTV) {
			fprintf(stderr, "INFO: GXExternalDisplay ignoring AirPlay-like screen\n");
			continue;
		}
		return screen;
	}
	return nil;
}
```

- [ ] **Step 3: Document the setting in the staged config**

Append to `ios/config/Options.ini`:

```ini
GX_EXTERNAL_DISPLAY = wired
```

- [ ] **Step 4: Build**

Run: `cmake --build build/ios-vulkan --target z_generals -j`
Expected: clean link.

- [ ] **Step 5: Commit**

```bash
git add GeneralsMD/Code/GameEngineDevice/Source/SDL3Device/iOSExternalDisplay.mm ios/config/Options.ini
git commit -m "ios: GX_EXTERNAL_DISPLAY policy (wired/any/off) with AirPlay heuristic"
```

---

### Task 7: On-device validation, diary, and wrap-up

- [ ] **Step 1: [HARDWARE CHECKPOINT] Full on-device validation**

Ask the user to run `./scripts/build/ios/package-ios-zh.sh --dev --install` (or a full-asset package) on an iPhone 15+ with a USB-C monitor and walk this checklist:

1. **Launch attached:** game on monitor at monitor-native resolution; phone shows the dim trackpad surface with hints.
2. **Hot-plug in shell menu and in a skirmish:** game migrates, UI re-lays out at the new resolution, no crash.
3. **Unplug both places:** game returns to the phone, absolute touch gestures work again.
4. **Trackpad feel:** cursor tracks finger motion (tune `TRACKPAD_SENSITIVITY` if traversal is too slow/fast); W3D ANI cursor visible and context-switching on the monitor.
5. **Gestures:** tap selects; tap-then-drag band-selects; long-press deselects (right click); two-finger drag scrolls the camera; pinch zooms; double-tap double-clicks (selects all units of a type).
6. **Lifecycle:** background + resume while migrated; app switcher; rapid plug/unplug (debounce holds).
7. **AirPlay (if available):** AirPlay screen is ignored under `wired`, honored under `any`.

Fix what fails; sensitivity/threshold constants at the top of the trackpad section are the expected tuning knobs.

- [ ] **Step 2: Diary entry**

Append a dated section to `docs/DEV_BLOG/2026-07-DIARY.md` in the established format (Changes / Validation), covering: the migration mechanism (UIWindow reassignment, CAMetalLayer survival), the trackpad synthesis path riding the virtual cursor, the resolution recipe reuse, the AirPlay heuristic and `GX_EXTERNAL_DISPLAY`, and the spike findings from Task 2.

- [ ] **Step 3: Final build sweep**

Run the full iOS build one more time plus, if configured locally, the macOS preset (`cmake --build build/macos-vulkan --target z_generals -j`) to confirm the shared-file edits (`SDL3Mouse.cpp`, `SDL3GameEngine.cpp`) still compile where `TARGET_OS_IPHONE` is false.

- [ ] **Step 4: Commit**

```bash
git add docs/DEV_BLOG/2026-07-DIARY.md
git commit -m "docs: diary — iPhone external-display trackpad mode"
```

---

## Out of scope (YAGNI, per spec)

- Pointer acceleration curves, scroll momentum, on-screen trackpad buttons.
- Mirroring the game to both displays.
- The Generals (non-Zero-Hour) tree — the iOS port is Zero Hour only.
- Runtime settings UI for sensitivity (constants + Options.ini only).
