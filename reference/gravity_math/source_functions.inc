static inline int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

static inline int32_t deg_to_centi(float deg) { return (int32_t)std::lround((double)deg * 100.0); }
static inline float centi_to_deg(int32_t centi) { return (float)centi * 0.01f; }
static inline int32_t float_to_q16(float v) { return (int32_t)std::lround((double)v * 65536.0); }
static inline float q16_to_float(int32_t q16) { return (float)q16 / 65536.0f; }

static inline int32_t div_round_i64(int64_t num, int64_t den)
{
    if (den == 0) return 0;
    if (num >= 0) return (int32_t)((num + den / 2) / den);
    return (int32_t)((num - den / 2) / den);
}

struct AngleLUTEntry { int16_t c; int16_t s; };
static std::vector<AngleLUTEntry> ANG_LUT;               // [-5,5] step 0.25 deg (legacy roll LUT)
static std::vector<AngleLUTEntry> ANG_CENTI_LUT;         // [0,35999] step 0.01 deg
static std::vector<int16_t> ATAN_RATIO_CENTI_LUT;        // atan(r), r in [0,1], centi-deg
static const int ATAN_RATIO_LUT_SIZE = 4096;

static inline void build_angle_lut() {
    if (!ANG_LUT.empty() && !ANG_CENTI_LUT.empty() && !ATAN_RATIO_CENTI_LUT.empty()) {
        save_angle_luts_if_ready();
        return;
    }
    StageTimer _t(ST_LUT);
    if (ANG_LUT.empty()) {
        const float minDeg = -5.0f, maxDeg = 5.0f, step = 0.25f;
        int N = (int)std::lround((maxDeg - minDeg) / step) + 1;
        ANG_LUT.resize(N);
        for (int i = 0; i < N; ++i) {
            float deg = minDeg + i * step;
            float rad = deg * (float)M_PI / 180.0f;
            int16_t c = (int16_t)std::lroundf(cosf(rad) * 32767.0f);
            int16_t s = (int16_t)std::lroundf(sinf(rad) * 32767.0f);
            ANG_LUT[i] = { c, s };
        }
    }

    if (ANG_CENTI_LUT.empty()) {
        ANG_CENTI_LUT.resize(36000);
        for (int i = 0; i < 36000; ++i) {
            double deg = (double)i * 0.01;
            double rad = deg * M_PI / 180.0;
            int16_t c = (int16_t)std::lround(std::cos(rad) * 32767.0);
            int16_t s = (int16_t)std::lround(std::sin(rad) * 32767.0);
            ANG_CENTI_LUT[(size_t)i] = { c, s };
        }
    }

    if (ATAN_RATIO_CENTI_LUT.empty()) {
        ATAN_RATIO_CENTI_LUT.resize((size_t)ATAN_RATIO_LUT_SIZE + 1);
        for (int i = 0; i <= ATAN_RATIO_LUT_SIZE; ++i) {
            double ratio = (double)i / (double)ATAN_RATIO_LUT_SIZE;
            int16_t centi = (int16_t)std::lround(std::atan(ratio) * 18000.0 / M_PI);
            ATAN_RATIO_CENTI_LUT[(size_t)i] = centi;
        }
    }

    save_angle_luts_if_ready();
}

static inline int32_t wrap_centi_360(int32_t centi)
{
    int32_t v = centi % 36000;
    return (v < 0) ? (v + 36000) : v;
}

static inline void get_cos_sin_q15_centi(int32_t centi, int16_t* c, int16_t* s)
{
    if (ANG_CENTI_LUT.empty()) build_angle_lut();
    int32_t idx = wrap_centi_360(centi);
    const AngleLUTEntry& e = ANG_CENTI_LUT[(size_t)idx];
    *c = e.c;
    *s = e.s;
}

static inline int32_t clamp_q15_from_q30(int64_t v_q30)
{
    int64_t q15 = (v_q30 + (1ll << 14)) >> 15;
    if (q15 > 32767) q15 = 32767;
    if (q15 < -32768) q15 = -32768;
    return (int32_t)q15;
}

static inline void matmul_q15(const int32_t A[3][3], const int32_t B[3][3], int32_t O[3][3])
{
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            int64_t acc_q30 =
                (int64_t)A[i][0] * B[0][j] +
                (int64_t)A[i][1] * B[1][j] +
                (int64_t)A[i][2] * B[2][j];
            O[i][j] = clamp_q15_from_q30(acc_q30);
        }
    }
}

static uint32_t isqrt_u64(uint64_t x)
{
    uint64_t res = 0;
    uint64_t bit = 1ull << 62;
    while (bit > x) bit >>= 2;
    while (bit != 0) {
        if (x >= res + bit) {
            x -= res + bit;
            res = (res >> 1) + bit;
        } else {
            res >>= 1;
        }
        bit >>= 2;
    }
    return (uint32_t)res;
}

static int32_t atan2_centi_q15(int32_t y_q15, int32_t x_q15)
{
    if (ATAN_RATIO_CENTI_LUT.empty()) build_angle_lut();
    if (y_q15 == 0 && x_q15 == 0) return 0;

    int64_t ay = std::llabs((long long)y_q15);
    int64_t ax = std::llabs((long long)x_q15);
    int32_t base = 0;

    if (ax == 0) {
        base = 9000;
    } else if (ay <= ax) {
        int idx = (int)((ay * ATAN_RATIO_LUT_SIZE + (ax / 2)) / ax);
        idx = clampi(idx, 0, ATAN_RATIO_LUT_SIZE);
        base = ATAN_RATIO_CENTI_LUT[(size_t)idx];
    } else {
        int idx = (int)((ax * ATAN_RATIO_LUT_SIZE + (ay / 2)) / ay);
        idx = clampi(idx, 0, ATAN_RATIO_LUT_SIZE);
        base = 9000 - ATAN_RATIO_CENTI_LUT[(size_t)idx];
    }

    if (x_q15 >= 0) return (y_q15 >= 0) ? base : -base;
    return (y_q15 >= 0) ? (18000 - base) : (base - 18000);
}

static int32_t asin_centi_q15(int32_t v_q15)
{
    int32_t v = clampi(v_q15, -32767, 32767);
    int64_t vv_q30 = (int64_t)v * (int64_t)v;
    int64_t one_q30 = (1ll << 30);
    int64_t rem_q30 = one_q30 - vv_q30;
    if (rem_q30 < 0) rem_q30 = 0;
    int32_t cos_q15 = (int32_t)isqrt_u64((uint64_t)rem_q30);
    return atan2_centi_q15(v, cos_q15);
}

static void convert_rpy_sensor_to_cam_centi(int32_t roll_sys1_centi, int32_t pitch_sys1_centi,
    int32_t yaw_offset_centi, int32_t pitch_offset_centi, int32_t roll_offset_centi,
    int32_t* roll_centi_out, int32_t* pitch_centi_out, int32_t* yaw_centi_out)
{
    int16_t c_rr, s_rr, c_pp, s_pp;
    int16_t c_ror, s_ror, c_por, s_por, c_yor, s_yor;

    get_cos_sin_q15_centi(roll_sys1_centi, &c_rr, &s_rr);
    get_cos_sin_q15_centi(pitch_sys1_centi, &c_pp, &s_pp);
    get_cos_sin_q15_centi(roll_offset_centi, &c_ror, &s_ror);
    get_cos_sin_q15_centi(pitch_offset_centi, &c_por, &s_por);
    get_cos_sin_q15_centi(yaw_offset_centi, &c_yor, &s_yor);

    const int32_t ONE_Q15 = 32767;
    int32_t Rx[3][3] = {
        { ONE_Q15, 0, 0 },
        { 0, c_rr, -s_rr },
        { 0, s_rr, c_rr }
    };
    int32_t Ry[3][3] = {
        { c_pp, 0, s_pp },
        { 0, ONE_Q15, 0 },
        { -s_pp, 0, c_pp }
    };

    int32_t Rr[3][3] = {
        { ONE_Q15, 0, 0 },
        { 0, c_ror, -s_ror },
        { 0, s_ror, c_ror }
    };
    int32_t Rp[3][3] = {
        { c_por, 0, s_por },
        { 0, ONE_Q15, 0 },
        { -s_por, 0, c_por }
    };
    int32_t Rz[3][3] = {
        { c_yor, -s_yor, 0 },
        { s_yor, c_yor, 0 },
        { 0, 0, ONE_Q15 }
    };

    int32_t R_sys1[3][3], Rt[3][3], Roff[3][3], R[3][3];
    matmul_q15(Rx, Ry, R_sys1);
    matmul_q15(Rz, Rp, Rt);
    matmul_q15(Rt, Rr, Roff);
    matmul_q15(R_sys1, Roff, R);

    int32_t pitch_centi = asin_centi_q15(-R[2][0]);

    int16_t c_pitch = 0, s_pitch = 0;
    get_cos_sin_q15_centi(pitch_centi, &c_pitch, &s_pitch);
    (void)s_pitch;

    int32_t roll_centi = 0;
    int32_t yaw_centi = 0;
    if (std::abs((int)c_pitch) > 8) {
        roll_centi = atan2_centi_q15(R[2][1], R[2][2]);
        yaw_centi = atan2_centi_q15(R[1][0], R[0][0]);
    } else {
        roll_centi = 0;
        yaw_centi = atan2_centi_q15(-R[0][1], R[1][1]);
    }

    if (roll_centi_out) *roll_centi_out = roll_centi;
    if (pitch_centi_out) *pitch_centi_out = pitch_centi;
    if (yaw_centi_out) *yaw_centi_out = yaw_centi;
}
