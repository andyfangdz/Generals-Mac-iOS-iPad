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

// Internal: re-derive the game's internal resolution after a screen change.
// Lives in iOSExternalDisplayResolution.cpp (a normal C++ TU) because the
// engine headers' Bool/Byte typedefs collide with UIKit's MacTypes in the
// ObjC++ TU. No-op before the engine exists.
void GXExternalDisplay_ApplyGameResolution(int pixelWidth, int pixelHeight);

// Internal: true once the engine subsystems needed by a runtime resolution
// change exist. Migration waits for this — the external UIWindowScene can
// connect while the engine is still initializing (launch-attached monitor).
bool GXExternalDisplay_EngineReady(void);

#endif // TARGET_OS_IPHONE
