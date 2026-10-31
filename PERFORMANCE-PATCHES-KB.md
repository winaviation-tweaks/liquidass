# Performance patches for older iPhones

Patches by **K.B.**, made for iPhone X (A11) and other button-less iPhones that lag with the tweak.

Liquid (Gl)ass is the work of **dylv** and stays under its original CC BY-NC 4.0 license (see LICENSE).
These changes are marked as modifications of the original, as the license requires.

## What changed

| File | Change |
|---|---|
| `Shared/LGSharedSupport.{h,m}` | New `LGDeviceIsLowTier()`: true on iPhone12,x and older (A13 and below). `Performance.Mode` pref: 0 auto, 1 force low, 2 force full. |
| `Shared/LGLiveBackdropView.m` | On low-tier devices the default `Global.Quality` is 0.5 (an explicit user value still wins). Cover sheet glass captures at 0.5 scale instead of 1.0. |
| `Hooks/Clock.x` | `trackMotion` no longer wakes the display link when Clock is off or no clock exists. Default clock tracking is 30fps on low-tier devices unless `Clock.FPS` is set. |
| `Hooks/Banner.x` | Notification/banner host state is cached (refreshed on prefs reload). Material classification is cached per window and superview instead of being redone on every `layoutSubviews`. `UILabel` hooks return immediately when both hosts are off. |
| `Hooks/CoverSheet.x` | Skips `[CATransaction flush]` in the per-frame display link on low-tier devices. |

## Behaviour on newer devices

Devices newer than the A13 are unchanged, except for the two cheap early-exit paths in Clock and Banner.

## Known trade-offs (please test)

* Cover sheet glass on low-tier devices may look slightly softer during swipe-up, and may trail the panel by a frame during interactive pulls (flush removed).
* Clock avoidance of notifications updates at 30fps by default on low-tier devices.
* Set `Performance.Mode` to 2 in `dylv.liquidassprefs.plist` to restore the old behaviour on any device.

## Not yet verified

These patches were written by reading the source and were not compiled or run when written. Build with Theos and test on a real device before releasing.
