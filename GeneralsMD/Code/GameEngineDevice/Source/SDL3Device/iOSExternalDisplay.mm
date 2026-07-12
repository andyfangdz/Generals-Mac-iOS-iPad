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
