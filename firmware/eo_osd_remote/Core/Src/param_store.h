#ifndef PARAM_STORE_H
#define PARAM_STORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define PARAM_STORE_CAM_COUNT 6u
#define PARAM_STORE_MAGIC UINT32_C(0x5041524D)
#define PARAM_STORE_VERSION 3u
#define PARAM_STORE_PAGE_BYTES 2048u
#define PARAM_STORE_PROFILE_REVISION UINT32_C(0x7106B1F1)
#define PARAM_STORE_JOURNAL_MAGIC UINT32_C(0x4A524150)
#define PARAM_STORE_JOURNAL_VERSION 4u
#define PARAM_STORE_HEADER_BYTES 32u
#define PARAM_STORE_BODY_BYTES 144u
#define PARAM_STORE_COMMIT_OFFSET PARAM_STORE_BODY_BYTES
#define PARAM_STORE_COMMIT_MARKER UINT64_C(0xA5C35A3CC33CA55A)

/* This native little-endian bank deliberately retains legacy ABI padding at
 * bytes 38..39. The naturally aligned blob has the exact 112-byte v3 packed
 * on-flash layout; explicit reserved0 also keeps both RAM banks aligned. */
typedef struct {
    uint16_t yaw_cd[PARAM_STORE_CAM_COUNT];
    int16_t pitch_cd[PARAM_STORE_CAM_COUNT];
    int16_t roll_cd[PARAM_STORE_CAM_COUNT];
    uint16_t overlap_px;
    int32_t feather_strength_q16;
} ParamBankQ16;

typedef struct {
    uint32_t magic;
    uint16_t version;
    uint16_t length;
    uint32_t crc32;
    uint8_t mode;
    uint8_t reserved0[3];
    ParamBankQ16 eo;
    ParamBankQ16 ir;
    uint32_t write_count;
    uint32_t reserved1;
} ParamStoreBlob;

typedef struct {
    void *ctx;
    bool (*read)(void *ctx, uint8_t slot, uint32_t offset, void *out, size_t length);
    bool (*erase)(void *ctx, uint8_t slot);
    bool (*program)(void *ctx, uint8_t slot, uint32_t offset, uint64_t data);
} ParamStoreIo;

typedef enum {
    PARAM_STORE_OK = 0,
    PARAM_STORE_BAD_ARGUMENT,
    PARAM_STORE_IO_ERROR,
    /* The last marker might be physically committed but could not be read
     * back. Active metadata/cfg stay unchanged; reboot can select that record.
     * A subsequent save rescans before choosing an erase target. */
    PARAM_STORE_COMMIT_UNCERTAIN
} ParamStoreError;

typedef struct {
    int8_t active_slot; /* -1: no readable persisted copy; otherwise 0 or 1 */
    bool legacy_active;
    bool initialized;
    uint32_t generation;
    uint32_t profile_revision;
    ParamStoreError last_error; /* diagnostic; not committed metadata */
} ParamStoreState;

typedef enum {
    PARAM_STORE_SOURCE_DEFAULTS = 0,
    PARAM_STORE_SOURCE_LEGACY,
    PARAM_STORE_SOURCE_JOURNAL
} ParamStoreSource;

typedef struct {
    ParamStoreSource source;
    bool migration_needed;
    bool migration_committed;
    bool read_error;
    bool write_error;
} ParamStoreBootResult;

bool param_store_mode_valid(uint8_t mode);
bool param_store_bank_valid(const ParamBankQ16 *bank);
void param_store_defaults(ParamStoreBlob *cfg);
void param_store_seal(ParamStoreBlob *cfg);
bool param_store_blob_valid(const ParamStoreBlob *cfg);
ParamStoreBootResult param_store_boot(ParamStoreState *state, const ParamStoreIo *io,
                                      ParamStoreBlob *out);
/* cfg is an editable RAM configuration. Header/CRC/write_count and committed
 * state change only after verified commit; failed saves preserve cfg exactly.
 * A successful save increments write_count once, with unsigned wrap. */
bool param_store_save(ParamStoreState *state, const ParamStoreIo *io, ParamStoreBlob *cfg);

#endif
