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

// Call at the TOP of the per-frame SDL event poll. In trackpad mode this
// services the runloop so UIKit delivers pending touches, then flushes the
// accumulated finger motion as a single coalesced SDL event — same-frame
// delivery, and the queue can never back up behind a fast-moving finger.
void GXExternalDisplay_PumpTrackpadInput(void);

// True while the game window lives on an external screen and the phone
// touchscreen acts as a trackpad.
bool GXExternalDisplay_TrackpadActive(void);

// True on iPhone-idiom devices. The pointer-lock/virtual-cursor mouse model
// (and the trackpad feature it serves) is iPhone-only; iPads use the native
// absolute pointer model and manage external displays themselves.
bool GXExternalDisplay_IsPhoneIdiom(void);

// True while the phone's interactive scene is foreground-active. SDL's scene
// delegate conflates every scene's lifecycle into app-level active/inactive
// callbacks, and the external-display scene NEVER reports active — so SDL's
// focus events would pause the engine forever in trackpad mode. This queries
// UIKit directly for the scene that actually matters.
bool GXExternalDisplay_PhoneSceneActive(void);

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
