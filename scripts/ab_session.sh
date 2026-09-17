#!/usr/bin/env bash
# One build's share of an A/B image-quality + frame-rate comparison.
#
#   scripts/ab_session.sh <label> <bitfile> [device]
#
# Programs <bitfile> over JTAG (volatile; QSPI is untouched), waits for DDR
# calibration, then for EO panorama and IR panorama grabs a 60-frame average,
# and finally runs the four-mode optical frame-rate + black-frame check.
#
# NOTE: eo_video_mode.py re-sends the camera display parameters as a side
# effect of changing mode (see its docstring).  Every session does the same, so
# the comparison stays fair.
set -u
cd "$(dirname "$0")/.."
LABEL="$1"; BIT="$2"; DEV="${3:-0}"
OUT="captures/ab_${LABEL}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
VIV="C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat"

if [ "$BIT" != "none" ]; then
    echo "== programming $BIT"
    "$VIV" -mode batch -nojournal -nolog -source scripts/program_bit.tcl -tclargs "$BIT" \
        > "$OUT/program.log" 2>&1
    grep -E "PROGRAMMED=|ERROR" "$OUT/program.log"
    sleep 40
fi

for m in "14:eo_panorama" "13:ir_panorama"; do
    sel="${m%%:*}"; name="${m#*:}"
    echo "== $name"
    python scripts/eo_video_mode.py --select "$sel" 2>&1 | grep -E "STATUS now" || echo "  mode change failed"
    sleep 12
    python scripts/grab_average.py --device "$DEV" --frames 60 --out "$OUT/$name" 2>&1 | grep -v "WARN:"
done

bash scripts/measure_30fps_optical.sh 10 "$DEV" 2>&1 | tee "$OUT/fps.txt" | sed -n '/^summary/,$p'
echo "OUT=$OUT"
