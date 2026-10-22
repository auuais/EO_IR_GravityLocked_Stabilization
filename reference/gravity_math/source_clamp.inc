        // Clamp logic: compute maximum per-camera angle, scaling IMU sensor data if it exceeds MAX_CAM_ANGLE_CENTI
        if (roll_Sensor_centi != 0 || pitch_Sensor_centi != 0 || yaw_Sensor_centi != 0) {
            int32_t max_cam_angle_centi = 0;
            for (int cam = 0; cam < NUM_CAMS; ++cam) {
                int32_t r_cam_c = 0, p_cam_c = 0, y_cam_c = 0;
                convert_rpy_sensor_to_cam_centi(
                    roll_Sensor_centi, pitch_Sensor_centi,
                    (cam < (int)yaw_off.size() ? yaw_off[cam] : 0),
                    (cam < (int)pit_off.size() ? pit_off[cam] : 0),
                    (cam < (int)rol_off.size() ? rol_off[cam] : 0),
                    &r_cam_c, &p_cam_c, &y_cam_c
                );
                (void)y_cam_c;
                max_cam_angle_centi = std::max({ max_cam_angle_centi, std::abs(r_cam_c), std::abs(p_cam_c) });
            }

            if (max_cam_angle_centi > MAX_CAM_ANGLE_CENTI) {
                roll_Sensor_centi = div_round_i64((int64_t)roll_Sensor_centi * MAX_CAM_ANGLE_CENTI, max_cam_angle_centi);
                pitch_Sensor_centi = div_round_i64((int64_t)pitch_Sensor_centi * MAX_CAM_ANGLE_CENTI, max_cam_angle_centi);
                yaw_Sensor_centi = div_round_i64((int64_t)yaw_Sensor_centi * MAX_CAM_ANGLE_CENTI, max_cam_angle_centi);
                printf("[ORIENTATION] Max camera angle %d.%02d > %d.%02d. Scaled global sensor by %d/%d\n",
                    max_cam_angle_centi / 100, std::abs(max_cam_angle_centi % 100),
                    MAX_CAM_ANGLE_CENTI / 100, MAX_CAM_ANGLE_CENTI % 100,
                    MAX_CAM_ANGLE_CENTI, max_cam_angle_centi);
            }
        }
