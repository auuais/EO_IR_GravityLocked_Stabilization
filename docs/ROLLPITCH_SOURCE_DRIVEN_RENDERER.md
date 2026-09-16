# Live per-camera roll/pitch: the source-driven renderer

**Repo:** `EO_Panorama_V19_RollPitch` (branched from `EO_Panorama_V19_M1`
fork `f9ff372`, the 29.97 fps EO panorama build).
**Goal:** apply the per-camera Pitch/Roll offsets that the UI maintenance page
and the firmware already send, live, up to **±10°** on each axis, matching the
C++ reference model (`MAX_CAM_ANGLE_CENTI 1000`).

## 1. Why the renderer has to change

The M1 renderer is *output-driven*: it walks the 3840x480 panorama in raster
order and samples source rows from a 64-line cache per camera. A row of output
needs every source row its map touches to be in that cache at once. That span
is 63 lines at 0°, and grows by ~12 lines per degree of roll:

| roll | source span (M1 cache must hold) |
|---|---|
| 0°  | 63 |
| 2°  | 88 |
| 5°  | 133 |
| 10° | 235 |

The C++ V19 model is *source-driven*: for each source row y0 it holds only a
2-line cache, writes every output pixel that samples y0 into a RowWindow of
partly built output rows, and emits an output row once its last source row has
passed. There the cost of roll is the number of *output* rows open at once,
and an output row is ~1/3 of the bits of a six-camera source line:

Measured on the shipped EO segment ROM (`model/envelope.py`):

| case | open-row window | max queue | visits/frame |
|---|---|---|---|
| zero | 30 | 396 | 197k |
| roll ±10 all | 118 | 725 | 669k |
| pitch ±10 alternating cameras | 123 | – | 184k |
| roll ±10 + pitch ±10, alternating | 214 | 885 | 641k |
| pitch -10 all | 30 | 1679 | 180k |

## 2. Offset math (matches the C++ model)

With no IMU input `convert_rpy_sensor_to_cam_centi` returns the offsets
unchanged, so per camera k:

```
y_shift_k = round_half_away(PITCH_TR_Q16 * pitch_cd / (100 * 65536))   rows
(c_k, s_k) = Q15 of cos/sin(-roll_cd)        (scale 32768: 0° is exact identity)
```

The C++ LUT uses scale 32767; this design uses 32768 so zero offset reproduces
the M1 renderer bit-exactly. The difference is 3e-5 relative.

The RTL segment ROM stores, per (output row sy, camera, 64-px segment), an
affine chord `ax0, ay0` (Q16) and `dax, day` (Q.5). A shift plus rotation of an
affine segment is affine, so each segment transforms exactly once:

```
dx = ax0 - CX              dy = ay0 + (y_shift<<16) - CY       CX=960<<16 CY=540<<16
A_x = ((c*dx + s*dy) >>> 15) + CX
A_y = ((-s*dx + c*dy) >>> 15) + CY
D_x = (c*(dax<<11) + s*(day<<11)) >>> 15
D_y = (-s*(dax<<11) + c*(day<<11)) >>> 15
pixel i: ax = A_x + i*D_x, ay = A_y + i*D_y
```

At zero offset `A = (ax0, ay0)` and `D = (dax<<11, day<<11)`, exactly the M1
renderer's `affine_q16`.

**Validity (C++ semantics):** a pixel is valid when `0 <= ax <= 1918<<16` and
`0 <= ay <= 1078<<16`. Invalid pixels are written as `EO_V19_BLACK_PIXEL`.
At zero offset no pixel is invalid, so this changes nothing there.

**Sampling (unchanged from M1):** `x = qx_phase(ax, parity(pano_x))`,
rows `ay>>16` and `+1`, vertical interpolation with `ay[15:0]`, luma and the
per-pixel chroma byte interpolated separately.

## 3. Architecture

```
I2C regfile ──► OffsetSync (stable-for-N, clamp ±1000) ──► TableBuilder (on change)
                                                              │ PARAMS (URAM, sorted by start row)
                                                              │ BUCKET_END[y], ROW_READY[sy]
                                                              │ Ylo/Yhi, fetch window
DDR replay (beat mode) ──► LineRing: 3 rows x 6 cams, 120 beats x 256 b
                               │
             Walker ◄── QUEUE (URAM FIFO of partly walked segments)
               │ pixel tokens {cam, sy, lx, ax, ay}
             Sampler: line read ► mux ► interp ► RowWindow RMW write
                                                     │ URAM, 256 rows x 3925 px, 4 px/word
             Emitter: row sy_out when ROW_READY[sy_out] <= y0_done ► blend seams ► px stream
```

### 3.1 Tables (rebuilt when offsets change, between passes)

Per segment, walking in the direction of increasing source y (`dir = D_y>=0`):

* `sched_y(pixel) = clamp(floor(ay), 0, 1078)` — monotone along the walk.
* `start_y = sched_y(first pixel)`, `end_y = sched_y(last pixel)`.
* `Ylo = min start_y`, `Yhi = max end_y`; both then clamp every start/end.
* `ROW_READY[sy] = max end_y` over the row's 66 segments.
* PARAMS are written in `start_y` order (counting sort, two passes over the
  31680 segments), `BUCKET_END[y]` = one past the last PARAMS index with
  `start_y <= y`.
* Fetch/write windows: min/max source column and row over segment endpoints.

Entry layout (141 bits, stored in 144 = 2 URAM widths):
`{sy 9, cam 3, seg 4, i 6, dir 1, last_i 6, ax 32, ay 32, step_x 24, step_y 24}`
where `step = dir ? D : -D` and `i` starts at `dir ? 0 : last_i`.

### 3.2 Per pass

For `y0 = Ylo .. Yhi`:

1. Replay demand `need_row = y0+2`; the ring holds rows `y0`, `y0+1` for reads
   while row `y0+2` is written into the third slot (`slot = row mod 3`).
2. Walker drains the `n` queue entries present at the start of y0, then the
   new PARAMS entries up to `BUCKET_END[y0]`. For each segment it emits pixels
   while `take = (y0 == Yhi) || ay < 0 || (ay>>16) <= y0`; a segment that is
   not exhausted is pushed back with its walked state. Order between segments
   is irrelevant: every pixel has its own RowWindow address.
3. After the walker is idle the pipeline is allowed to drain, `y0_done = y0`,
   and y0 advances once rows `y0+1` and `y0+2` are complete.

Emission runs concurrently: row `sy_out` is emitted when
`ROW_READY[sy_out] <= y0_done` (or all y0 are done). Each pixel of an emitted
row was written in this pass, because every pixel's `sched_y <= end_y <=
ROW_READY`. So the RowWindow never needs clearing, even after an aborted pass.

### 3.3 RowWindow aliasing

`slot = sy mod 256`. The walker may not issue a pixel for
`sy >= sy_out + 255` (sy_out is the row being emitted). If emission can still
progress the walker stalls; if it cannot (the geometry genuinely exceeds 256
open rows) the pixel is dropped, the row is marked bad and emitted black, and
a sticky overflow flag is raised. No measured 10° case comes within 40 rows of
this.

### 3.4 Seam blending at emission

The RowWindow stores one strip per camera (cam0 650 px, cam1..5 655 px, 3925
in total), so seam pixels never collide. The emitter reads strips in order and
delays the last 17 pixels of strip k to blend with the first 17 of strip k+1,
using the M1 formula and alpha tables. `cam_present` handling is M1's: absent
camera A → black; both present → blend; B absent → A.

## 4. One core for EO and IR panorama

EO panorama (mode 0x15) and IR panorama (mode 0x14) never run together, so
`RpRenderer` serves both and rebuilds its tables when the mode flips (~4 ms).
What differs is selected at run time (`model/rpcore.py` is the reference):

| | EO | IR |
|---|---|---|
| source | 1920x1080, 16-bit {Y,C} | 640x512, 8-bit luma |
| segment ROM | 144-bit, 11 segs/row, deltas Q.5 | 96-bit, 10 segs/row, Q12.4 |
| strips | 650, 655 x5 | 616, 621, **640**, 621, 621, 621 |
| output row | 3840 | 3576 (fold formatter pads) |
| sampling | x phase-locked to pano_x parity, interp8 on Y and C | x = floor, truncating vlerp on Y, C = 0x80 |
| seams | 17/17, alpha j | 29/29, except cam2/cam3: 48 cam2 px (lx 592..639, last repeated), 90 cam3 px, `cam23_fold_alpha_pos` |
| absent camera in a seam | A absent -> black | A absent -> B |
| pitch_to_translation_factor | -9.80 | -8.72 |
| RowWindow | 256 rows x 1024 words, 4 x 16-bit px | 512 rows x 512 words, 8 x 8-bit px |
| replay beat | 16 px x 16 bit, 4 ring words | 32 px x 8 bit, 8 ring words |

IR camera 2 is 640 wide because the M1 IR renderer extrapolates its last
RowRun segment to source column 639 for the fold-straddling seam.

IR's 512-row RowWindow never aliases (480 output rows); its alternating
+-10 deg case needs 288 rows, which would not fit 256.

## 5. Memory budget (xcku15p: 984 BRAM tiles, 128 URAM)

Synthesis of the EO-only build (commit ab33bb9):

| | M1 (routed) | roll/pitch |
|---|---|---|
| Block RAM tiles | 880.5 (89.5%) | 441 (44.8%) |
| URAM | 10 | 92 (RowWindow 64, PARAMS 16, queue 2) |
| DSP | 26 | 29 |

The shared core additionally removes the six IR 32-line caches.

## 6. Interfaces that change outside the renderer

* **I2C regfile** already stores the bank the firmware pushes
  (`fpga_push_bank`): EO base 0x20, IR base 0x50; per camera i16 LE pitch at
  `base+0x0C+2i`, roll at `base+0x18+2i`. The old
  `eo_cyl_h_fov_q16`-style decode of the same addresses was dead and is
  removed. The bytes are exported to the panorama and synchronised there
  (stable for 2^20 ui_clk cycles before being applied: the firmware writes
  byte by byte).
* **EoV19DdrReplay** gains `BEAT_OUT` mode (beats go straight into the line
  ring, no 16-cycle serial shift per beat) and a runtime fetch window.
* **EoV19DdrCamWriter** row/beat window becomes runtime-settable so zero offset
  keeps today's write bandwidth (the 30 fps constraint was write bandwidth).

## 7. Verification

| check | result |
|---|---|
| `model/golden.py --selftest`: offset renderer at 0 vs M1 EO transcription | 0 / 1,843,200 px differ |
| `model/rpcore.py --selftest`: generic EO vs golden.py; IR at 0 vs M1 IR transcription (all present, cam2 absent, cam3 absent) | 0 differ |
| walker exactly-once / right row / written before emit: EO and IR, zero, 10 deg, mixed, alternating +-10 | pass |
| `tb_RpTables`: every PARAMS entry, bucket and row-ready value, EO and IR, 4 offset cases, alternating sensors | 0 mismatches |
| `tb_EoV19DdrReplayBeatOut`: real replay in BEAT_OUT mode into the line ring, late-ack arbiter, aborts | pass |
| `tb_EoV19DdrReplayArbiterAck`: pixel-shift replay unchanged | pass |
| `tb_EoV19RpRenderer` (EO-only core): zero, zero again, mixed, 10 deg, alternating +-10, camera absent | bit-exact, 13-17 ms per pass |
| `tb_RpRenderer` (shared core): EO and IR cases | see commit log |

Bench outputs are compared with `python model/compare_rp_tb.py`.

## 8. Firmware and UI

The per-camera offsets already travel UI -> MCU (config bank apply) -> FPGA
(`fpga_push_bank`, byte by byte with read-back verify).  Two things had to
change because the FPGA now acts on them:

* **Range**: FW `cfg_bank_values_valid` and the UI dialog accepted +-500 cd
  (5 deg); both now accept +-1000 cd (10 deg), the FPGA's clamp.
* **Default EO pitch**: FW `cfg_set_bank_defaults` and the UI's local defaults
  had EO pitch `{-500, 500, -500, 500, -500, 500}`, a placeholder the FPGA used
  to ignore.  With this renderer it would shift alternate cameras by +-49
  rows.  Both now default to 0, as in `parameters_unified.ini [eo_offset]`.
  **A board whose MCU flash already holds the old pattern keeps it** -- check
  the Maintenance page and zero the EO pitch offsets before judging the image.
* The Maintenance status page showed pitch/roll as uint16 (-500 read as
  65036); it now shows signed centi-degrees and degrees.
