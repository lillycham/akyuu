# Web UI: a Check tab, and a graph that fits the viewport

Status: built, 2026-10-11, except part C (a look in a real browser). The Compare action does the comparison in the page,
and not with an endpoint, so that an export can do it too. Both changes are in
`web/index.html` (one file, inline script, no build step), with small changes
to the tests.

## Why

1. The check report is the last card group of the Health tab, after the eight
   cards of verify. Nobody finds it, and a clean store shows three cards that
   say "None."
2. The graph is drawn at its natural size. A store of a few hundred memories is
   wider than the window, and a dense one is thousands of pixels wide (the
   961-node window of the routing work was about 7,400 px). There is no
   overview, no zoom and no way to see the shape of the graph.

Both are page changes. The server and the JSON do not change, except for one
optional endpoint in part B.

## Part A: the Check tab

### What the person sees

- A tab **Check** between **GC** and **Health**. It shows a count when there
  are problems: `Check 2`. The count is only for severity `problem`.
- The view has, from the top:
  1. A summary line: `2 problems, 3 suggestions, 1 note`, or the line
     `All clear: nothing needs attention.` with a green pill when there are no
     findings. A line says when the report was made, and that the check reads
     the store and does not change it.
  2. A filter for kind and severity (the same chips as the graph tab).
  3. One card for each finding, problems first: the severity pill, the kind,
     the reason in one sentence, the ids as links (each with its ref name),
     and for a stale link or a fork the memories to read instead.
- A click on an id selects the node, as in the other tabs. A new action
  **Compare** on a pair finding (near duplicate, duplicate body) opens the
  side panel with the two memories side by side and the sentences that only one
  of them has (see part B of this note: it needs the `compare` endpoint).
- The Health tab loses its check cards. It goes back to being verify only.

### How it works

- State: `state.check` (the report), `state.checkFingerprint` (the
  fingerprint of the store at the time of the report).
- `loadCheck()` is the function that exists now (`loadCheck(box, list)`), moved
  to its own view and without the `list` helper argument. It fills
  `#check-list` and the tab badge.
- The badge needs the report before the tab is opened. Fetch it once at start,
  and again only when the fingerprint of `/api/stats` changes. The poll runs
  every 2 seconds, and the check reads every body, so it must not run each time.
  At 3000 memories, measure the cost first (the target is under 0.3 s). If it
  is more, add `check` counts to `/api/stats` with a cache on the server keyed by
  the same fingerprint.
- Static export (`akyuu viz`): the report is `data.check`, already in the
  bundle. An export made before this change has no `check` part: show the note
  "This export has no check report." as now.
- Keyboard and URL: `#check` in the location hash, like the other tabs.

### Changes

| File | Change |
|---|---|
| `web/index.html` | the tab button, `<section id="view-check">`, `loadCheck`, `renderCheck`, the badge, `TABS`, `switchTab`, the hash, remove the call in `loadHealth` |
| `test/check-page.js` | `tabs`/`views` list has `check`; assert the view has the three groups, that Health has no `Check:` text, that the badge text is `Check N` when there are problems |
| `test/WebTests.hs` | none (the endpoint exists). One test that `/api/check` has `findings` and `refs` is already there |

### Order

1. Move the code and make the tab (no new behaviour).
2. Summary line, all-clear state, filters, badge.
3. Compare action (needs B3 below).

## Part B: the graph fits the viewport

### The problem in numbers

`drawGraph` sets `width` and `height` of the SVG to the natural size of the
layout, and the container scrolls. At natural size the text is 12 px, which is
readable but needs a lot of scrolling. A fit scale for a wide graph is 0.15 to
0.2, and text at that size is not readable at all.

So "fit" is two things: a scale, and what the page shows at a small scale.

### The design

1. **A scale, with the natural size kept.** Keep the SVG `viewBox` at the
   natural size, and set the CSS size of the `<svg>` to `natural * scale`. All
   the routing and layout code stays as it is. The scale is page state:
   `state.view = { mode: 'fit' | 'manual', scale }`.
2. **Fit at the start and on a new window.** `fit = min(canvasWidth / width,
   canvasHeight / height)`, clamped to `[MIN_SCALE, 1]`. A graph that is
   smaller than the canvas is not enlarged (scale 1).
3. **A floor for the text.** `MIN_SCALE = 0.4`. Below it the page does not
   shrink further. A dense graph stays larger than the canvas and scrolls, and
   the notice says so and suggests fewer heads or hops. A smaller drawing of a
   dense graph is not useful.
4. **An overview mode under 0.55.** Below this scale the page hides the
   text of the nodes and keeps the boxes, the kind colours, the ref tags and
   the edges. Hover and click still work, and the side panel shows the text. The
   text comes back when the scale goes up. This is what "see the shape" needs.
5. **Zoom and pan.**
   - Buttons in the toolbar: `−`, `+`, `Fit`, `100%`, and a label with the
     percentage.
   - `ctrl` or `cmd` with the wheel zooms around the pointer. A plain wheel
     scrolls, as now.
   - Drag on an empty place of the canvas pans (pointer events), and a click on
     a node still selects it.
   - Keep the scroll position stable when the scale changes: the point under
     the pointer (or the centre) stays under it.
6. **Re-fit on resize** with a `ResizeObserver` on the canvas, only in `fit`
   mode. The side panel opening changes the canvas width, so this matters.
7. **The same for the GC view** (`#gc-canvas`), which uses `drawGraph` too. Its
   canvas is `max-height: 65vh`, so it fits to that.

### Changes

| File | Change |
|---|---|
| `web/index.html` | `state.view`, `fitScale`, `applyScale`, the toolbar buttons, wheel and pointer handlers, `ResizeObserver`, a CSS class `overview` on the `<svg>` that hides `text.label` |
| pure part of the script | `fitScale(natural, canvas, min)` and `anchorScroll(old, new, point)` as pure functions, exported in `pure` for the node check |
| `test/check-page.js` | unit cases for `fitScale` (smaller than canvas, wider, taller, below the floor) and `anchorScroll`; in the fake DOM: the `Fit` button changes the SVG size and the label |
| `test/check-routing.js` | none: the routes do not change |

### What does not change

The layout, the routing, the column order and the highlight. Scaling is a
property of the view, not of the drawing.

## Part C: a real browser

Everything in the plan can be tested in node and a fake DOM, but the look
(text size at 0.55, the drag, the wheel, the overview) is the part that needs
eyes. Plan:

1. Run `akyuu seed --demo` and `akyuu serve`, and look at the page in the
   browser pane (the in-app browser) at a large and a small window.
2. Make a store of a few hundred memories with the seed or a small script, and
   check the fit, the overview and the zoom.
3. Fix what shows, then write down the settings (`MIN_SCALE`, the overview
   threshold) with the reason.

If the browser pane is not available in the session, the person looks and says
what is wrong. The node checks stay as the guard.

## Optional: `GET /api/compare?a=ID&b=ID`

Read-only, like the other endpoints. It returns what `akyuu compare` prints:
the two memories with their refs, the shared share, the sentences that only
one has, and the two drop flags. It uses `Ops.compareMemories`, which exists.
It is needed only for the Compare action of part A. About 40 lines and two
tests, in the style of `/api/memory`. Add it with part A step 3, or leave the
action out.

## Order of work

1. A1: the Check tab (move, no change of behaviour).
2. B1: scale state, `fitScale`, the buttons, and fit at start.
3. B2: wheel and drag, anchor scroll, re-fit on resize.
4. B3: the overview mode and `MIN_SCALE`.
5. A2: the summary, filters, all-clear state and the badge.
6. C: look at it in a browser, and adjust.
7. Optional: the compare endpoint and the Compare action.

Each step is one commit that passes `cabal test` and `smoke-routing.sh`.

## Open questions

- **The floor.** 0.4 and an overview under 0.55 are guesses. Part C decides.
- **Badge cost.** Measure the check at 3000 memories before it runs on a
  fingerprint change. If it is slow, the server caches it.
- **Persist the view?** `localStorage` for the last tab and filters would be
  nice, but the storage can fail, so it must be optional. Leave it out of the
  first version.
