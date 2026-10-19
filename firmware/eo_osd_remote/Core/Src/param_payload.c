#include "param_payload.h"
#include <float.h>
#include <string.h>

_Static_assert(sizeof(float) == 4 && FLT_RADIX == 2 && FLT_MANT_DIG == 24 &&
               FLT_MAX_EXP == 128, "Legacy UI feather requires IEEE binary32");
_Static_assert(PARAM_STORE_CAM_COUNT == 6u, "Bank wire layout has six cameras");

static uint16_t read_u16(const uint8_t *p)
{
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static int16_t read_i16(const uint8_t *p)
{
    const uint16_t value = read_u16(p);
    return (int16_t)(value <= UINT16_C(32767) ? (int32_t)value :
                     (int32_t)value - INT32_C(65536));
}

static bool decode_feather(const uint8_t *p, int32_t *out)
{
    const uint32_t bits = (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                          ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    if (bits >= UINT32_C(6554) && bits <= UINT32_C(655360)) {
        *out = (int32_t)bits;
        return true;
    }
    /* Reject NaN/Inf before float evaluation. Valid Q16 bit patterns describe
     * tiny subnormal floats, so the two accepted representations are disjoint. */
    if ((bits & UINT32_C(0x7f800000)) == UINT32_C(0x7f800000)) return false;
    float value;
    memcpy(&value, &bits, sizeof(value));
    if (!(value >= 0.1f && value <= 10.0f)) return false;
    *out = (int32_t)((double)value * 65536.0 + 0.5);
    return true;
}

bool param_payload_decode(const uint8_t *payload, size_t length, ParamBankQ16 *out)
{
    if (!payload || !out || length != PARAM_PAYLOAD_BANK_SIZE) return false;
    ParamBankQ16 bank;
    memset(&bank, 0, sizeof(bank));
    for (size_t i = 0; i < PARAM_STORE_CAM_COUNT; ++i) {
        bank.yaw_cd[i] = read_u16(payload + i * 2u);
        bank.pitch_cd[i] = read_i16(payload + 12u + i * 2u);
        bank.roll_cd[i] = read_i16(payload + 24u + i * 2u);
    }
    bank.overlap_px = read_u16(payload + 36u);
    if (!decode_feather(payload + 38u, &bank.feather_strength_q16) ||
        !param_store_bank_valid(&bank)) return false;
    memcpy(out, &bank, sizeof(bank));
    return true;
}

bool param_payload_is_calibration_command(uint8_t type, uint8_t command)
{
    return type == 1u && (command == 0x30u || command == 0x31u);
}

bool param_payload_allow_legacy_command(uint8_t type, uint8_t command)
{
    return param_payload_is_calibration_command(type, command) ||
           (type == 1u && command == 0x33u);
}

bool param_payload_is_calibration_reply(uint8_t type, const uint8_t *payload,
                                        size_t length)
{
    if (!payload) return false;
    if (type == 2u) return length == 1u;
    if (type != 3u || length == 0u) return false;
    return (payload[0] == 0x30u && length == 45u) ||
           (payload[0] == 0x31u && length == 4u);
}
