# Custom mouse cursor (DeX)

Replaces the **default arrow** of the browser with a user-imported cursor while
a mouse is used in Samsung DeX. Off by default; configured under
Settings → Custom cursor.

## What is replaced, and what is not

| Where | Replaced? | How |
|---|---|---|
| Browser UI (tabs, title bar, menus, buttons) | default arrow only | `CustomCursorScope` wraps the app in a `MouseRegion` whose cursor is a `CustomImageMouseCursor`. Regions with their own cursor (hand, I-beam, resize) win over it, as in any Flutter app. |
| Web pages (Gecko) | default arrow only | `PointerInputFrameLayout.onResolvePointerIcon` swaps the page's arrow for `CustomPointerIcons.pageIcon`. Text, hand, resize, grab, `none`, … are returned untouched. |
| Other apps / system cursor | never | Icons are set on this app's views only. |

## Formats

* `.cur` / `.ico` – hotspot read from the file; PNG-in-ICO and DIB (1/4/8/24/32 bpp,
  uncompressed) supported.
* `.ani` – frames, `rate` and `seq ` chunks. Played in the browser UI.
  Web pages show the first frame: Android's `PointerIcon` has no runtime
  animation API.
* `.png` – hotspot chosen in a dialog.

Not supported: OS/2 bitmaps, RLE/BITFIELDS, 16 bpp, `.ani` made of raw bitmaps,
"invert screen" cursors (their inverting pixels become transparent).

## Files

* `domain/cursor_formats.dart` – parsers, PNG encoder (pure Dart, unit tested).
* `domain/custom_cursor_store.dart` – settings and cursor files under
  `<app support>/custom_cursors/`.
* `domain/providers.dart` – controller, DeX tracking, hand-off to native.
* `data/custom_cursor_channel.dart` – `eu.weblibre.gecko/custom_cursor`.
* `presentation/` – settings screen and the `CustomCursorScope`.
* Android: `CustomPointerIcons.kt` (package `flutter_mozilla_components`),
  channel handler in `MainActivity.kt`.

The feature bundles no cursor artwork. Cursors a user imports keep their own
licences; check them before redistributing a build that ships one.
