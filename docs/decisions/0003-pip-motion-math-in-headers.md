# ADR-003: Keep PiP motion math in plain C++ headers

## Status

Accepted

## Date

2026-11-17

## Context

The PiP card needs corner picking, spring motion, screen fitting, cursor
anchored resizing and width limits. Each of those is arithmetic over rectangles
and vectors. Running the card is the only way to see them, because the code that
used them sat inside `ZenPiPController.mm`, a 1900 line Objective-C file that
needs a full Gecko build and a live video.

That made three things hard:

- Checking a corner cone or a rubber band by reading code.
- Reusing the screen fitting in the zoom path without copying it.
- Changing a constant without recompiling AppKit code that only wraps it.

## Decision

Put the math in header-only C++ namespaces with no AppKit and no Gecko
dependency.

- `ZenPiPThrowMath.h` holds `zen_pip_throw`: points, rects, screens, corner
  selection, screen fitting, spring evaluation and rescue.
- `ZenPiPZoomMath.h` holds `zen_pip_zoom`: scroll factors, width limits, base
  frame resize, pixel snapping and keep-on-screen.
- Both are exported from `src/zen/pip/moz.build` so other code can include them.
- `ZenPiPController.mm` owns state and calls these functions. It does not
  compute frames itself.

The functions are pure. Same input, same output, no globals. `ResizeFromBase`
takes the base frame and anchor fractions as arguments rather than reading
window state.

## Alternatives considered

### Keep the math inline in the controller

Rejected. The controller already manages windows, timers, monitors and focus.
Mixing screen geometry into it is why the corner code had three copies at one
point.

### Move the math into a Swift package

Rejected. The Gecko build compiles `libxul` from C++ and Objective-C++. A Swift
target adds a toolchain dependency and an ABI boundary for pure arithmetic.

### Unit test the Objective-C controller with a mock window

Rejected. It would still need a test harness for `NSWindow` and a running app
for display metrics. Header math can be tested with a plain C++ test.

## Consequences

- The math can be exercised without a browser. No test file exists yet, which is
  a gap, not a design limit.
- Constants live in one place per concern and are readable as a table.
- The controller still owns macOS specifics: live resize, display links and
  window levels. The split is arithmetic versus stateful AppKit.
- Header-only code is compiled into every translation unit that includes it.
  The files are small and the functions inline, so the cost is acceptable.

See [pip/spec.md](../specs/pip/spec.md).
