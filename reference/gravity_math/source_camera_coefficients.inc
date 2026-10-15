            int y_shift_px = div_round_i64((int64_t)PITCH_TO_TRANSLATION_FACTOR_q16 * pitch_cam_centi, 100ll * (1ll << 16));
            y_shift_q_cam[cam] = (int32_t)y_shift_px << WFIX_SHIFT;

            int16_t c15 = 0, s15 = 0;
            get_cos_sin_q15_centi(-roll_cam_centi, &c15, &s15);
            c15_cam[cam] = c15;
            s15_cam[cam] = s15;
