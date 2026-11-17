# Spec: Ardia glass tokens

Platform: any. The material reads differently on macOS without native vibrancy,
which is expected.

## Purpose

One definition of the frosted surface used by the new chrome: the swipe capsule,
the swipe history sheet, the Ctrl+Tab card and the PiP call controls. Before
this sheet each surface declared its own blur, fill and border, and the three
came out looking like different materials.

## Files

| File | Role |
| --- | --- |
| `src/zen/common/styles/zen-ardia-glass.css` | Token definitions and the `.zen-ardia-glass` class |
| `src/zen/common/styles/zen-single-components.css` | Imports the sheet for browser chrome |
| `src/zen/common/styles/zen-browser-ui.css` | Sheet and capsule styles that consume the tokens |
| `src/toolkit/themes/shared/pictureinpicture/player-css.patch` | Links the sheet in the PiP document |

## Tokens

| Token | Value |
| --- | --- |
| `--zen-ardia-glass-filter` | `blur(42px) saturate(180%)` |
| `--zen-ardia-glass-fill` | `light-dark(rgba(246,246,250,0.86), rgba(38,39,43,0.86))` |
| `--zen-ardia-glass-rim` | 1px, `rgba(0,0,0,0.125)` light, `rgba(255,255,255,0.15)` dark |
| `--zen-ardia-glass-shadow` | 2px 8px drop shadow plus a 1px inset highlight |
| `--zen-ardia-glass-fill-over-video` | `rgba(38,39,43,0.86)` |
| `--zen-ardia-glass-rim-over-video` | 1px `rgba(255,255,255,0.15)` |
| `--zen-ardia-glass-shadow-over-video` | Heavier drop shadow, same inset highlight |

The base fill follows the color scheme. The over-video variants stay dark,
because a PiP control floats over arbitrary video and there is no window scheme
to follow there.

## Usage rules

- Declare the blur once, in this sheet. A consumer that needs a denser surface
  may redeclare `--zen-ardia-glass-fill` locally. It must not redeclare the
  filter, or the surfaces drift apart again.
- Apply the class, or copy the three declarations. Do not invent a fourth
  recipe.
- The PiP player links the sheet directly because it is a separate document and
  does not load `zen-single-components.css`.

## Reduced transparency

Under `prefers-reduced-transparency: reduce` the filter becomes `none` and the
fill becomes opaque. The platform would disable the blur anyway; without the
override the surface would read as a washed-out gray.

| Token | Reduced value |
| --- | --- |
| Filter | `none` |
| Fill | `#f2f2f7` light, `#252629` dark |
| Over-video fill | `#252629` |
| Shadow | 4px 14px, no inset highlight |

## Contrast

Text on the sheet uses the normal chrome colors. The 0.86 alpha fill keeps
contrast above the body text minimum for both schemes at the 42px blur. A
consumer that lowers alpha must recheck its own text.

## Known limits

- `backdrop-filter` on a large surface costs GPU time during scroll. The sheet
  and the card are fixed-size, so the cost stays bounded. Do not use this class
  for full-window surfaces.
- Firefox on Linux without compositor blur renders the fill only, which is still
  legible.
- The sheet opts out of the design token lint rule. Spacing and color tokens do
  not cover alpha-composited glass values yet.

## Verification

1. Open the swipe sheet in light and dark mode. It matches the Ctrl+Tab card.
2. Turn on Reduce Transparency in System Settings. All three surfaces become
   opaque and no blur artifact appears behind the text.
3. Open PiP over a bright video. The call controls stay legible.
