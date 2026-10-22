#ifndef PARAM_PAYLOAD_H
#define PARAM_PAYLOAD_H

#include "param_store.h"

#define PARAM_PAYLOAD_BANK_SIZE 42u

/* Exact legacy bank wire layout: six unsigned yaw, six signed pitch, six
 * signed roll, unsigned overlap, then feather. All fields are little endian;
 * the 42-byte wire bank has none of ParamBankQ16's native alignment padding.
 * Feather accepts valid Q16 first, or finite IEEE binary32 in [0.1f, 10.0f]
 * for the identified legacy PC UI. Output is canonical Q16 and changes only
 * on success. No yaw normalization or signed interpretation is performed. */
bool param_payload_decode(const uint8_t *payload, size_t length, ParamBankQ16 *out);

/* Narrow legacy protocol gates. The caller must validate the enclosing frame
 * and scope calibration replies to the active calibration request. These
 * helpers do not authorize unsolicited legacy telemetry. */
bool param_payload_is_calibration_command(uint8_t type, uint8_t command);
bool param_payload_allow_legacy_command(uint8_t type, uint8_t command);
bool param_payload_is_calibration_reply(uint8_t type, const uint8_t *payload,
                                        size_t length);

#endif
