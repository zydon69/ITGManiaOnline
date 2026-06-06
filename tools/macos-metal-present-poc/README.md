# macOS Metal Present POC

Small standalone probe for `PLAN-METAL-PRESENT.md` phase 1.

It opens a `CAMetalLayer`, presents simple color frames with
`presentDrawable:afterMinimumDuration:`, and reports presentation timing stats.
This intentionally does not link with ITGmania and does not change the game
runtime.

## Build

```bash
tools/macos-metal-present-poc/build.sh
```

## Run

```bash
tools/macos-metal-present-poc/build/metal_present_poc --hz 120 --seconds 120
```

Useful variants:

```bash
tools/macos-metal-present-poc/build/metal_present_poc --hz 60 --seconds 120
tools/macos-metal-present-poc/build/metal_present_poc --hz 120 --seconds 180 --width 1496 --height 935
tools/macos-metal-present-poc/build/metal_present_poc --hz 120 --seconds 180 --warmup 2
```

## Reading the Result

Look for:

```text
METAL_POC_SUMMARY ...
```

Important fields:

- `avg_present_delta_ms`: average interval between drawable-presented callbacks.
- `max_present_delta_ms`: worst interval.
- `over_1_5x_budget`: frames above 1.5x the target frame budget.
- `over_2x_budget`: clear missed-refresh candidates.
- `warmup`: first seconds ignored by timing stats so window creation and initial
  drawable allocation do not pollute the result.

At 120 Hz, the ideal budget is about 8.333 ms. The POC is promising if
`over_2x_budget=0` and `max_present_delta_ms` remains close to one refresh for
a few minutes.
