# Liquid (Gl)ass
This tweak is incomplete, issues WILL happen.

## Applied to
- folders on the homescreen
- opened folders
- widgets
- underneath app icons
- dock
- lockscreen platter views (notifications & music player)
- quick actions buttons
- app library
- settings app
- clock

## Quick explanation on how this tweak works
- the tweak injects a `LiquidGlassView` into specific springboard surfaces, then feeds that view a backdrop source plus screenspace origin data
- most surfaces are still snapshot / wallpaper based:
  - homescreen, dock, folders, widgets, context menus, App Library, lockscreen platters, etc usually sample from cached wallpaper or cached composite snapshots
  - on iOS 15 and lower it can still decode cpbitmap wallpapers directly
- once a source image is captured, the tweak usually does not rebuild it every frame. the common path is:
  - cache the source image
  - upload it to Metal
  - keep the glass aligned by updating origin / sampling coordinates on display link ticks
  - except for the notification banners which uses a springboard-local live backdrop capture path
- the code splits to these folders:
  - `Runtime/` owns the Metal renderer
  - `Shared/` owns prefs / logging / hook helpers
  - `Hooks/` owns the per-surface injection logic

## The Metal shader
- the renderer uploads the source image as a Metal texture, bakes a blurred variant, then draws the glass in a custom fragment shader
- the normal rounded glass path uses the card bounds / corner radius to estimate edge distance, then uses that edge band to drive:
  - Snell's [law of refraction](https://en.wikipedia.org/wiki/Snell%27s_law)
  - blur/body mix
  - specular highlight / fresnel-ish lift
- there is also a shape mask path used for the lockscreen clock. the shader receives a second texture mask and derives edge behavior from the glyph shape instead of only from a rounded rect
- the blur is separable and baked in two compute passes, then reused until settings or source content actually require a rebake

### contributions to this tweak are welcomed
