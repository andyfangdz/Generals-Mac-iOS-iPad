// GeneralsX @feature 11/07/2026 Engine-facing half of the iPhone external-display
// layer: applies a runtime resolution change when the game window moves between
// screens. Kept out of iOSExternalDisplay.mm because the engine headers'
// Bool/Byte typedefs collide with UIKit's MacTypes in an ObjC++ TU.
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

#include "SDL3Device/iOSExternalDisplay.h"

#include "Common/GlobalData.h"
#include "GameClient/Display.h"
#include "GameClient/InGameUI.h"
#include "GameClient/Mouse.h"
#include "GameClient/Shell.h"
#include "GameClient/HeaderTemplate.h"
#include "GameClient/View.h"

#include <cstdio>

bool GXExternalDisplay_EngineReady(void)
{
	return TheDisplay != nullptr && TheWritableGlobalData != nullptr &&
	       TheHeaderTemplateManager != nullptr && TheMouse != nullptr &&
	       TheShell != nullptr && TheInGameUI != nullptr && TheTacticalView != nullptr;
}

// Same recipe as the options screen's resolution apply (OptionsMenu.cpp):
// setDisplayMode + resolution-dependent subsystem refreshes. No-op before the
// engine exists — the launch path derives -xres/-yres in SDL3Main instead.
void GXExternalDisplay_ApplyGameResolution(int pixelWidth, int pixelHeight)
{
	if (!TheDisplay || !TheWritableGlobalData || pixelWidth <= 0 || pixelHeight <= 0) {
		return;
	}
	const Int xres = pixelWidth & ~1; // keep it even, matching the SDL3Main launch path
	const Int yres = pixelHeight;
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

#endif // TARGET_OS_IPHONE
