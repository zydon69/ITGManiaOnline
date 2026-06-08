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

- [ ] Title/menu visual parity
- [ ] Song Select left pane, banners, jackets, score panels
- [ ] Song Select preview music/video behavior
- [ ] Gameplay noteskins, receptors, holds, mines, judgments, combo
- [ ] Dense chart gameplay
- [ ] BGA/video chart gameplay
- [ ] Failed chart flow
- [ ] Evaluation screen panes and screenshot animation
- [ ] Render-to-texture visual styles / ActorFrameTexture
- [ ] One 3D/background/model scene
- [ ] Fullscreen and windowed visual parity

## Acceptance Rule

Phase 8 is complete only when:

- the automated smoke remains green;
- the manual checklist has no visible OpenGL vs Metal differences that affect
  gameplay, readability, colors, alpha blending, texture orientation, or render
  target effects;
- any accepted difference is documented here with a reason.
