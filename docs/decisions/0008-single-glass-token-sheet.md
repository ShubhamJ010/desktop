# ADR-008: One glass token sheet for every new surface

## Status

Accepted

## Date

2026-11-17

## Context

Four new surfaces use a frosted material: the swipe capsule, the swipe history sheet, the Ctrl+Tab card and the PiP call controls. Each was written separately while the features were built. By the time all four existed, each declared its own blur radius, fill alpha, border and shadow, and they read as four levels of transparency.

The browser already has an acrylic recipe for sidebar panels and tab previews. The new surfaces should look like the same material.

A second constraint: the PiP controls float over video, where there is no window color scheme to follow. The video is what the blur reads through.

## Decision

Create one stylesheet, `src/zen/common/styles/zen-ardia-glass.css`, with the tokens and one class.

- `--zen-ardia-glass-filter`: `blur(42px) saturate(180%)`, declared once.
- `--zen-ardia-glass-fill`: `light-dark()` with 0.86 alpha, so the tint follows the scheme and the blur establishes depth.
- The rim is a 1px border, and the shadow token adds a 1px inset highlight. The highlight is what makes the edge read as glass rather than a flat panel.
- `--zen-ardia-glass-fill-over-video`, `-rim-over-video` and `-shadow-over-video` are fixed dark values for the PiP controls.
- `.zen-ardia-glass` applies fill, filter, border and shadow together.
- `prefers-reduced-transparency: reduce` replaces the filter with `none` and the fill with an opaque color, because the platform disables blur anyway and an uncompensated fill looks washed out.

Consumers may redeclare the fill locally when a surface needs to be denser. They must not redeclare the filter, or the recipe splits again. The Ctrl+Tab card is the one exception: it redeclares the fill at 0.97 alpha and sets its own 0.5px rim and `0 12px 28px` shadow, because a popup window has no page behind it.

Chrome includes the sheet through `zen-single-components.css`. The PiP player links it directly, because the player is a separate document that does not load the chrome sheet.

## Alternatives considered

### Keep one recipe per surface

Rejected. That is the state this ADR ends. Three definitions of the same material drift on every change.

### A native `NSVisualEffectView` for chrome surfaces

Rejected. The capsule and sheet are DOM elements in the browser stack. Wrapping them in native views puts a window or layer above page content and complicates input, scrolling and popups.

### A JavaScript theme object

Rejected. The values are CSS-only and need media queries for reduced transparency. JavaScript would add a startup path to a paint-time concern.

### Use the existing design tokens

Not possible yet. The token set has no alpha-composited glass values, and the sheet opts out of the design token lint rule for that reason. Once the set gains glass values, this sheet should read from it.

## Consequences

- One place changes the blur for all four surfaces.
- Reduced transparency behavior is written once. Previously each surface had to remember it.
- Full-window surfaces must not use the class. A 42px backdrop blur over a large area costs GPU time during scroll.
- The sheet is exempt from the design token lint rule. The exemption is recorded in the file with a comment, not in global config.
- The PiP player loads a second stylesheet, one extra request in a document that already loads its own CSS.

See [glass/spec.md](../specs/glass/spec.md).
