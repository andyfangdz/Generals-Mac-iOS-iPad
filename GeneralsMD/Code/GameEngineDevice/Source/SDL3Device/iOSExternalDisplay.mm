// GeneralsX @feature 11/07/2026 External-display + touchscreen-trackpad mode for iPhone.
#include "SDL3Device/iOSExternalDisplay.h"

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <SDL3/SDL.h>
#include <cstdio>
#include <cstring>
#include <strings.h>

// No engine headers here: their Bool/Byte typedefs collide with UIKit's
// MacTypes. Engine-facing work goes through iOSExternalDisplayResolution.cpp.

namespace {

SDL_Window* s_gameWindow = nullptr;
bool s_trackpadActive = false;
bool s_pendingCheck = false;
Uint64 s_lastDisplayEventTicks = 0;
UIWindow* s_trackpadWindow = nil;   // created in Task 4
Uint64 s_dumpAtTicks = 0;           // diag: scene-tree dump scheduled on the frame loop

// Debounce rapid plug/unplug: act only after the display set is stable.
const Uint64 DISPLAY_SETTLE_MS = 500;

enum class ExternalDisplayPolicy { Wired, Any, Off };

ExternalDisplayPolicy s_policy = ExternalDisplayPolicy::Wired;

// GX_EXTERNAL_DISPLAY = wired (default) | any | off
// Tiny standalone parse of Options.ini in the working directory
// (<bundle>/GameData, set by SDL3Main before window creation); runs once at
// startup, before the engine's own preferences machinery exists.
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
			if (strcasecmp(value, "off") == 0)      policy = ExternalDisplayPolicy::Off;
			else if (strcasecmp(value, "any") == 0) policy = ExternalDisplayPolicy::Any;
			else                                    policy = ExternalDisplayPolicy::Wired;
		}
	}
	fclose(f);
	return policy;
}

UIWindow* gameUIWindow(void)
{
	if (!s_gameWindow) {
		return nil;
	}
	return (__bridge UIWindow*)SDL_GetPointerProperty(
		SDL_GetWindowProperties(s_gameWindow),
		SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
}

// The app is scene-based (SDL3's UIKit backend adopts UIScene, and its app
// delegate accepts any connecting session role), so external-display work goes
// through UIWindowScene: iOS connects a scene for an attached monitor
// automatically, and windows move between displays by reassigning
// `windowScene`. Setting `UIWindow.screen` in a scene-based app is a silent
// no-op — the first on-device test proved it.
bool screenPassesPolicy(UIScreen* screen)
{
	if (s_policy == ExternalDisplayPolicy::Off || screen == nil ||
	    screen == [UIScreen mainScreen]) {
		return false;
	}
	// iOS has no public wired-vs-AirPlay API. Heuristic: AirPlay-to-Apple-TV
	// screens report the .tv interface idiom in their trait collection; wired
	// USB-C/HDMI displays do not. Third-party AirPlay receivers may slip
	// through — GX_EXTERNAL_DISPLAY=off is the escape hatch (=any embraces AirPlay).
	if (s_policy == ExternalDisplayPolicy::Wired &&
	    screen.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomTV) {
		return false;
	}
	return true;
}

UIWindowScene* desiredExternalScene(void)
{
	for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) {
			continue;
		}
		UIWindowScene* windowScene = (UIWindowScene*)scene;
		if (screenPassesPolicy(windowScene.screen)) {
			return windowScene;
		}
	}
	return nil;
}

UIWindowScene* mainWindowScene(void)
{
	for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) {
			continue;
		}
		UIWindowScene* windowScene = (UIWindowScene*)scene;
		if (windowScene.screen == [UIScreen mainScreen]) {
			return windowScene;
		}
	}
	return nil;
}

// True while a policy-eligible external screen is attached but its scene has
// not connected yet — iOS creates the scene asynchronously after the screen
// appears, so the poll must keep waiting instead of dropping the request.
bool externalScreenAwaitingScene(void)
{
	for (UIScreen* screen in [UIScreen screens]) {
		if (screenPassesPolicy(screen)) {
			return true;
		}
	}
	return false;
}

// ---------------------------------------------------------------------------
// Trackpad input synthesis
//
// Touches on the phone-screen trackpad window become relative SDL mouse events
// with `which = 0` (an indirect-pointer ID): SDL3Mouse::translateEvent routes
// those through the virtual-cursor branch built for iPad pointer lock, so the
// trackpad needs no changes to the mouse code itself.
// ---------------------------------------------------------------------------

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
	static bool s_loggedFirstPush = false;
	if (!s_loggedFirstPush) {
		s_loggedFirstPush = true;
		fprintf(stderr, "INFO: GXExternalDisplay first synthetic mouse event (type 0x%x)\n", type);
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

} // anonymous namespace (reopened below; ObjC classes live at file scope)

// Gestures (relative flavor of the absolute translator in SDL3GameEngine.cpp):
//   1 finger move          -> cursor motion (no click)
//   tap                    -> left click (second tap in the link window = double)
//   tap-then-drag          -> left-button drag (band select)
//   stationary long-press  -> right click
//   2 finger drag          -> camera scroll (RMB drag)
//   2 finger pinch         -> zoom (mouse wheel)
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
	static bool s_loggedFirstTouch = false;
	if (!s_loggedFirstTouch) {
		s_loggedFirstTouch = true;
		fprintf(stderr, "INFO: GXExternalDisplay trackpad received first touch\n");
	}
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
			_pinchDist = (float)[self pinchDistance];
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
		// window is a double-click (the cursor did not move between taps,
		// so no radius check is needed).
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

namespace {

// Minimal trackpad surface: near-black, dimmed, with faint usage hints.
void createTrackpadWindow(void)
{
	if (s_trackpadWindow) {
		return;
	}
	UIWindowScene* phoneScene = mainWindowScene();
	if (!phoneScene) {
		fprintf(stderr, "WARNING: GXExternalDisplay no main window scene for trackpad\n");
		return;
	}
	UIScreen* phone = phoneScene.screen;
	s_trackpadWindow = [[UIWindow alloc] initWithWindowScene:phoneScene];
	s_trackpadWindow.frame = phone.bounds;
	UIViewController* vc = [[UIViewController alloc] init];
	GXTrackpadView* pad = [[GXTrackpadView alloc] initWithFrame:phone.bounds];
	pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	// Visibly a trackpad, not a dead screen: very dark (battery on OLED)
	// but clearly "on", with readable usage hints.
	pad.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
	UILabel* hint = [[UILabel alloc] initWithFrame:pad.bounds];
	hint.autoresizingMask = pad.autoresizingMask;
	hint.text = @"TRACKPAD\n\n"
	            @"move finger — cursor · tap — click · tap-then-drag — select\n"
	            @"hold — right click · two fingers — scroll · pinch — zoom";
	hint.numberOfLines = 0;
	hint.textAlignment = NSTextAlignmentCenter;
	hint.font = [UIFont systemFontOfSize:15];
	hint.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
	hint.userInteractionEnabled = NO;
	[pad addSubview:hint];
	vc.view = pad;
	s_trackpadWindow.rootViewController = vc;
	s_trackpadWindow.windowLevel = UIWindowLevelNormal;
	[s_trackpadWindow makeKeyAndVisible];
	// The engine owns the main thread and SDL's event pump runs the runloop in
	// microsecond slices that never reach the CoreAnimation commit observer —
	// a window created mid-game-loop would never composite (black screen) nor
	// register with the render server for touch routing. Commit it NOW.
	[CATransaction flush];
	fprintf(stderr, "INFO: GXExternalDisplay trackpad window shown: key=%d hidden=%d frame=%.0fx%.0f sceneState=%ld\n",
	        (int)s_trackpadWindow.isKeyWindow, (int)s_trackpadWindow.hidden,
	        s_trackpadWindow.frame.size.width, s_trackpadWindow.frame.size.height,
	        (long)phoneScene.activationState);
}

void destroyTrackpadWindow(void)
{
	if (!s_trackpadWindow) {
		return;
	}
	s_trackpadWindow.hidden = YES;
	s_trackpadWindow = nil;
}

// Move the SDL window's UIWindow to `scene`. The CAMetalLayer inside SDL's
// view hierarchy survives the move, so DXVK experiences it as a resize, not a
// surface loss. SDL picks up the new size through its view-controller layout
// callbacks and emits SDL_EVENT_WINDOW_RESIZED.
bool migrateGameWindowToScene(UIWindowScene* scene)
{
	UIWindow* window = gameUIWindow();
	if (!window || !scene) {
		return false;
	}
	window.windowScene = scene;
	window.frame = scene.screen.bounds;
	[window setNeedsLayout];
	[window layoutIfNeeded];
	[CATransaction flush]; // see createTrackpadWindow: the runloop's CA commit never runs
	SDL_SyncWindow(s_gameWindow);
	int lw = 0, lh = 0, pw = 0, ph = 0;
	SDL_GetWindowSize(s_gameWindow, &lw, &lh);
	SDL_GetWindowSizeInPixels(s_gameWindow, &pw, &ph);
	fprintf(stderr, "INFO: GXExternalDisplay migrated window to %s scene, window %dx%d pt, drawable %dx%d px\n",
	        (scene.screen == [UIScreen mainScreen]) ? "main" : "external", lw, lh, pw, ph);
	return true;
}

// Re-derive the game's internal resolution from the current drawable size.
// The engine-facing half lives in iOSExternalDisplayResolution.cpp.
void applyGameResolutionFromWindow(void)
{
	if (!s_gameWindow) {
		return;
	}
	int pw = 0, ph = 0;
	SDL_GetWindowSizeInPixels(s_gameWindow, &pw, &ph);
	if (pw <= 0 || ph <= 0) {
		return;
	}
	GXExternalDisplay_ApplyGameResolution(pw, ph);
}

// SDL's scene delegate keeps ONE global pointer to its black launch-cover
// window. A second scene connection (the external display) overwrites that
// pointer, orphaning the phone scene's cover — it is never hidden, paints the
// phone solid black at level Normal+1, and swallows every touch. Hide any
// such leftover cover on the given scene.
void hideStaleLaunchCovers(UIWindowScene* scene)
{
	if (!scene) {
		return;
	}
	UIWindow* game = gameUIWindow();
	for (UIWindow* w in scene.windows) {
		if (w != game && w != s_trackpadWindow && !w.hidden &&
		    w.windowLevel > UIWindowLevelNormal) {
			fprintf(stderr, "INFO: GXExternalDisplay hiding stale cover window (level %.1f) on %s screen\n",
			        (double)w.windowLevel,
			        (scene.screen == [UIScreen mainScreen]) ? "main" : "external");
			w.hidden = YES;
		}
	}
}

// GeneralsX @diag 12/07/2026 Ground-truth dump of every scene and window —
// the trackpad window claims key+visible yet the phone shows nothing.
void dumpSceneTree(const char* tag)
{
	for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) {
			fprintf(stderr, "DIAG[%s]: scene %s (not a window scene)\n", tag,
			        [NSStringFromClass([scene class]) UTF8String]);
			continue;
		}
		UIWindowScene* ws = (UIWindowScene*)scene;
		fprintf(stderr, "DIAG[%s]: scene %s role=%s state=%ld screen=%.0fx%.0f main=%d\n", tag,
		        [NSStringFromClass([ws class]) UTF8String],
		        [ws.session.role UTF8String],
		        (long)ws.activationState,
		        ws.screen.bounds.size.width, ws.screen.bounds.size.height,
		        (int)(ws.screen == [UIScreen mainScreen]));
		for (UIWindow* w in ws.windows) {
			fprintf(stderr, "DIAG[%s]:   window %s frame=%.0f,%.0f %.0fx%.0f level=%.1f hidden=%d key=%d alpha=%.2f trackpad=%d game=%d\n",
			        tag, [NSStringFromClass([w class]) UTF8String],
			        w.frame.origin.x, w.frame.origin.y,
			        w.frame.size.width, w.frame.size.height,
			        (double)w.windowLevel, (int)w.hidden, (int)w.isKeyWindow,
			        (double)w.alpha, (int)(w == s_trackpadWindow), (int)(w == gameUIWindow()));
		}
	}
}

void enterExternalMode(UIWindowScene* scene)
{
	if (!migrateGameWindowToScene(scene)) {
		fprintf(stderr, "WARNING: GXExternalDisplay migration failed; staying on phone screen\n");
		return;
	}
	s_trackpadActive = true;
	createTrackpadWindow();
	hideStaleLaunchCovers(mainWindowScene());
	hideStaleLaunchCovers(scene);
	applyGameResolutionFromWindow();
	dumpSceneTree("enter");
	s_dumpAtTicks = SDL_GetTicks() + 3000; // dispatch_after starves; use the frame loop
}

void leaveExternalMode(void)
{
	migrateGameWindowToScene(mainWindowScene());
	s_trackpadActive = false;
	destroyTrackpadWindow();
	hideStaleLaunchCovers(mainWindowScene());
	applyGameResolutionFromWindow();
}

} // anonymous namespace

void GXExternalDisplay_Startup(SDL_Window* window)
{
	s_gameWindow = window;
	s_policy = readExternalDisplayPolicy();
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
	if (s_dumpAtTicks != 0 && SDL_GetTicks() >= s_dumpAtTicks) {
		s_dumpAtTicks = 0;
		dumpSceneTree("enter+3s");
	}
	if (!s_pendingCheck || !s_gameWindow) {
		return;
	}
	if (s_lastDisplayEventTicks != 0 &&
	    (SDL_GetTicks() - s_lastDisplayEventTicks) < DISPLAY_SETTLE_MS) {
		return; // let rapid plug/unplug settle
	}

	// Reconcile until done: the request stays pending while the external
	// scene has not connected yet (iOS creates it asynchronously after the
	// screen appears) or while the engine is still initializing — a runtime
	// resolution change needs the full subsystem set.
	UIWindowScene* external = desiredExternalScene();
	if (external && !s_trackpadActive) {
		if (!GXExternalDisplay_EngineReady()) {
			return; // retry next frame
		}
		s_pendingCheck = false;
		enterExternalMode(external);
	} else if (!external && s_trackpadActive) {
		if (!GXExternalDisplay_EngineReady()) {
			return;
		}
		s_pendingCheck = false;
		leaveExternalMode();
	} else if (!external && !s_trackpadActive && externalScreenAwaitingScene()) {
		return; // screen attached, scene still connecting — keep waiting
	} else {
		s_pendingCheck = false;
	}
}

bool GXExternalDisplay_TrackpadActive(void)
{
	return s_trackpadActive;
}

bool GXExternalDisplay_PhoneSceneActive(void)
{
	UIWindowScene* scene = mainWindowScene();
	return scene != nil && scene.activationState == UISceneActivationStateForegroundActive;
}

#endif // TARGET_OS_IPHONE
