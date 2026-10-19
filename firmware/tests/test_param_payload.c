#include "param_payload.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static unsigned long long checks;

static void write_u16(uint8_t *p, uint16_t value)
{
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
}

static void write_u32(uint8_t *p, uint32_t value)
{
    for (unsigned i = 0; i < 4u; ++i) p[i] = (uint8_t)(value >> (i * 8u));
}

static void initial_payload(uint8_t *p)
{
    static const uint16_t yaw[6] = {9000, 15000, 21000, 27000, 33000, 39000};
    memset(p, 0, PARAM_PAYLOAD_BANK_SIZE);
    for (unsigned i = 0; i < 6u; ++i) write_u16(p + i * 2u, yaw[i]);
    write_u16(p + 36u, 30);
    write_u32(p + 38u, 65536);
}

static void expect_invalid(const uint8_t *p, size_t length)
{
    ParamBankQ16 out, before;
    memset(&out, 0xa5, sizeof(out));
    memcpy(&before, &out, sizeof(out));
    assert(!param_payload_decode(p, length, &out));
    assert(memcmp(&out, &before, sizeof(out)) == 0);
    ++checks;
}

static void test_layout_and_lengths(void)
{
    uint8_t p[64];
    ParamBankQ16 bank;
    initial_payload(p);
    assert(p[10] == 0x58 && p[11] == 0x98); /* 39000, never -26536. */
    static const int16_t pitch[6] = {-500, -1, 0, 1, 499, 500};
    for (unsigned i = 0; i < 6u; ++i) {
        write_u16(p + 12u + i * 2u, (uint16_t)pitch[i]);
        write_u16(p + 24u + i * 2u, (uint16_t)pitch[5u - i]);
    }
    write_u16(p + 36u, 1920);
    assert(param_payload_decode(p, 42, &bank));
    for (unsigned i = 0; i < 6u; ++i) {
        assert(bank.yaw_cd[i] == 9000u + i * 6000u);
        assert(bank.pitch_cd[i] == pitch[i]);
        assert(bank.roll_cd[i] == pitch[5u - i]);
    }
    assert(bank.overlap_px == 1920 && bank.feather_strength_q16 == 65536);
    ++checks;
    for (size_t n = 0; n <= sizeof(p); ++n) if (n != 42u) expect_invalid(p, n);
    expect_invalid(NULL, 42);
    assert(!param_payload_decode(p, 42, NULL)); ++checks;
    write_u16(p + 36u, 1921); expect_invalid(p, 42);
    write_u16(p + 36u, 65535); expect_invalid(p, 42);
    write_u16(p + 36u, 0); assert(param_payload_decode(p, 42, &bank)); ++checks;
}

static void test_all_yaw_and_signed_angles(void)
{
    uint8_t p[42];
    ParamBankQ16 bank;
    initial_payload(p);
    for (uint32_t value = 0; value <= 65535u; ++value) {
        write_u16(p + 10u, (uint16_t)value);
        assert(param_payload_decode(p, sizeof(p), &bank));
        assert(bank.yaw_cd[5] == value); ++checks;
    }
    initial_payload(p);
    for (unsigned axis = 0; axis < 2u; ++axis) {
        for (unsigned cam = 0; cam < 6u; ++cam) {
            const unsigned offset = 12u + axis * 12u + cam * 2u;
            for (uint32_t value = 0; value <= 65535u; ++value) {
                const int32_t signed_value = value <= 32767u ? (int32_t)value : (int32_t)value - 65536;
                write_u16(p + offset, (uint16_t)value);
                if (signed_value >= -500 && signed_value <= 500) {
                    assert(param_payload_decode(p, sizeof(p), &bank));
                    assert((axis ? bank.roll_cd[cam] : bank.pitch_cd[cam]) == signed_value);
                    ++checks;
                } else expect_invalid(p, sizeof(p));
            }
            write_u16(p + offset, 0);
        }
    }
}

static void test_feather(void)
{
    uint8_t p[42];
    ParamBankQ16 bank;
    initial_payload(p);
    for (uint32_t q16 = 6554u; q16 <= 655360u; ++q16) {
        write_u32(p + 38u, q16);
        assert(param_payload_decode(p, sizeof(p), &bank));
        assert(bank.feather_strength_q16 == (int32_t)q16); ++checks;
    }
    static const struct { uint32_t bits; int32_t q16; } valid_float[] = {
        {0x3dcccccdu, 6554},       /* 0.1f */
        {0x3f800000u, 65536},      /* 1.0f, actual legacy PC Apply encoding */
        {0x3fa00000u, 81920},      /* 1.25f */
        {0x3fc00000u, 98304},      /* 1.5f */
        {0x41200000u, 655360},     /* 10.0f */
        {0x3f800040u, 65537},      /* exactly 1 + half a Q16 step: round up */
        {0x3f80003fu, 65536},      /* just below half a Q16 step */
        {0x3f800041u, 65537},      /* just above half a Q16 step */
        {0x411fffffu, 655360}      /* greatest float below 10 */
    };
    for (size_t i = 0; i < sizeof(valid_float) / sizeof(valid_float[0]); ++i) {
        write_u32(p + 38u, valid_float[i].bits);
        assert(param_payload_decode(p, sizeof(p), &bank));
        assert(bank.feather_strength_q16 == valid_float[i].q16); ++checks;
    }
    static const uint32_t invalid[] = {
        0, 1, 6553, 655361, 0xffffffffu, 0x80000000u, 0x7f800000u,
        0xff800000u, 0x7fc00000u, 0x7f800001u, 0xffc00000u,
        0x3dccccccu, 0x41200001u, 0xbdcccccdu, 0xbf800000u, 0x7f7fffffu
    };
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
        write_u32(p + 38u, invalid[i]); expect_invalid(p, sizeof(p));
    }
}

static void test_protocol_gates(void)
{
    uint8_t payload[64] = {0};
    for (unsigned type = 0; type < 256u; ++type) {
        for (unsigned command = 0; command < 256u; ++command) {
            const bool calibration = type == 1u && (command == 0x30u || command == 0x31u);
            const bool allowed = calibration || (type == 1u && command == 0x33u);
            assert(param_payload_is_calibration_command((uint8_t)type, (uint8_t)command) == calibration);
            assert(param_payload_allow_legacy_command((uint8_t)type, (uint8_t)command) == allowed);
            checks += 2;
            payload[0] = (uint8_t)command;
            for (size_t n = 0; n <= sizeof(payload); ++n) {
                const bool reply = (type == 2u && n == 1u) ||
                    (type == 3u && ((command == 0x30u && n == 45u) || (command == 0x31u && n == 4u)));
                assert(param_payload_is_calibration_reply((uint8_t)type, payload, n) == reply);
                ++checks;
            }
        }
        for (size_t n = 0; n <= 64u; ++n) {
            assert(!param_payload_is_calibration_reply((uint8_t)type, NULL, n)); ++checks;
        }
    }
}

int main(void)
{
    test_layout_and_lengths();
    test_all_yaw_and_signed_angles();
    test_feather();
    test_protocol_gates();
    printf("PASS param payload: %llu checks; exact42, camera layout, all uint16 yaw, all signed16 R/P, Q16/legacy IEEE float, invalid/atomic output, exhaustive protocol gates\n", checks);
    return 0;
}
