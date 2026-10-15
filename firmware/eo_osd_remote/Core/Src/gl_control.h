#pragma once
#include "fpga_i2c.h"

// Desired UI state and observed transport result are distinct. A failed write,
// failed read or mismatched readback remains pending until a later retry.
typedef struct {
    uint8_t desired;
    bool pending;
    bool attempted;
    uint32_t last_attempt_ms;
    HAL_StatusTypeDef last_result;
} gl_control_t;

uint8_t gl_control_encode(uint8_t ui_on_off, uint8_t ui_method);
bool gl_mode_uses_vsync(uint8_t stored_mode);
void gl_control_init(gl_control_t *control);
void gl_control_set_ui(gl_control_t *control, uint8_t ui_on_off, uint8_t ui_method);
void gl_control_service(gl_control_t *control, fpga_i2c_t *dev, uint32_t now_ms);
