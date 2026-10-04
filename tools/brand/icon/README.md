# The app icon's layers

Knit's icon is the stitched "K" from knit-next's launcher icon, in three layers for Icon Composer (ADR 2026-10.5waw):

- `background.svg`: the slate ground, `#454551`, Android's `colorAccent`.
- `stitches.svg`: the K's dashes in light coral, `#F4928E`. The path is `ic_launcher_monochrome.xml`'s, the same one
  `KnitMarkPath` draws in the app.
- `nodes.svg`: the eight coral dots, `#E55E4C`, at the dashes' outer ends and the node's corners. Their centers are
  the centers of the path's round caps.

All three sit on Android's 520-unit grid, so they stack without moving.

## Building `App/AppIcon.icon`

Icon Composer runs only in the Mac's desktop session.

1. Make a new icon. Set its background to the slate, or drop in `background.svg`.
2. Add `stitches.svg` as one layer and `nodes.svg` as a second layer above it. Keep them in separate groups so the
   glass can lift the dots off the dashes.
3. Look at the dark, tinted and clear renderings, and give the dots more contrast in any of them that needs it.
4. Save it as `App/AppIcon.icon`.

Then wire it in:

1. List `AppIcon.icon` among the `KnitApp` target's sources in `App/project.yml`, keeping
   `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`.
2. Run `scripts/mac.sh run scripts/check.sh xcode` and `scripts/check.sh release`. Then check the built app's icon on
   an iOS 18 Simulator, where Xcode substitutes a flat rendering.
3. Delete `App/Assets.xcassets/AppIcon.appiconset` only after both of those pass.
