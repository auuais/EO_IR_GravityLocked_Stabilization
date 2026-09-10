# Handoff: the black edge rows in EO panorama

**Date:** 2026-09-10  **Branch:** `codex/ir-ddr-buffer`
**Repo:** `E:\Xylinx\EO_Panorama_V19_M1_IR_DDR` (the same defect exists in
`E:\Xylinx\EO_Panorama_V19_M1`; the two repos' row tables are byte-identical)

This is a request for a cause and a fix. A partial explanation already exists
and **does not match the hardware** — the mismatch is the interesting part, so
it is stated explicitly rather than smoothed over.

---

## 1. What is actually on screen

EO panorama renders a 3840x480 logical canvas that is folded into 1920x960 for
the HD raster: physical row `y` is the LEFT half (x 0..1919) of logical row `y`,
and physical row `480+y` is the RIGHT half (x 1920..3839) of the same logical
row. The remaining 120 physical rows (960..1079) are letterbox.

Measured from captured stills, four different builds and four different scenes
(bright daylight through a dark room):

```
physical black rows : 0, 1, 2, 479, 480, 481, 482, 959
folded to logical   : 0, 1, 2, 479      (each appears twice, once per half)
```

So **three rows at the top of the logical canvas and one at the bottom**, which
on screen reads as a band at the top of each half plus a hairline at the bottom
of each half. It is often described as "2 top and 2 bottom"; the true split is
3 and 1.

This is stable and scene-independent. It is not dark content: those rows
measure `max sample = 0` exactly, which is `EO_V19_BLACK_PIXEL` (`16'h1080`,
Y=0x10 C=0x80, studio black) surviving YUV->RGB, whereas real dark content in
the same frames never goes below ~130.

Reproduce:

```
python - <<'PY'
import cv2
g=cv2.cvtColor(cv2.imread('captures/final_30fps.png'),cv2.COLOR_BGR2GRAY)
rmax=g.max(axis=1)
blk=[y for y in range(960) if rmax[y]<=16]
print(sorted({y if y<480 else y-480 for y in blk}))
PY
```

## 2. The only mechanism that can blacken a whole content row

`src/EoV19StreamingRendererII1.v:531`

```verilog
black[0] <= ((pano_y<CONTENT_Y0)||(pano_y>CONTENT_Y1)||row_black||!cam_present[map_cam_a[2:0]]);
```

* `CONTENT_Y0 = EO_V19_YPAD = 0`, `CONTENT_Y1 = YPAD + PER_CAM_H - 1 = 479`
  (`src/EoV19PanoramaParams.vh:35,42,51`). PANO_H is 480, so **there are no
  padding rows** — the first two terms are never true. Any "border" theory is
  out.
* `!cam_present[...]` blackens one camera's tile, i.e. a vertical band, not a
  row.
* That leaves **`row_black`**, set in exactly one place — the row gate,
  `src/EoV19StreamingRendererII1.v:526`:

```verilog
end else if(gate_overrun_q) begin
    row_black<=1'b1; state<=2'd2;      // emit a bounded black row
end else if(gate_lower_ok_q) begin
    row_black<=1'b0; sy<=pano_y-CONTENT_Y0; state<=2'd2;
end
```

## 3. The gate, and the arithmetic that was blamed

Per rendered row (`src/EoV19StreamingRendererII1.v:136-141,151-166`):

```verilog
gate_max_row  = scale_row(row_max_y0[map_row_index]);
gate_min_row  = scale_row(row_min_y0[map_row_index]);
gate_need_row = gate_max_row + 2;                      // bilinear lead

gate_lower_ok = rows_k >= gate_need_row          (all present cameras)
gate_overrun  = rows_k >  gate_min_row + 62      (any present camera)
```

`rows_k` is `captured_rows` from camera k's `EoV19LineCache` (64 lines deep,
`src/EoV19LineCache.v:10`). `scale_row` is the identity here:
`ENABLE_REDUCED_RASTER = 0` at line 130, so `small_raster` is constant 0.

Two constraints bind the same variable at once. The row can only render if

```
gate_max_row + 2  <=  rows  <=  gate_min_row + 62
```

which is satisfiable only when `span = max - min <= 60`. **The `+2` lead is
spent out of the same 62-row budget**, so checking `span <= 62` in isolation is
wrong — that error has been made before on this problem.

Evaluating the shipped tables (`assets/rowruns/eo_v19_render_row_{max,min}_y0.mem`,
480 entries, identical in both repos):

```
row   0: min=  46 max= 107 span=61   need>=109  guard<=108   INFEASIBLE by 1
row   1: min=  48 max= 109 span=61   need>=111  guard<=110   INFEASIBLE by 1
row   2: min=  50 max= 111 span=61   need>=113  guard<=112   INFEASIBLE by 1
row   3: min=  52 max= 113 span=61   need>=115  guard<=114   INFEASIBLE by 1
row 479: min=1001 max=1051 span=50   need>=1053 guard<=1063  feasible
```

Span 61 is the maximum anywhere in the table and occurs on exactly four rows.
It is the steep top-edge cylindrical warp.

## 4. Where the explanation breaks — the open question

The arithmetic predicts black on logical rows **0,1,2,3**. The hardware shows
black on logical rows **0,1,2,479**. Both ends are wrong:

* **Row 3 is predicted infeasible and renders fine.**
* **Row 479 is comfortably feasible (span 50, 10 rows of slack) and renders
  black.**

Rows 0,1,2 agree, which is why the span-61 story looked complete. It is not.
Any proposed fix that only addresses span-61 rows will, on this evidence, leave
row 479 black and may not even change row 3.

**Do not treat the span-61 analysis as the settled cause.** It is a real,
independently verifiable infeasibility in the table, but something else is also
in play.

### The strongest lead: two different guard constants for one cache

The pass-start gate and the per-row gate disagree about the cache's residency
bound.

`src/EoV19StreamingRendererII1.v:211`

```verilog
wire start_rows_aligned = (dbg_rows_min >= first_need_row) &&
                          (dbg_rows_max <= first_start_row + 11'd63);
```

against the per-row `gate_min_row + 62` above. With
`first_need_row = row_max_y0[0]+2 = 109` and `first_start_row = row_min_y0[0] = 46`,
the start condition is `rows >= 109 && rows <= 109` — every camera must be at
**exactly** row 109 when a pass starts. From there the per-row guard of `+62`
puts row 0 into overrun on its very first evaluation (109 > 46+62 = 108).

A 64-entry ring holds rows `[R-64, R-1]`, so the true bound is `min + 64`, and
both 62 and 63 are conservative — but they are conservative by *different*
amounts, and nothing in the code explains why. Worth establishing which is
intended before changing either.

### Fragility worth knowing about

Five rows have span exactly 60, i.e. `need == guard`, feasible with **zero**
margin. Any map regeneration that widens the warp by one row on those rows adds
five more black rows. The current tables sit right on the edge.

## 5. What to measure next

Triggered ILA capture does not work on this design — the core fires on arm
regardless of the condition (verified by triggering on `frame_edge`, a one-cycle
30 Hz pulse, and catching it in 0 of 8 windows). Use `-trigger_now` only, via
`scripts/capture_v19_loop.tcl`, and see
`docs/MEASURED_20260903_MAPS31.md` for the full write-up.

The renderer already exports what is needed on `v19_dbg_bus` (bit layout in
`scripts/decode_frameset_probe.py` and section 8 of
`docs/HANDOFF_EO_PANORAMA_30FPS_20260903.md`): `dbg_pano_y[42:34]`,
`dbg_rows_min[21:11]`, `dbg_row_target[10:0]`, `dbg_state[44:43]`.

1. **Correlate `pano_y` with `rows_min` and `row_target`** across many
   untriggered windows and find, for the rows that go black, whether
   `gate_overrun` or `gate_lower_ok` is the term that fails. That distinguishes
   "waited too long" from "arrived too early".
2. **Add a sticky per-row black bitmap.** The cheapest decisive instrument: a
   480-bit vector, bit `n` set when `row_black` is asserted for `pano_y == n`,
   readable untriggered. Then the exact black set is known from the RTL's own
   point of view rather than inferred from a photograph. The frame-completion
   counters added in `EoV19StreamingRendererII1` (see
   `scripts/decode_eo_done.py`) are a working model for how to carry this out on
   `probe24` — note there is no spare ILA probe, so it has to share.
3. **Check row 479 specifically.** It is the last content row and the one that
   asserts `last[0]` and therefore `frame_done`. Establish whether it is
   blackened by the gate at all, or by the pass ending underneath it.

## 6. Candidate fixes, with what each costs

Ordered by size, not by preference — the measurement above should pick.

1. **Unify the guard at `+63`** (per-row `gate_min_row + 63`, matching the
   existing start gate). One constant. Makes all four span-61 rows feasible with
   zero margin. Cheapest thing to try, and it directly resolves the
   inconsistency in section 4. Does not obviously explain row 479, so do not
   expect it to fix everything.
2. **Guard at `+64`**, the ring's true bound, giving one row of margin on
   span-61 and two on span-60. Needs confidence that `captured_rows` and the
   cache's write pointer cannot be off by one against each other at a frame
   boundary; that is the reason the constant is conservative today.
3. **Regenerate the maps with the edge span capped at 60.** No RTL change and
   it restores margin on the five span-60 rows too, but it changes panorama
   geometry slightly at the top edge and needs the generator to accept such a
   constraint (`scripts/v19_generate_render_runs.py`).
4. **Deepen the line cache**, `CACHE_LINES` 64 -> 128. Removes the class of
   problem outright. **Almost certainly not viable:** the design is BRAM-bound
   at 82.1% (808/984) and this costs roughly another 320 tiles. Three of eight
   builds in the 2026-09-04 session failed timing on BRAM placement alone. If
   anything, the caches want to get *smaller* — narrowing them to the map's
   actual column window (271..1610) would free ~93 tiles, see
   `docs/HANDOFF_EO_PANORAMA_30FPS_20260903.md` section 18.

## 7. Context a fresh reader needs

* Fixing this is cosmetic-priority. EO panorama now runs at **29.97 fps** with
  correct geometry and no vertical banding (2026-09-04, build
  `20260904_133759_wrwindow_c83e29d`); these 8 physical rows are the last known
  visual defect.
* The black rows are **the correct behaviour of the gate**, not a crash. The
  alternative to emitting black is sampling line-cache rows that have already
  been overwritten, which produces torn content. Any fix must keep that
  guarantee.
* The fold arithmetic is correct and uninvolved. It only makes one blacked
  logical row appear twice on screen.
* `EoV19LineCache` retires a source row after WIDTH accepted pixels and
  explicitly ignores hsync gaps, so replay read-gap timing does not affect
  `captured_rows`.
