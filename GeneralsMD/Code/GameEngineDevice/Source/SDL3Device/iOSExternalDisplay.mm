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
UIWindow* s_trackpadWindow = nil;   // created in Task 4

// Debounce rapid plug/unplug: act only after the display set is stable.
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

	UIScreen* external = desiredExternalScreen();
	if (external && !s_trackpadActive) {
		enterExternalMode(external);
	} else if (!external && s_trackpadActive) {
		leaveExternalMode();
	}
}

bool GXExternalDisplay_TrackpadActive(void)
{
	return s_trackpadActive;
}

#endif // TARGET_OS_IPHONE
