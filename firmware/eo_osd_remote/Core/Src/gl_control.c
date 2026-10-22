#include "gl_control.h"
#include "fpga_regs.h"

uint8_t gl_control_encode(uint8_t ui_on_off, uint8_t ui_method)
{
    return ui_on_off == 1u && ui_method == 1u ? FPGA_GL_CONTROL_ON : FPGA_GL_CONTROL_OFF;
}

bool gl_mode_uses_vsync(uint8_t stored_mode)
{
    // 14/15 are the stored/on-wire ICD panorama modes. Keep legacy 01/02.
    return stored_mode == 0x01u || stored_mode == 0x02u ||
           stored_mode == 0x14u || stored_mode == 0x15u;
}

void gl_control_init(gl_control_t *control)
{
    control->desired = FPGA_GL_CONTROL_OFF;
    control->pending = true;
    control->attempted = false;
    control->last_attempt_ms = 0u;
    control->last_result = HAL_ERROR;
}

void gl_control_set_ui(gl_control_t *control, uint8_t ui_on_off, uint8_t ui_method)
{
    uint8_t desired = gl_control_encode(ui_on_off, ui_method);
    if (desired != control->desired) {
        control->desired = desired;
        control->pending = true;
        control->attempted = false; // A new Off immediately supersedes pending On.
    }
}

void gl_control_service(gl_control_t *control, fpga_i2c_t *dev, uint32_t now_ms)
{
    // Refresh after success also restores control following FPGA-only reset.
    const uint32_t interval = control->pending ? 100u : 1000u;
    if (control->attempted && (uint32_t)(now_ms - control->last_attempt_ms) < interval) return;
    control->attempted = true;
    control->last_attempt_ms = now_ms;
    control->last_result = fpga_write_verify_reg8_value(dev, FPGA_REG_GL_CONTROL,
                                                      control->desired, 20u);
    control->pending = control->last_result != HAL_OK;
}
