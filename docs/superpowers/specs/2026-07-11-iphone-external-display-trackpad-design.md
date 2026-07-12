# iPhone External-Display + Touchscreen-Trackpad Mode

**Date:** 2026-07-11
**Status:** Approved design, pre-implementation
**Scope:** Zero Hour (`z_generals`) iOS target only, matching the existing iOS port.

## Summary

When a wired USB-C external monitor is connected to an iPhone, the game moves
fullscreen onto the monitor and the phone's touchscreen becomes a trackpad
driving the game's virtual cursor. Disconnecting reverses everything mid-game.
No external monitor means no behavior change: the existing absolute
touch-gesture scheme continues to apply.

## Decisions (made with the user)

1. **Activation:** trackpad mode exists *only* while a wired external display
   is connected. The connection itself is the mode switch; no settings UI.
2. **Phone screen content:** a minimal trackpad surface — near-black, dimmed,
   with faint text hints ("move — tap to click — two fingers to scroll").
   Rendered by the iOS shell layer (UIKit), not the game engine.
3. **Connections supported:** wired USB-C only. AirPlay displays are ignored
   (iOS default mirroring applies to them). Because iOS has no clean public
   wired-vs-AirPlay API, detection is heuristic with a config override.
4. **Hot-plug:** connect/disconnect is handled mid-game, both directions.
5. **Architecture:** UIKit platform layer (Approach A below), not pure SDL.

## Approaches considered

- **A (chosen): UIKit platform layer.** Native screen-connect handling;
  migrate the SDL window's underlying `UIWindow` to the external screen so the
  CAMetalLayer survives and DXVK sees only a resize; a plain UIKit window on
  the phone captures touches and shows the trackpad surface.
- **B: Pure SDL.** `SDL_EVENT_DISPLAY_ADDED/REMOVED` plus a second SDL window
  for touch capture. Rejected: SDL3's iOS backend has uncertain multi-window
  and cross-screen window-move support, and SDL display info cannot
  distinguish wired from AirPlay.
- **C: Launch-time detection only.** Rejected: hot-plug is required.

## Components

All new code lives in the existing iOS platform layer of the GeneralsMD tree.

### `iOSExternalDisplay.mm` (new, alongside `GeneralsMD/Code/Main/SDL3Main.cpp`)

ObjC++ display manager:

- Observes screen connect/disconnect notifications, plus a startup check for
  a display that was attached before launch.
- `IsWiredExternalDisplay()` — best-available heuristic, overridable via
  `GX_EXTERNAL_DISPLAY = wired | any | off` in `Options.ini`. `any` also
  accepts AirPlay screens; `off` disables the feature entirely.
- **On connect:** reassign the SDL window's underlying `UIWindow` to the
  external screen (CAMetalLayer intact → DXVK handles it as a resize), then
  create the trackpad `UIWindow` on the phone screen.
- **On disconnect:** move the game window back to the phone screen, destroy
  the trackpad window, restore the absolute touch-gesture path.
- Migrations are serialized on the main thread and debounced against rapid
  plug/unplug.

### Trackpad view (same file)

A `UIView` handling raw `UITouch` events with trackpad semantics, mirroring
the vocabulary of the existing absolute gesture translator in
`SDL3GameEngine.cpp` but producing *relative* motion:

| Gesture | Action |
|---|---|
| one-finger move | cursor motion (no click) |
| tap | left click |
| tap-then-drag | left-button drag (band select) |
| long-press | right click |
| two-finger drag | scroll |
| pinch | zoom |

Linear sensitivity (single constant, scaled into game coordinates via the
existing `scaleMouseDelta`). No acceleration curves, no momentum, no
on-screen buttons in v1.

### Input bridge

The trackpad view synthesizes SDL events — relative `SDL_EVENT_MOUSE_MOTION`
deltas and button events, tagged like the existing `sendSyntheticMouse` — and
pushes them onto SDL's event queue. The in-flight iPad pointer-lock work
(virtual cursor `m_RelativePointerX/Y`, W3D-rendered ANI cursor in
`SDL3Mouse`) consumes them unchanged: SDL3Mouse cannot tell a trackpad finger
from a locked physical pointer. **Zero changes to the virtual-cursor code.**

### Resolution switch

On migration (either direction), re-derive the game resolution from the new
drawable size using the same aspect/height logic as the launch-time
`-xres`/`-yres` injection in `SDL3Main.cpp`, applied through the engine's
existing display-mode-change path (the one the options screen uses).

## Data flow

UIKit touch → trackpad view gesture logic → synthetic SDL relative-motion and
button events → SDL3Mouse virtual cursor (existing) → W3D ANI cursor rendered
in the game window on the monitor (existing).

## Edge cases and error handling

- **Display attached before launch:** startup check performs the same
  migration once SDL window creation completes.
- **Backgrounding while on external display:** the existing lifecycle watcher
  already pauses simulation and rendering; the trackpad window follows the
  same pause and does not synthesize input while paused.
- **Migration or swapchain-resize failure:** log the failure and fall back to
  the phone screen (single-display mode) rather than crash.
- **AirPlay screen connects:** ignored under the default `wired` setting; the
  system mirrors as usual.
- **Rapid plug/unplug:** debounced; only the final stable state is applied.

## Testing and validation

- The iOS Simulator cannot run DXVK (Vulkan feature rejection, see the
  2026-07-11 diary entry), so behavior validation is **on-device**: an
  iPhone 15 or later with a USB-C monitor, checking hot-plug both directions,
  cursor feel and sensitivity, tap/drag-select/right-click/scroll/zoom, and
  resolution correctness on the monitor.
- Build validation: clean `z_generals` iPhoneOS arm64 build and a signed app
  bundle, per the existing project bar.

## Known risks

1. **UIWindow migration with a live Vulkan surface.** Reassigning the SDL
   window's `UIWindow` to another screen while DXVK presents into its
   CAMetalLayer is well-trodden UIKit territory but unvalidated with this
   exact stack. The first implementation task is a spike proving the
   migration (both directions) before building the rest on top of it.
2. **Wired-vs-AirPlay detection is heuristic.** Hence the
   `GX_EXTERNAL_DISPLAY` override as an escape hatch.
3. **Mid-game engine resolution change** is exercised through an existing
   engine path, but that path has not been used on iOS before; validated as
   part of the spike.

## Dependencies

Builds directly on the uncommitted 2026-07-11 iPad pointer-lock work
(relative mouse mode, virtual cursor, W3D ANI cursor rendering in
`SDL3Mouse`). That work should land before or together with this feature.
