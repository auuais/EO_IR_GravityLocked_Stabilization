#include "param_store.h"
#include <string.h>

_Static_assert(sizeof(ParamBankQ16) == 44u, "legacy bank size");
_Static_assert(offsetof(ParamBankQ16, feather_strength_q16) == 40u, "legacy bank padding");
_Static_assert(sizeof(ParamStoreBlob) == 112u, "legacy blob size");
_Static_assert(offsetof(ParamStoreBlob, mode) == 12u, "legacy CRC start");
_Static_assert(offsetof(ParamStoreBlob, eo) == 16u, "legacy EO offset");
_Static_assert(offsetof(ParamStoreBlob, ir) == 60u, "legacy IR offset");
_Static_assert(offsetof(ParamStoreBlob, write_count) == 104u, "legacy count offset");
_Static_assert(offsetof(ParamStoreBlob, reserved1) == 108u, "legacy reserved offset");
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "Legacy ParamStoreBlob requires a little-endian target"
#endif

typedef struct {
    bool valid;
    bool read_error;
    uint32_t generation;
    uint32_t profile;
    ParamStoreBlob cfg;
} Record;

typedef struct {
    Record records[2];
    int8_t selected;
    bool legacy;
    bool read_error;
    ParamStoreBlob legacy_cfg;
} Scan;

static uint32_t crc32(const uint8_t *bytes, size_t length)
{
    uint32_t crc = UINT32_MAX;
    size_t i;
    for (i = 0; i < length; ++i) {
        unsigned bit;
        crc ^= bytes[i];
        for (bit = 0; bit < 8u; ++bit)
            crc = (crc >> 1) ^ (UINT32_C(0xEDB88320) & (0u - (crc & 1u)));
    }
    return ~crc;
}

static uint32_t get32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void put32(uint8_t *p, uint32_t value)
{
    p[0] = (uint8_t)value; p[1] = (uint8_t)(value >> 8);
    p[2] = (uint8_t)(value >> 16); p[3] = (uint8_t)(value >> 24);
}

bool param_store_mode_valid(uint8_t mode)
{
    return mode <= 3u || mode == 6u || (mode >= 7u && mode <= 0x15u);
}

bool param_store_bank_valid(const ParamBankQ16 *bank)
{
    unsigned i;
    if (bank == NULL) return false;
    for (i = 0; i < PARAM_STORE_CAM_COUNT; ++i) {
        if (bank->pitch_cd[i] < -500 || bank->pitch_cd[i] > 500 ||
            bank->roll_cd[i] < -500 || bank->roll_cd[i] > 500) return false;
    }
    /* Yaw is unsigned and deliberately includes the INI's 39000 cd. */
    return bank->overlap_px <= 1920u && bank->feather_strength_q16 >= 6554 &&
           bank->feather_strength_q16 <= 655360;
}

void param_store_seal(ParamStoreBlob *cfg)
{
    if (cfg == NULL) return;
    cfg->magic = PARAM_STORE_MAGIC;
    cfg->version = PARAM_STORE_VERSION;
    cfg->length = (uint16_t)sizeof(*cfg);
    cfg->crc32 = crc32((const uint8_t *)cfg + offsetof(ParamStoreBlob, mode),
                      sizeof(*cfg) - offsetof(ParamStoreBlob, mode));
}

static void apply_mounting(ParamStoreBlob *cfg)
{
    unsigned i;
    for (i = 0; i < PARAM_STORE_CAM_COUNT; ++i) {
        cfg->eo.yaw_cd[i] = (uint16_t)(6000u * i);
        cfg->ir.yaw_cd[i] = (uint16_t)(9000u + 6000u * i);
        cfg->eo.pitch_cd[i] = 0; cfg->eo.roll_cd[i] = 0;
        cfg->ir.pitch_cd[i] = 0; cfg->ir.roll_cd[i] = 0;
    }
}

void param_store_defaults(ParamStoreBlob *cfg)
{
    if (cfg == NULL) return;
    memset(cfg, 0, sizeof(*cfg));
    cfg->mode = 0x15u;
    cfg->eo.overlap_px = 100u; cfg->ir.overlap_px = 30u;
    cfg->eo.feather_strength_q16 = 65536;
    cfg->ir.feather_strength_q16 = 65536;
    apply_mounting(cfg);
    param_store_seal(cfg);
}

bool param_store_blob_valid(const ParamStoreBlob *cfg)
{
    ParamBankQ16 bank;
    if (cfg == NULL || cfg->magic != PARAM_STORE_MAGIC ||
        cfg->version != PARAM_STORE_VERSION || cfg->length != sizeof(*cfg) ||
        !param_store_mode_valid(cfg->mode)) return false;
    memcpy(&bank, &cfg->eo, sizeof(bank));
    if (!param_store_bank_valid(&bank)) return false;
    memcpy(&bank, &cfg->ir, sizeof(bank));
    return param_store_bank_valid(&bank) && cfg->crc32 ==
        crc32((const uint8_t *)cfg + offsetof(ParamStoreBlob, mode),
              sizeof(*cfg) - offsetof(ParamStoreBlob, mode));
}

static bool io_valid(const ParamStoreIo *io)
{
    return io != NULL && io->read != NULL && io->erase != NULL && io->program != NULL;
}

static bool decode_body(uint8_t body[PARAM_STORE_BODY_BYTES], Record *record)
{
    uint32_t expected = get32(body + 20);
    if (get32(body) != PARAM_STORE_JOURNAL_MAGIC ||
        get32(body + 4) != (PARAM_STORE_HEADER_BYTES << 16 | PARAM_STORE_JOURNAL_VERSION) ||
        get32(body + 16) != sizeof(ParamStoreBlob) ||
        get32(body + 24) != 0u || get32(body + 28) != 0u) return false;
    put32(body + 20, 0);
    if (crc32(body, PARAM_STORE_BODY_BYTES) != expected) return false;
    memcpy(&record->cfg, body + PARAM_STORE_HEADER_BYTES, sizeof(record->cfg));
    if (!param_store_blob_valid(&record->cfg)) return false;
    record->generation = get32(body + 8);
    record->profile = get32(body + 12);
    record->valid = true;
    return true;
}

static void read_record(const ParamStoreIo *io, uint8_t slot, Record *record)
{
    uint64_t marker;
    uint8_t body[PARAM_STORE_BODY_BYTES];
    memset(record, 0, sizeof(*record));
    /* Avoid touching potentially torn/ECC-invalid body doublewords unless its
     * separately programmed commit doubleword is complete. read may fail on ECC. */
    if (!io->read(io->ctx, slot, PARAM_STORE_COMMIT_OFFSET, &marker, sizeof(marker))) {
        record->read_error = true; return;
    }
    if (marker != PARAM_STORE_COMMIT_MARKER) return;
    if (!io->read(io->ctx, slot, 0, body, sizeof(body))) {
        record->read_error = true; return;
    }
    (void)decode_body(body, record);
}

static void scan(const ParamStoreIo *io, Scan *found)
{
    uint32_t delta;
    memset(found, 0, sizeof(*found));
    found->selected = -1;
    read_record(io, 0, &found->records[0]);
    read_record(io, 1, &found->records[1]);
    found->read_error = found->records[0].read_error || found->records[1].read_error;
    if (found->records[0].valid) found->selected = 0;
    if (found->records[1].valid) {
        delta = found->records[1].generation - found->records[0].generation;
        /* Adjacent generations wrap naturally. Equal or exactly half-range
         * ambiguity deterministically selects slot0, independent of scan order. */
        if (!found->records[0].valid || (delta != 0u && delta < UINT32_C(0x80000000)))
            found->selected = 1;
    }
    if (found->selected < 0) {
        if (io->read(io->ctx, 1, 0, &found->legacy_cfg, sizeof(found->legacy_cfg)))
            found->legacy = param_store_blob_valid(&found->legacy_cfg);
        else found->read_error = true;
    }
}

static void make_body(uint8_t body[PARAM_STORE_BODY_BYTES], const ParamStoreBlob *cfg,
                      uint32_t generation, uint32_t profile)
{
    memset(body, 0, PARAM_STORE_BODY_BYTES);
    put32(body, PARAM_STORE_JOURNAL_MAGIC);
    put32(body + 4, PARAM_STORE_HEADER_BYTES << 16 | PARAM_STORE_JOURNAL_VERSION);
    put32(body + 8, generation); put32(body + 12, profile);
    put32(body + 16, (uint32_t)sizeof(*cfg));
    memcpy(body + PARAM_STORE_HEADER_BYTES, cfg, sizeof(*cfg));
    put32(body + 20, crc32(body, PARAM_STORE_BODY_BYTES));
}

bool param_store_save(ParamStoreState *state, const ParamStoreIo *io, ParamStoreBlob *cfg)
{
    Scan found;
    ParamStoreBlob next;
    uint8_t body[PARAM_STORE_BODY_BYTES], verify[PARAM_STORE_BODY_BYTES];
    uint8_t target;
    uint32_t generation, profile, offset;
    uint64_t word;
    Record committed;
    if (state == NULL || cfg == NULL || !io_valid(io) || !state->initialized) {
        if (state != NULL) state->last_error = PARAM_STORE_BAD_ARGUMENT;
        return false;
    }
    memcpy(&next, cfg, sizeof(next));
    param_store_seal(&next);
    if (!param_store_blob_valid(&next)) {
        state->last_error = PARAM_STORE_BAD_ARGUMENT; return false;
    }
    /* Rescan before every erase, including retries after an ambiguous marker
     * completion. Never trust stale RAM state to identify the surviving copy. */
    scan(io, &found);
    if (state->active_slot >= 0 && state->active_slot < 2 &&
        found.records[(unsigned)state->active_slot].read_error) {
        /* A failed re-read of the known active copy must not turn it into the
         * erase target. Reboot can explicitly choose a readable older copy. */
        state->last_error = PARAM_STORE_IO_ERROR; return false;
    }
    if (found.read_error && found.selected < 0 && !found.legacy) {
        state->last_error = PARAM_STORE_IO_ERROR; return false;
    }
    generation = 1u; profile = PARAM_STORE_PROFILE_REVISION;
    target = 0;
    if (found.selected >= 0) {
        const Record *active = &found.records[(unsigned)found.selected];
        target = (uint8_t)(1 - found.selected);
        generation = active->generation + 1u;
        if (active->profile != 0u) profile = active->profile;
    }
    next.write_count += 1u;
    param_store_seal(&next);
    make_body(body, &next, generation, profile);
    state->last_error = PARAM_STORE_IO_ERROR;
    if (!io->erase(io->ctx, target)) return false;
    if (!io->read(io->ctx, target, PARAM_STORE_COMMIT_OFFSET, &word, sizeof(word)) ||
        word != UINT64_MAX) return false;
    for (offset = 0; offset < PARAM_STORE_BODY_BYTES; offset += 8u) {
        memcpy(&word, body + offset, sizeof(word));
        if (!io->program(io->ctx, target, offset, word)) return false;
    }
    if (!io->read(io->ctx, target, 0, verify, sizeof(verify)) ||
        memcmp(body, verify, sizeof(body)) != 0) return false;
    /* A callback can fail after the physical marker completed. Reconcile by
     * reading the actual committed record instead of blindly rolling RAM back. */
    (void)io->program(io->ctx, target, PARAM_STORE_COMMIT_OFFSET, PARAM_STORE_COMMIT_MARKER);
    read_record(io, target, &committed);
    if (!committed.valid || committed.generation != generation || committed.profile != profile ||
        memcmp(&committed.cfg, &next, sizeof(next)) != 0) {
        state->last_error = committed.read_error ? PARAM_STORE_COMMIT_UNCERTAIN : PARAM_STORE_IO_ERROR;
        return false;
    }
    memcpy(cfg, &next, sizeof(*cfg));
    state->active_slot = (int8_t)target; state->legacy_active = false;
    state->generation = generation; state->profile_revision = profile;
    state->last_error = PARAM_STORE_OK;
    return true;
}

ParamStoreBootResult param_store_boot(ParamStoreState *state, const ParamStoreIo *io,
                                      ParamStoreBlob *out)
{
    ParamStoreBootResult result = { PARAM_STORE_SOURCE_DEFAULTS, false, false, false, false };
    Scan found;
    if (state == NULL || out == NULL || !io_valid(io)) {
        if (out != NULL) param_store_defaults(out);
        if (state != NULL) {
            memset(state, 0, sizeof(*state)); state->active_slot = -1;
            state->last_error = PARAM_STORE_BAD_ARGUMENT;
        }
        result.read_error = true; return result;
    }
    memset(state, 0, sizeof(*state)); state->active_slot = -1; state->initialized = true;
    scan(io, &found); result.read_error = found.read_error;
    if (found.selected >= 0) {
        const Record *active = &found.records[(unsigned)found.selected];
        memcpy(out, &active->cfg, sizeof(*out));
        state->active_slot = found.selected; state->generation = active->generation;
        state->profile_revision = active->profile;
        result.source = PARAM_STORE_SOURCE_JOURNAL;
    } else if (found.legacy) {
        memcpy(out, &found.legacy_cfg, sizeof(*out));
        state->active_slot = 1; state->legacy_active = true;
        result.source = PARAM_STORE_SOURCE_LEGACY;
    } else param_store_defaults(out);
    result.migration_needed = state->profile_revision == 0u;
    if (result.migration_needed) {
        apply_mounting(out); param_store_seal(out);
        /* Never turn a transient scan/ECC failure into a committed default
         * record that supersedes an unreadable calibrated record. Reboot or
         * call boot again after read recovery before accepting further saves. */
        if (found.read_error && found.selected < 0 && !found.legacy) {
            state->initialized = false;
            state->last_error = PARAM_STORE_IO_ERROR;
        } else result.migration_committed = param_store_save(state, io, out);
        result.write_error = !result.migration_committed;
    }
    return result;
}
