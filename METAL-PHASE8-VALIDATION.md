# Metal Phase 8 Validation

This file tracks the OpenGL vs Metal visual parity gate for the native Metal
renderer.

## Automated A/B Smoke

Tool:

```bash
tools/metal-renderer-validation/validate_metal_ab.py --wait 8
```

Latest run:

- Output: `MetalValidation/20260608-064538`
- OpenGL launch: passed
- Metal launch: passed
- OpenGL renderer marker: found
- Metal renderer marker: found
- `RageDisplay_Metal initialized`: found
- Targeted bad log lines: 0 for OpenGL, 0 for Metal
- Screenshots captured for both renderers

The pixel diff is diagnostic only for now. The title/menu scene is animated and
the two launches are not frame-synchronized, so large pixel deltas do not by
themselves indicate a renderer mismatch. Visual parity must still be judged on
the checklist below.

## Manual Checklist

- [x] Title/menu visual parity
- [x] Song Select left pane, banners, jackets, score panels
- [x] Song Select preview music/video behavior
- [x] Gameplay noteskins, receptors, holds, mines, judgments, combo
- [x] Dense chart gameplay
- [x] BGA/video chart gameplay
- [x] Failed chart flow
- [x] Evaluation screen panes and screenshot animation
- [x] Render-to-texture visual styles / ActorFrameTexture
- [x] One 3D/background/model scene
- [x] Fullscreen and windowed visual parity

Validated by user playtesting on 2026-06-08. The latest reviewed Metal log shows
a complete session through gameplay, failed evaluation, profile save, title menu,
and exit with:

- `RageDisplay_Metal initialized`;
- `Current renderer: metal`;
- no targeted Metal shader/pipeline errors;
- no crash markers;
- no `Mixing underruns` marker in the reviewed session.

The `failed` log entries in this run are gameplay result/state markers, not
renderer failures.

## Phase 8 Result

Phase 8 is accepted for the current Apple Silicon test machine.

Remaining validation belongs to later gates:

- Phase 9 performance and pacing comparison against OpenGL;
- multi-machine validation, especially another Apple Silicon Mac and ideally an
  Intel Mac before considering Metal as a default.

## Acceptance Rule

Phase 8 is complete only when:

- the automated smoke remains green;
- the manual checklist has no visible OpenGL vs Metal differences that affect
  gameplay, readability, colors, alpha blending, texture orientation, or render
  target effects;
- any accepted difference is documented here with a reason.
