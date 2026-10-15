#include "oracle.hpp"
#include <iomanip>
#include <iostream>
#include <string>

// A dependency-free, line-oriented numerical oracle. stdout contains only data;
// the Python harness batches requests through one process and validates every
// response. It never loads INIs, camera images, hardware, or production profiles.
int main()
{
    using namespace gravity_oracle;
    build_angle_lut();
    std::ios::sync_with_stdio(false);
    std::string op;
    while (std::cin >> op) {
        if (op == "LUTS") {
            std::cout << "LUTS";
            for (const auto& entry : ANG_CENTI_LUT) std::cout << ' ' << entry.c << ' ' << entry.s;
            for (const auto value : ATAN_RATIO_CENTI_LUT) std::cout << ' ' << value;
            std::cout << '\n';
        } else if (op == "FRAME") {
            int count = 0, enabled = 0;
            int32_t r, p, y, factor, resize, limit;
            std::cin >> count >> r >> p >> y >> enabled >> factor >> resize >> limit;
            if (count < 1 || count > 1024 || limit <= 0) return 2;
            std::vector<Mount> mounts(static_cast<size_t>(count));
            for (auto& mount : mounts) std::cin >> mount.yaw >> mount.pitch >> mount.roll;
            const auto f = compute_frame(r, p, y, enabled != 0, mounts, factor, resize, limit);
            std::cout << "FRAME " << f.roll << ' ' << f.pitch << ' ' << f.yaw << ' '
                << f.max_camera_angle << ' ' << f.limited << ' ' << f.pitch_factor << ' ' << count;
            for (const auto& pose : f.poses) {
                std::cout << ' ' << pose.roll << ' ' << pose.pitch << ' ' << pose.yaw
                    << ' ' << pose.cosine << ' ' << pose.sine << ' ' << pose.y_shift_px << ' ' << pose.y_shift_q16;
            }
            std::cout << '\n';
        } else if (op == "ANGLE") {
            int32_t r, p, yo, po, ro, rc = 0, pc = 0, yc = 0;
            std::cin >> r >> p >> yo >> po >> ro;
            convert_rpy_sensor_to_cam_centi(r, p, yo, po, ro, &rc, &pc, &yc);
            std::cout << "ANGLE " << rc << ' ' << pc << ' ' << yc << '\n';
        } else if (op == "ATAN") {
            int32_t y, x; std::cin >> y >> x;
            std::cout << "ATAN " << atan2_centi_q15(y, x) << '\n';
        } else if (op == "ASIN") {
            int32_t v; std::cin >> v;
            std::cout << "ASIN " << asin_centi_q15(v) << '\n';
        } else if (op == "SQRT") {
            uint64_t v; std::cin >> v;
            std::cout << "SQRT " << isqrt_u64(v) << '\n';
        } else if (op == "DIV") {
            int64_t num, den; std::cin >> num >> den;
            std::cout << "DIV " << div_round_i64(num, den) << '\n';
        } else if (op == "FLOAT") {
            float v; std::cin >> v;
            std::cout << "FLOAT " << deg_to_centi(v) << ' ' << float_to_q16(v) << '\n';
        } else if (op == "MAP") {
            int width, height, cosine, sine;
            int32_t bx, by, shift;
            std::cin >> width >> height >> bx >> by >> shift >> cosine >> sine;
            HEIGHT = height;
            int32_t ax = 0, ay = 0;
            int row = -1;
            uint64_t reads = 0;
            const bool valid = compute_axay_for_dest_rowptr(0, 1, &bx, &by,
                width << 15, height << 15, (width - 2) << 16, (height - 2) << 16,
                shift, static_cast<int16_t>(cosine), static_cast<int16_t>(sine), ax, ay, row, reads);
            std::cout << "MAP " << valid << ' ' << ax << ' ' << ay << ' ' << row << '\n';
        } else {
            std::cerr << "Unknown request: " << op << '\n';
            return 2;
        }
        if (!std::cin) { std::cerr << "Malformed " << op << " request\n"; return 2; }
    }
    return 0;
}
