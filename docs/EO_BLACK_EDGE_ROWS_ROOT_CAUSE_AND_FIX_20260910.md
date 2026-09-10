# EO Black Edge Rows: Root Cause and Proposed Fix

Date: 2026-09-10

Worktree: `E:\Xylinx\EO_Panorama_V19_M1_IR_DDR`

Branch: `codex/ir-ddr-buffer`, examined HEAD `d6d931a`

Scope: diagnosis and proposal only. No production RTL, maps, project settings,
bitstream or board programming changed.

## 1. Conclusion

**The demonstrated EO defect is an incompatible row-window admission contract,
aggravated by an off-by-one replay request. The evidence supports four rejected
TOP logical rows (0..3), not separate top and bottom two-row failures.**

The apparent contradiction in the handoff can be explained without inventing
a second bottom-edge failure:

1. Current RTL and tables cannot admit logical rows 0..3. A focused simulation
   of the actual renderer FSM reproduces all four rejections.
2. A one-line UPWARD displacement of the physical raster places those rejected
   rows at exactly the captured positions: 0..2 and 479..482. It also moves the
   start of the normal bottom padding from 960 to 959.
3. Independently, saved EO-single and IR-panorama frames exhibit the edge
   positions predicted by that same upward displacement. Across all three modes,
   the model has zero mismatched black/nonblack row classifications in the
   clean 2026-09-04 capture set.

This is strong, mutually consistent evidence, but not a hardware trace of the
renderer row numbers. The exact component introducing the one-line displacement
is **not established**: scanout, SDI transport/receiver, or capture handling must
be distinguished with a row-coded test. Do not label it a proven USB-card defect.
Likewise, do not present an isolated gate simulation as a full replay/datapath
or hardware verification.

Recommended fix: retain the 64-line cache and geometry; correct EO's replay
index/count conversion, use a consistent `+63` admission bound, and verify that
the required rows stay protected through the last cache read. Do not remove the
overrun protection, crop the maps, or add a compensating bottom-row offset.

## 2. Source and Build Identity

Starting document:
[HANDOFF_EO_BLACK_EDGE_ROWS_20260910.md](HANDOFF_EO_BLACK_EDGE_ROWS_20260910.md).

The active production instantiation is `EoV19StreamingRendererII1`, not the older
serial renderer: `src/PanoramaBase_DdrBlackFrame.v:2550`.

Relevant code:

| Location | Contract or behavior |
|---|---|
| `src/EoV19StreamingRendererII1.v:136` | Current row's min/max and `max+2` readiness target |
| `src/EoV19StreamingRendererII1.v:171` | Overrun above `min+62` |
| `src/EoV19StreamingRendererII1.v:211` | Pass-start bound uses `min+63` instead |
| `src/EoV19StreamingRendererII1.v:344` | Replay demand interface |
| `src/EoV19StreamingRendererII1.v:457` | Cache-miss blackening in the pixel pipeline |
| `src/EoV19StreamingRendererII1.v:516` | Registered row admission FSM |
| `src/EoV19LineCache.v:76` | `wr_y` advances after WIDTH accepted pixels |
| `src/EoV19LineCache.v:94` | Row tag commits at line completion |
| `src/EoV19LineCache.v:215` | Row metadata synchronized to renderer |
| `src/EoV19DdrDesync.v:836` | Replay stops when emitted row index reaches demand |
| `src/EoV19DdrDesync.v:1192` | Line-end hold/advance decision |
| `src/IrV19StreamingRenderer.v:551` | IR explicitly subtracts one from its count target |

The archive `builds/bit_archive/20260904_133759_wrwindow_c83e29d/manifest.json`
records source commit `c83e29d` and bit SHA-256
`b6bfaeb898f16270195a092b94372aa0ec3bc24697d9c2b4ec2c3c95fa9d96e4`.
`git diff c83e29d HEAD` is empty for the EO II1 renderer, replay, line cache,
RowRun records, and both row-bound tables. This ties the source analysis to the
recorded build source; the board's currently loaded image was not queried today.

EO remains **3840x480 logical, folded into two 1920x480 halves**, with physical
rows 960..1079 black. `EO_V19_YPAD=0`. IR's 1788-pixel fold width is unrelated
and must not be applied to EO.

## 3. Proven Admission Defect

Let `m = row_min_y0[y]`, `M = row_max_y0[y]`, and `C = captured_rows`.
For the replay range involved here, C is the absolute next source-row index
after completed writes, not a count starting at zero after `source_start_row`.
The most recently completed source row is C-1.

Bilinear interpolation needs source rows through M+1. Therefore:

```text
Readiness:        C >= M+2
Current guard:   C <= m+62
Feasibility:    M-m <= 60
```

Actual shipped values:

| Logical y | m | M | Span | Minimum C | Maximum C, current guard | Result |
|---:|---:|---:|---:|---:|---:|---|
| 0 | 46 | 107 | 61 | 109 | 108 | Impossible |
| 1 | 48 | 109 | 61 | 111 | 110 | Impossible |
| 2 | 50 | 111 | 61 | 113 | 112 | Impossible |
| 3 | 52 | 113 | 61 | 115 | 114 | Impossible |
| 4 | 54 | 114 | 60 | 116 | 116 | Zero margin |
| 473 | 990 | 1050 | 60 | 1052 | 1052 | Zero margin |
| 478 | 999 | 1051 | 52 | 1053 | 1061 | Feasible |
| 479 | 1001 | 1051 | 50 | 1053 | 1063 | Feasible |

There are exactly four span-61 rows, 0..3, and five span-60 rows,
4,5,6,7,473. A span of 61 needs **63 actual source lines**, m through M+1
inclusive. It fits in 64 entries; the physical cache capacity is not inherently
insufficient. The conservative admission policy excludes that valid window.

The start gate also disagrees with the row gate: it admits only C=109 for
the first window, but the row-0 guard immediately declares 109>108 an overrun.
No scheduling trick can make rows 2 and 3 simultaneously satisfy the current
steady-state lower and upper bounds.

### Isolated RTL test

XSim 2025.2 executed 960 cases against the actual II1 renderer and shipped tables.
All six row counters were forced to equal values; each case entered the actual
row-wait FSM and allowed its registered gate/settle latency to expire.

| Forced counter at admission | Rows rejected by actual FSM | Bottom 478/479 |
|---|---|---|
| C=M+2 | 0,1,2,3 | Both accepted |
| C=M+3 | 0,1,2,3,4,5,6,7,473 | Both accepted |

The second case represents a fully settled one-row overfetch; it does NOT mean
all nine rows necessarily fail on hardware. Admission can occur before that
extra row finishes. This timing dependence is itself undesirable.

The test also ran a negative control requiring no rejected content rows. It
failed with `$fatal` at logical row 0 as intended. XSim's launcher returned zero
even for that fatal, so log content, not process status alone, was checked.

## 4. Additional Proven Defect: EO Requests One Row Too Many

EO assigns `source_need_row = gate_need_row = M+2`.
Replay's `dbg_row` instead denotes the source row being emitted, and its
line-end state holds after `dbg_row >= source_need_row`.

```text
Current EO request:       last emitted row M+2 -> settled C=M+3
Required window:          last emitted row M+1 -> settled C=M+2
Correct request index:    gate_need_row - 1
```

IR already makes this exact conversion and documents why. Copying that interface
convention is appropriate; copying IR geometry or its cache-depth constants is not.

Consequences of the EO mismatch:

- One unnecessary source row is emitted per newly raised demand, subject to
  demand changes before the replay reaches its hold point.
- Span-60 rows become timing-sensitive under the existing `+62` guard.
- The initial C=109 start window is transient because replay may continue to
  C=110 instead of holding at 109.
- Changing only the guard to `+63` still permits settled C=M+3 to reject the
  span-61 rows. Changing only the replay request still leaves their bounds
  contradictory. **The two corrections belong together.**

## 5. Resolving the Apparent Bottom-Row Failure

I remeasured the saved, full-resolution 1920x1080 PNGs in
`captures/optical_20260904_150051`. A row was classified black only when the
maximum over every pixel and all three BGR channels was <=8.
Repeating at thresholds 0, 4, and 16 produced identical masks for all three files.

| Mode/file | Measured entirely black physical rows |
|---|---|
| `eo_single.png` | 1079 |
| `ir_panorama.png` | 959..1079 |
| `eo_panorama.png` | 0..2, 479..482, 959..1079 |

The earlier clean set `captures/optical_20260903_125017` has the same three
patterns. Not every historical capture is a clean baseline: the 02:34 Sep-04
EO panorama has extensive extra black regions, and the 17:47 Sep-03 file labeled
EO single has the panorama black-row pattern. Neither is used to assert healthy
operation or mode identity here.

For the gate-predicted four top logical rows, the expected physical mask is:

```text
Before displacement:  0..3, 480..483, 960..1079
One row upward:       0..2, 479..482, 959..1078
Black final row:      1079
Combined prediction:  0..2, 479..482, 959..1079
```

Equivalently, `observed[y] = intended[y+1]` for y<1079, with the final row black.
This predicts ALL 1080 row classifications correctly in each of the three modes:

- EO single: full 1080-row image becomes 1079 image rows plus one bottom black row.
- IR panorama: normal padding beginning at 960 appears beginning at 959.
- EO panorama: the four top-row gate failures produce the measured bands exactly.

In particular, captured row 479 can be the first black row of the NEXT physical
half, shifted upward; captured row 959 can be the first padding row, shifted
upward. Neither proves logical row 479 was rejected by the renderer.

The handoff's assumed `{0,1,478,479}` plus the opposite displacement direction
can also fit the EO panorama band positions alone. The independent modes and
the actual gate simulation favor `{0,1,2,3}` plus an upward displacement.
The reported visual observation is preserved; its attribution to numerical
renderer rows is what needs correction or direct tagged-row evidence.

`V19_CONTENT_FIRST_ROW=0` only describes renderer geometry. It cannot establish
the absence, presence, direction, or hardware location of a downstream offset.
`scripts/grab_still.py` performs no explicit crop/shift at its default scale.
The examined scanout uses a 960-row EO window and has no explicit two-row top
or bottom crop (`PanoramaBase_DdrBlackFrame.v:4309` onward). Neither observation
alone localizes the displacement. Do not compensate by shifting EO maps.

## 6. Corrections to Other Handoff Claims

**`row_black` is not the only blackening mechanism.** The pipeline also asserts
`black[7]` for a cache miss, including a B-camera miss during blending. Source
pixels can themselves be black. A `row_black` bitmap alone cannot distinguish
all black-image causes. The offset explanation above removes the need to assume
a second bottom bug, but a full regression must still cover cache misses.

**`min+64` is not unconditionally safe.** At C, the writer may already be
overwriting the slot formerly holding C-64. The cache changes that slot's tag
only when the new row completes, not when overwrite begins. Consequently an
old tag may still hit while its data is partly overwritten. A held, fully idle
64-row window differs from a concurrently written ring. Do not relax the guard
to +64 without an explicit residency/ownership proof.

**This is not evidence of an asynchronous camera-clock crossing fault.** In the
DDR path inspected here, replay exports `replay_clk=clk`; replay and the renderer
use `c0_ddr4_ui_clk`. The old metadata synchronizer stages still introduce latency,
but the incompatible inequalities and inclusive-index mismatch exist even with
all six counters forced equal in one clock domain.

**The existing verifier has a false-negative for admission failure.** Running
`python scripts/v19_verify_row_window.py` returned PASS: zero reconstructed y0
values exceeded either table bound, with maximum span 61. Its admission check
uses span<=62, ignoring the +2 readiness lead. The correct current-guard check
is `max+2 <= min+62`. Its comments about bypassed black-on-miss are also stale.

## 7. Recommended EO-Only Fix

### A. Correct and unify the window contract

Preserve the current maps and 64 banks per camera. Define shared constants for
cache depth, bilinear lead and the protected window bound, rather than unrelated
62/63 literals. For the proposed DDR-paced implementation:

```verilog
// Proposal, not applied to production RTL in this investigation.
required_count = row_max_y0 + 2;
last_source_row_to_emit = required_count - 1;
oldest_row_guard_limit = row_min_y0 + 63;
```

Apply the index conversion to BOTH startup and subsequent EO demand. Use the
same +63 upper bound for pass-start and per-row admission; remove or update the
unused `gate_upper_ok` expression so it cannot preserve a conflicting contract.
Keep missing-camera behavior and the registered gate-settle timing intact.

With replay stopped exactly at the requested row:

```text
C = M+2
C <= m+63  iff  M-m <= 61
```

Every current table row satisfies this. The span-61 window holds 63 completed
source rows, leaving one physical slot unused. This is a capacity/admission
proof, not yet proof of safe timing throughout a pixel pipeline transaction.

### B. Protect the window until reads finish

Prove, and explicitly enforce if necessary, that replay cannot overwrite a
required slot while that output row has cache reads in flight. Latch the row's
demand/window; let replay hold after M+1, and release that protection only after
the last cache read belonging to the output row has completed. The boundary is
not merely the last token issued, and a stalled pipeline must not release it.

Do not create a deadlock by stopping replay BEFORE it fills the row's demand.
If the existing sequential replay timing already supplies sufficient read-drain
margin, establish that in an integrated test before adding handshake state.
Retain per-token tag checks. Tag invalidation at overwrite start is useful
defense-in-depth, but cannot substitute for preventing premature eviction.

### C. Fix verification before spending a hardware build

Update the row-window verifier to check all of the following independently:

1. Reconstructed, quantized y0 bounds for every issued map token.
2. Bilinear y1 completion and guard feasibility, including the +2 term.
3. Replay's inclusive row-index convention and exact stop point.
4. Residency from row admission through the last cache read, under backpressure.

Add positive tests for all 480 rows and negative controls for the old +62 guard,
the old unconverted replay request, and an attempted overwrite of a protected
row. Test long output stalls, delayed DDR responses, missing cameras, and a
mode/reset at row boundaries. Assert no cache-miss blackening for present-camera
pixels and exactly 3840*480 accepted pixels per successful EO frame.

The smallest sensible implementation starts with A and verifies B. There is no
reason to regenerate calibration maps or double cache depth for this map span.
Returning to two lines is not a drop-in fix: this output-row traversal needs up
to 63 source rows resident; a two-line implementation needs a different traversal
and destination accumulation scheme.

## 8. Hardware Acceptance and Offset Localization

Once implementation is separately authorized, retain 29.97-fps performance and
unchanged EO 1920x480-per-fold geometry. Archive every bit with its matching LTX.

Collect separate, frame-latched row diagnostics for admission rejection and
cache-miss blackening. Pipeline a row ID with each token; the live `pano_y` can
already name the next row when a pixel exits. Associate diagnostics with a
completed/published frame ID and retain them across idle/start_copy deassertion.
Mask intentionally absent-camera pixels out of the failure counts.

Use a known nonblack row-coded pattern to compare these boundaries:

1. Renderer accepted-pixel stream: logical row ID and first/last pixels.
2. Folded framebuffer addresses/data at physical rows 0,479,480,959.
3. Scanout active-line number versus transmitted row code and SAV/EAV.
4. Raw USB capture row codes, without UI scaling or automatic alignment.

This identifies where the one-line displacement occurs. Until then, successful
removal of EO gate blackening could still leave captured padding starting at 959,
as it currently does in IR. Report that transport/scanout geometry issue separately
instead of treating it as another failed panorama cache fix.

Acceptance requires zero unintended EO row rejects and cache misses, no torn
content, correct first/last logical rows, unchanged other modes, and a documented
row-coordinate correspondence from renderer through the captured image.

## 9. Reproduction Artifacts and Limits

Local diagnostic-only test source:
`.cache/eo_black_rows_20260910/tb_EoBlackRows.sv`.
Logs: `gate_cases.log` and `negative_control.log` in the same directory.
These are local scratch artifacts, not production sources or a committed test suite.

Run from that directory (two levels below the worktree root so ROM paths resolve):

```powershell
$v = 'C:\AMDDesignTools\2025.2\Vivado\bin'
& "$v\xvlog.bat" -sv -i ../../src ../../src/EoV19StreamingRendererII1.v ../../src/EoV19LineCache.v ../../src/EoV19RunRom.v tb_EoBlackRows.sv
& "$v\xelab.bat" -debug typical -O0 --timescale 1ns/1ps -L xpm -L unisims_ver -L unimacro_ver -L secureip tb_EoBlackRows -s eo_black_rows
& "$v\xsim.bat" eo_black_rows -R -log gate_cases.log
& "$v\xsim.bat" eo_black_rows -R -testplusarg require_no_black -log negative_control.log
```

This bench tests admission decisions with forced counters, not real replay,
cache data, full-frame output, proposed RTL changes, or pipeline backpressure.
It decisively disproves a current-gate-only explanation in which rows 2/3 pass
but rows 478/479 fail under correctly delivered demands.

No fresh grabber acquisition, ILA capture, synthesis, implementation, or programming
was performed in this investigation. The proposed fix has not been hardware-tested.

---

## 10. Implemented and hardware-tested, 2026-09-10

Section 7A applied as recommended. Build
`builds/bit_archive/20260910_172159_rowwindow_fix_b94c688/`, `Explore`,
WNS +0.036 / WHS +0.010 / WPWS +0.002, zero failing endpoints.

### The black rows are gone

```
black row runs, EO panorama : (959, 1079)   total 121
rows 0,1,2,3   max = 255,255,255,255        (were 0,0,0 + lit)
rows 478..483  max = 181,240,255,255,245,225
```

The only remaining run is the 120-row letterbox starting one row early at 959 —
**exactly the upward displacement predicted in section 5**. EO panorama's black
row count is now 121, identical to IR panorama's 121 in the same sweep, and IR
never had the content-row defect. That is a clean independent confirmation both
of the fix and of the displacement model: what is left in EO is only what IR
already had.

### Both corrections were necessary

Checked against the shipped tables before building, settled `captured_rows`
against the guard:

```
guard m+62, replay overfetch (C=M+3)   ->  9 rows rejected (0..7, 473)
guard m+62, corrected demand (C=M+2)   ->  4 rows rejected (0..3)
guard m+63, still overfetching         ->  4 rows rejected (0..3)
guard m+63 + corrected demand          ->  0 rows rejected
```

### Frame rate: unchanged

| mode | distinct frames/s | black frames | black rows |
|---|---:|---|---:|
| EO panorama | 29.96 (29.97 electrical) | 0/479 | 121 |
| IR panorama | 29.87 | 0/475 | 121 |
| IR single | 29.86 | 0/474 | 568 |
| EO single | 29.82 | 0/473 | 1 |

Ownership invariant still holds (`copy_active && !lease` 0.0%). Run lengths
`2x297` with 3 singles — a clean 30 at a 60 fps grab.

### Efficiency: a real cost, and it is not free

Against the immediately preceding 29.97 fps build:

| | wrwindow (8 black rows) | rowfix (0 black rows) |
|---|---:|---:|
| `copy_active` | 42.9% | 85.7% |
| pass duration | 14.3 ms | **28.6 ms** |
| DDR reads | 16.4 Mbeat/s | **23.1 Mbeat/s** |
| DDR writes | 14.7 Mbeat/s | 17.4 Mbeat/s |

The pass doubled and read traffic rose 41%. Frame rate is unaffected because
the loop is descriptor-supply limited at 30/s, not pass limited — but the
margin inside a 33.3 ms display frame fell from ~19 ms to **4.7 ms**, which is
the same thin margin that produced 47 stalls per 10 s earlier in this project.
It is not dropping frames today; it has much less room before it would.

**This is unexplained and should be treated as open.** Asking the replay for
one row FEWER should reduce read traffic, not raise it. Candidates worth
checking, in order: whether the tighter `hold_for_demand` makes the replay
stall and restart once per output row (paying request latency 480 times per
pass instead of running ahead); whether admitting the four previously-rejected
rows changes the demand sequence at pass start; and whether `source_start_row`
interacts with the new first-row demand. The fix should be kept either way —
correct output at 30 fps beats 8 black rows at 30 fps — but the margin should
be recovered before anything else is added to this pipeline.
