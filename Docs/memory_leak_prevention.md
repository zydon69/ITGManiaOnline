# Memory Leak Prevention

This project treats memory leaks as release blockers for the online build.

## Runtime snapshots

The engine logs compact native resource snapshots when the player moves between
screens. This covers both local play and online play.

Important transitions to inspect:

- local: `ScreenSelectMusic -> ScreenStage -> ScreenGameplay -> ScreenEvaluation*`
- online: `ScreenOnlineLobbies -> ScreenSelectMusic -> ScreenPlayerOptions -> ScreenGameplay -> ScreenEvaluation*`
- modal/pushed screens: `screen_push:*`
- popped screens: `screen_pop:*`

Log line format:

```text
ITG Resource: label=<transition> textures=<n> default=<n> volatile=<n> update_queue=<n> refs=<n> max_ref=<n> max_ref_texture=<file>
```

During repeated online cycles, `textures` and `refs` may spike while a screen is
active, but they must return to a stable baseline after leaving gameplay,
evaluation, and song selection. A steadily increasing baseline is a leak
candidate and must be investigated before release.

## Manual soak scenario

Use both flows before tagging a release build.

### Online flow

1. Start the signed macOS app from `/Applications/ITGmania/ITGmania.app`.
2. Log in, create or join an online room.
3. Run at least 10 consecutive songs:
   - select song
   - options
   - lobby
   - gameplay
   - evaluation
   - lobby
4. Quit the app cleanly.
5. Check `Logs/log.txt` for:
   - increasing `ITG Resource` baselines
   - `TEXTUREMAN LEAK`
   - repeated `Mixing underruns`
   - repeated texture reloads for the same song art after leaving screens

### Local flow

1. Start the signed macOS app from `/Applications/ITGmania/ITGmania.app`.
2. Play at least 10 local songs with different banners/backgrounds/cdtitles.
3. Move repeatedly through song select, gameplay, evaluation, and back.
4. Quit cleanly.
5. Check that local `ITG Resource` baselines also return to a stable level.

## Investigation rules

- Prefer explicit unloads on screen teardown for dynamic song assets.
- Do not keep Lua actor references to per-song textures after leaving the
  screen that owns them.
- Keep gameplay/evaluation transition holds bounded by timers.
- If a resource must survive multiple screens, document the owner and lifetime.
- Do not hide leak warnings. Fix ownership or register the risk explicitly.

## Release gate

Before a public online release, run a native leak pass:

```bash
cmake --build Build/release-local -j4
```

For suspicious changes, also run an AddressSanitizer build or Instruments
Allocations/Leaks session on macOS and keep the trace with the release notes.
