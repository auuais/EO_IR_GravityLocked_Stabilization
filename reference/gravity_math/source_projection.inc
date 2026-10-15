static inline bool compute_axay_for_dest_rowptr(
    int ox,
    int pcw,
    const int32_t* baseX_row, // points to base_x_q16[sy*per_cam_w_max]
    const int32_t* baseY_row,
    int32_t cx_q, int32_t cy_q,
    int32_t max_x_q, int32_t max_y_q,
    int32_t y_shift_q,
    int16_t c15, int16_t s15,
    int32_t& ax_q, int32_t& ay_q,
    int& y0_out,
    uint64_t& local_reads_bytes
) {
    if ((unsigned)ox >= (unsigned)pcw) return false;

    int32_t bx_q = baseX_row[ox];
    int32_t by_q = baseY_row[ox];
    local_reads_bytes += 8;

    by_q += y_shift_q;

    int32_t dx_q = bx_q - cx_q;
    int32_t dy_q = by_q - cy_q;

    int64_t tmpx = (int64_t)c15 * dx_q + (int64_t)s15 * dy_q;
    int64_t tmpy = -(int64_t)s15 * dx_q + (int64_t)c15 * dy_q;

    ax_q = (int32_t)(tmpx >> 15) + cx_q;
    ay_q = (int32_t)(tmpy >> 15) + cy_q;

    if (ax_q < 0 || ax_q > max_x_q || ay_q < 0 || ay_q > max_y_q) return false;

    int y0 = (ay_q >> WFIX_SHIFT);
    if (y0 < 0 || y0 >= HEIGHT - 1) return false;

    y0_out = y0;
    return true;
}
