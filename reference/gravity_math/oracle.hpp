#pragma once

// The .inc files are byte-for-byte source excerpts. See provenance.json.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace gravity_oracle {
// Non-numerical dependencies of the unmodified LUT builder.
enum { ST_LUT };
struct StageTimer { explicit StageTimer(int) {} };
static void save_angle_luts_if_ready() {}
static const int WFIX_SHIFT = 16;
static int HEIGHT = 0;

#include "source_functions.inc"
#include "source_projection.inc"

struct Mount { int32_t yaw, pitch, roll; };
struct Pose { int32_t roll, pitch, yaw, cosine, sine, y_shift_px, y_shift_q16; };
struct Frame {
    int32_t roll, pitch, yaw, max_camera_angle;
    bool limited;
    int32_t pitch_factor;
    std::vector<Pose> poses;
};

static Frame compute_frame(int32_t live_roll, int32_t live_pitch, int32_t live_yaw,
    bool enabled, const std::vector<Mount>& mounts, int32_t factor_q16,
    int32_t resize_q16, int32_t limit_centi)
{
    int32_t roll_Sensor_centi = enabled ? live_roll : 0;
    int32_t pitch_Sensor_centi = enabled ? live_pitch : 0;
    int32_t yaw_Sensor_centi = enabled ? live_yaw : 0;
    const int NUM_CAMS = static_cast<int>(mounts.size());
    const int32_t MAX_CAM_ANGLE_CENTI = limit_centi;
    std::vector<int32_t> yaw_off, pit_off, rol_off;
    for (const Mount& mount : mounts) {
        yaw_off.push_back(mount.yaw);
        pit_off.push_back(mount.pitch);
        rol_off.push_back(mount.roll);
    }

    // Read-only diagnostic duplicates the before-limit measurement; the actual
    // applied limit below is the unchanged block from source main().
    int32_t before = 0;
    if (roll_Sensor_centi || pitch_Sensor_centi || yaw_Sensor_centi) {
        for (const Mount& mount : mounts) {
            int32_t r = 0, p = 0, y = 0;
            convert_rpy_sensor_to_cam_centi(roll_Sensor_centi, pitch_Sensor_centi,
                mount.yaw, mount.pitch, mount.roll, &r, &p, &y);
            before = std::max({before, std::abs(r), std::abs(p)});
        }
    }

    // Redirect the original clamp's informational print away from the protocol.
#define printf(...) ((void)0)
#include "source_clamp.inc"
#undef printf

    if (resize_q16 == 0) resize_q16 = 1 << 16;
    // Same signed-shift expression as applyCameraConfig(), source line 1011.
    const int32_t PITCH_TO_TRANSLATION_FACTOR_q16 =
        div_round_i64((int64_t)factor_q16 << 16, resize_q16);
    std::vector<int32_t> y_shift_q_cam(NUM_CAMS, 0);
    std::vector<int16_t> c15_cam(NUM_CAMS, 0), s15_cam(NUM_CAMS, 0);
    Frame output{roll_Sensor_centi, pitch_Sensor_centi, yaw_Sensor_centi,
        before, before > limit_centi, PITCH_TO_TRANSLATION_FACTOR_q16, {}};
    for (int cam = 0; cam < NUM_CAMS; ++cam) {
        int32_t roll_cam_centi = 0, pitch_cam_centi = 0, yaw_cam_centi = 0;
        convert_rpy_sensor_to_cam_centi(roll_Sensor_centi, pitch_Sensor_centi,
            yaw_off[cam], pit_off[cam], rol_off[cam],
            &roll_cam_centi, &pitch_cam_centi, &yaw_cam_centi);
#include "source_camera_coefficients.inc"
        output.poses.push_back({roll_cam_centi, pitch_cam_centi, yaw_cam_centi,
            c15_cam[cam], s15_cam[cam], y_shift_px, y_shift_q_cam[cam]});
    }
    return output;
}
} // namespace gravity_oracle
