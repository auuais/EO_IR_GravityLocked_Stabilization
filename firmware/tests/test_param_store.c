#include "param_store.h"
#include <assert.h>
#include <setjmp.h>
#include <stdio.h>
#include <string.h>

typedef struct { char kind; uint8_t slot; uint32_t off; size_t length; } Operation;
typedef struct {
    uint8_t pages[2][PARAM_STORE_PAGE_BYTES];
    int32_t bad_word[2];
    bool ecc_latched[2];
    unsigned operations, fail_at, phase, partial_bytes;
    unsigned erases, programs;
    bool power_cut, failure_fired, fail_reads_after_marker;
    int protected_slot;
    Operation trace[128];
} Flash;

static Flash flash;
static jmp_buf power_return;
static unsigned fault_cases, corruption_cases;
static const uint8_t legacy_fixture[112] = {
    0x4d, 0x52, 0x41, 0x50, 0x03, 0x00, 0x70, 0x00, 0x2e, 0xb6, 0x6a, 0xcf, 0x14, 0xa1, 0xb2, 0xc3,
    0x64, 0x00, 0xd4, 0x17, 0x44, 0x2f, 0xb4, 0x46, 0x24, 0x5e, 0x94, 0x75, 0x0c, 0xfe, 0xf4, 0x01,
    0x0c, 0xfe, 0xf4, 0x01, 0x0c, 0xfe, 0xf4, 0x01, 0xff, 0xff, 0x02, 0x00, 0xfd, 0xff, 0x04, 0x00,
    0xfb, 0xff, 0x06, 0x00, 0x7b, 0x00, 0xfe, 0xca, 0x40, 0xe2, 0x01, 0x00, 0x8c, 0x23, 0xfc, 0x3a,
    0x6c, 0x52, 0xdc, 0x69, 0x4c, 0x81, 0xbc, 0x98, 0x0c, 0xfe, 0xf4, 0x01, 0x0c, 0xfe, 0xf4, 0x01,
    0x0c, 0xfe, 0xf4, 0x01, 0xff, 0xff, 0x02, 0x00, 0xfd, 0xff, 0x04, 0x00, 0xfb, 0xff, 0x06, 0x00,
    0x23, 0x00, 0xad, 0xbe, 0x47, 0x94, 0x03, 0x00, 0x07, 0x00, 0x00, 0x00, 0xef, 0xbe, 0xad, 0xde
}; /* Independent Python struct/zlib fixture: CRC32(mode..end)=0xcf6ab62e. */

static void clean_control(void)
{
    flash.operations = 0; flash.fail_at = 0; flash.phase = 0;
    flash.partial_bytes = 0; flash.erases = 0; flash.programs = 0;
    flash.power_cut = false; flash.failure_fired = false;
    flash.fail_reads_after_marker = false; flash.protected_slot = -1;
}

static void blank(void)
{
    memset(&flash, 0, sizeof(flash)); memset(flash.pages, 0xff, sizeof(flash.pages));
    flash.bad_word[0] = -1; flash.bad_word[1] = -1; clean_control();
}

static bool operation(char kind, uint8_t slot, uint32_t off, size_t len)
{
    Operation *item;
    assert(slot < 2u && off <= PARAM_STORE_PAGE_BYTES && len <= PARAM_STORE_PAGE_BYTES - off);
    assert(flash.operations < 128u);
    item = &flash.trace[flash.operations++];
    item->kind = kind; item->slot = slot; item->off = off; item->length = len;
    return flash.fail_at != 0u && flash.operations == flash.fail_at;
}

static bool fail_now(void)
{
    flash.failure_fired = true;
    if (flash.power_cut) longjmp(power_return, 1);
    return false;
}

static bool read_flash(void *ctx, uint8_t slot, uint32_t off, void *out, size_t len)
{
    bool hit = operation('r', slot, off, len);
    (void)ctx;
    if (hit && flash.phase == 0u) return fail_now();
    if (flash.ecc_latched[slot] || (flash.bad_word[slot] >= 0 &&
        (uint32_t)flash.bad_word[slot] >= off && (uint32_t)flash.bad_word[slot] < off + len)) {
        flash.ecc_latched[slot] = true; return false;
    }
    if (hit && flash.phase == 1u) {
        memcpy(out, flash.pages[slot] + off, len / 2u); return fail_now();
    }
    memcpy(out, flash.pages[slot] + off, len);
    return hit ? fail_now() : true;
}

static bool erase_flash(void *ctx, uint8_t slot)
{
    bool hit = operation('e', slot, 0, PARAM_STORE_PAGE_BYTES);
    (void)ctx;
    assert((int)slot != flash.protected_slot);
    if (hit && flash.phase == 0u) return fail_now();
    ++flash.erases;
    if (hit && flash.phase == 1u) {
        size_t length = flash.partial_bytes ? flash.partial_bytes : PARAM_STORE_PAGE_BYTES / 2u;
        memset(flash.pages[slot], 0xff, length); return fail_now();
    }
    memset(flash.pages[slot], 0xff, PARAM_STORE_PAGE_BYTES);
    flash.bad_word[slot] = -1; flash.ecc_latched[slot] = false;
    return hit ? fail_now() : true;
}

static bool program_flash(void *ctx, uint8_t slot, uint32_t off, uint64_t data)
{
    bool hit = operation('p', slot, off, 8);
    uint8_t bytes[8]; size_t i, count = 8;
    (void)ctx;
    assert((off & 7u) == 0u && (int)slot != flash.protected_slot);
    if (hit && flash.phase == 0u) return fail_now();
    memcpy(bytes, &data, sizeof(bytes)); ++flash.programs;
    if (hit && flash.phase == 1u) count = flash.partial_bytes ? flash.partial_bytes : 4u;
    for (i = 0; i < count; ++i) {
        assert((flash.pages[slot][off + i] & bytes[i]) == bytes[i]);
        flash.pages[slot][off + i] &= bytes[i];
    }
    if (hit && flash.phase == 1u) flash.bad_word[slot] = (int32_t)off;
    if (off == PARAM_STORE_COMMIT_OFFSET && flash.fail_reads_after_marker) {
        flash.ecc_latched[slot] = true; return false;
    }
    return hit ? fail_now() : true;
}

static const ParamStoreIo io = { NULL, read_flash, erase_flash, program_flash };

static bool same_metadata(const ParamStoreState *a, const ParamStoreState *b)
{
    return a->active_slot == b->active_slot && a->legacy_active == b->legacy_active &&
           a->initialized == b->initialized && a->generation == b->generation &&
           a->profile_revision == b->profile_revision;
}

static void check_mounts(const ParamStoreBlob *cfg)
{
    unsigned i;
    for (i = 0; i < 6u; ++i) {
        assert(cfg->eo.yaw_cd[i] == 6000u * i);
        assert(cfg->ir.yaw_cd[i] == 9000u + 6000u * i);
        assert(cfg->eo.pitch_cd[i] == 0 && cfg->eo.roll_cd[i] == 0);
        assert(cfg->ir.pitch_cd[i] == 0 && cfg->ir.roll_cd[i] == 0);
    }
    assert(cfg->ir.yaw_cd[5] == 39000u);
}

static void layout_and_validation(void)
{
    ParamStoreBlob cfg; ParamBankQ16 bank; unsigned mode;
    assert(sizeof(cfg) == 112u && sizeof(bank) == 44u);
    memcpy(&cfg, legacy_fixture, sizeof(cfg));
    assert(cfg.crc32 == UINT32_C(0xcf6ab62e) && param_store_blob_valid(&cfg));
    param_store_seal(&cfg); assert(memcmp(&cfg, legacy_fixture, sizeof(cfg)) == 0);
    for (mode = 0; mode < 256u; ++mode)
        assert(param_store_mode_valid((uint8_t)mode) == (mode <= 3u || (mode >= 6u && mode <= 21u)));
    param_store_defaults(&cfg); check_mounts(&cfg);
    assert(cfg.mode == 0x15u && cfg.eo.overlap_px == 100u && cfg.ir.overlap_px == 30u);
    assert(cfg.eo.feather_strength_q16 == 65536 && cfg.ir.feather_strength_q16 == 65536);
    memcpy(&bank, &cfg.eo, sizeof(bank)); bank.yaw_cd[5] = UINT16_MAX;
    bank.pitch_cd[0] = -500; bank.roll_cd[0] = 500; bank.overlap_px = 1920;
    bank.feather_strength_q16 = 6554; assert(param_store_bank_valid(&bank));
    bank.feather_strength_q16 = 6553; assert(!param_store_bank_valid(&bank));
    bank.feather_strength_q16 = 655360; assert(param_store_bank_valid(&bank));
    bank.feather_strength_q16 = 655361; assert(!param_store_bank_valid(&bank));
    bank.feather_strength_q16 = 65536; bank.pitch_cd[0] = -501; assert(!param_store_bank_valid(&bank));
    bank.pitch_cd[0] = 0; bank.roll_cd[0] = 501; assert(!param_store_bank_valid(&bank));
    bank.roll_cd[0] = 0; bank.overlap_px = 1921; assert(!param_store_bank_valid(&bank));
}

static void legacy_and_edits(void)
{
    ParamStoreBlob cfg, before, loaded; ParamStoreState state, reboot; ParamStoreBootResult result;
    unsigned i;
    blank(); memcpy(flash.pages[1], legacy_fixture, sizeof(legacy_fixture)); flash.protected_slot = 1;
    result = param_store_boot(&state, &io, &cfg);
    assert(result.source == PARAM_STORE_SOURCE_LEGACY && result.migration_committed);
    assert(state.active_slot == 0 && state.generation == 1 && state.profile_revision == PARAM_STORE_PROFILE_REVISION);
    check_mounts(&cfg);
    assert(memcmp(flash.pages[1], legacy_fixture, sizeof(legacy_fixture)) == 0);
    memcpy(&before, legacy_fixture, sizeof(before));
    assert(cfg.mode == before.mode && cfg.eo.overlap_px == before.eo.overlap_px && cfg.ir.overlap_px == before.ir.overlap_px);
    assert(cfg.eo.feather_strength_q16 == before.eo.feather_strength_q16 && cfg.ir.feather_strength_q16 == before.ir.feather_strength_q16);
    assert(memcmp(cfg.reserved0, before.reserved0, 3) == 0 && cfg.reserved1 == before.reserved1);
    assert(memcmp((const uint8_t *)&cfg + 54, legacy_fixture + 54, 2) == 0);
    assert(memcmp((const uint8_t *)&cfg + 98, legacy_fixture + 98, 2) == 0 && cfg.write_count == 8);
    for (i = 0; i < 6u; ++i) {
        clean_control(); flash.protected_slot = state.active_slot;
        cfg.eo.pitch_cd[i] = (int16_t)(101u + i); cfg.ir.roll_cd[i] = (int16_t)(-101 - (int)i);
        cfg.ir.yaw_cd[5] = (uint16_t)(39000u + i); cfg.mode = 7; cfg.reserved1 ^= 1u;
        assert(param_store_save(&state, &io, &cfg)); before = cfg;
        clean_control(); result = param_store_boot(&reboot, &io, &loaded);
        assert(result.source == PARAM_STORE_SOURCE_JOURNAL && !result.migration_needed);
        assert(flash.erases == 0 && flash.programs == 0 && memcmp(&loaded, &before, sizeof(loaded)) == 0);
        state = reboot; cfg = loaded;
    }
}

static void power_and_callback_failures(bool migration)
{
    Flash seed; ParamStoreState base_state, state, reboot;
    ParamStoreBlob old, desired, cfg, loaded, next;
    unsigned count, at, phase, power;
    blank();
    if (migration) {
        memcpy(flash.pages[1], legacy_fixture, sizeof(legacy_fixture));
        memset(&base_state, 0, sizeof(base_state));
        memcpy(&old, legacy_fixture, sizeof(old));
    } else {
        (void)param_store_boot(&base_state, &io, &old);
        old.eo.pitch_cd[0] = 123; assert(param_store_save(&base_state, &io, &old));
    }
    clean_control(); seed = flash; desired = old; desired.eo.roll_cd[1] = 321;
    if (migration) (void)param_store_boot(&state, &io, &cfg);
    else { state = base_state; cfg = desired; assert(param_store_save(&state, &io, &cfg)); }
    count = flash.operations; next = cfg;
    for (at = 1; at <= count; ++at) for (phase = 0; phase < 3u; ++phase) for (power = 0; power < 2u; ++power) {
        flash = seed; flash.fail_at = at; flash.phase = phase; flash.power_cut = power != 0u;
        flash.protected_slot = migration ? 1 : base_state.active_slot;
        state = base_state; cfg = desired;
        if (setjmp(power_return) == 0) {
            if (migration) (void)param_store_boot(&state, &io, &cfg);
            else {
                bool saved = param_store_save(&state, &io, &cfg);
                if (!saved) {
                    assert(same_metadata(&state, &base_state));
                    assert(memcmp(&cfg, &desired, sizeof(cfg)) == 0);
                }
            }
        }
        assert(flash.failure_fired);
        if (migration) assert(memcmp(flash.pages[1], legacy_fixture, sizeof(legacy_fixture)) == 0);
        else assert(memcmp(flash.pages[(unsigned)base_state.active_slot], seed.pages[(unsigned)base_state.active_slot], PARAM_STORE_PAGE_BYTES) == 0);
        clean_control();
        /* ECC from a partially programmed inactive doubleword may persist.
         * Boot must still use the good copy, and saving can reclaim the bad page. */
        (void)param_store_boot(&reboot, &io, &loaded);
        if (migration) {
            check_mounts(&loaded); assert(loaded.mode == 0x14 && loaded.reserved1 == UINT32_C(0xdeadbeef));
            assert(loaded.eo.overlap_px == 123 && loaded.ir.overlap_px == 35);
        } else assert(memcmp(&loaded, &old, sizeof(old)) == 0 || memcmp(&loaded, &next, sizeof(next)) == 0);
        ++fault_cases;
    }
}

static uint32_t independent_crc(const uint8_t *p, size_t len)
{
    uint32_t value = UINT32_MAX; size_t i; unsigned b;
    for (i = 0; i < len; ++i) { value ^= p[i]; for (b = 0; b < 8u; ++b)
        value = (value & 1u) ? (value >> 1) ^ UINT32_C(0xEDB88320) : value >> 1; }
    return value ^ UINT32_MAX;
}

static void change_header(uint8_t slot, uint32_t generation, uint32_t profile)
{
    uint32_t crc, zero = 0;
    memcpy(flash.pages[slot] + 8, &generation, 4); memcpy(flash.pages[slot] + 12, &profile, 4);
    memcpy(flash.pages[slot] + 20, &zero, 4);
    crc = independent_crc(flash.pages[slot], PARAM_STORE_BODY_BYTES);
    memcpy(flash.pages[slot] + 20, &crc, 4);
}

static void corrupt_and_wrap(void)
{
    Flash seed; ParamStoreState state; ParamStoreBlob old, newer, loaded; unsigned byte, bit;
    blank(); (void)param_store_boot(&state, &io, &old); newer = old;
    newer.eo.pitch_cd[0] = 234; assert(param_store_save(&state, &io, &newer));
    assert(state.active_slot == 1); clean_control(); seed = flash;
    for (byte = 0; byte < PARAM_STORE_COMMIT_OFFSET + 8u; ++byte) for (bit = 0; bit < 8u; ++bit) {
        flash = seed; flash.pages[1][byte] ^= (uint8_t)(1u << bit);
        (void)param_store_boot(&state, &io, &loaded);
        assert(state.active_slot == 0 && memcmp(&loaded, &old, sizeof(old)) == 0);
        assert(flash.erases == 0 && flash.programs == 0); ++corruption_cases;
    }
    flash = seed; change_header(0, UINT32_MAX, PARAM_STORE_PROFILE_REVISION);
    change_header(1, 0, PARAM_STORE_PROFILE_REVISION);
    (void)param_store_boot(&state, &io, &loaded); assert(state.active_slot == 1 && state.generation == 0);
    clean_control(); assert(param_store_save(&state, &io, &loaded)); assert(state.active_slot == 0 && state.generation == 1);
    flash = seed; change_header(0, 17, PARAM_STORE_PROFILE_REVISION); change_header(1, 17, PARAM_STORE_PROFILE_REVISION);
    (void)param_store_boot(&state, &io, &loaded); assert(state.active_slot == 0);
    flash = seed; change_header(0, 0, PARAM_STORE_PROFILE_REVISION); change_header(1, UINT32_C(0x80000000), PARAM_STORE_PROFILE_REVISION);
    (void)param_store_boot(&state, &io, &loaded); assert(state.active_slot == 0);
    /* Unmarked v4 migrates once; any nonzero profile preserves edits. */
    flash = seed; change_header(1, 2, 0); clean_control();
    assert(param_store_boot(&state, &io, &loaded).migration_committed); check_mounts(&loaded);
    flash = seed; change_header(1, 2, UINT32_C(0x12345678)); clean_control();
    assert(!param_store_boot(&state, &io, &loaded).migration_needed);
    assert(loaded.eo.pitch_cd[0] == 234 && flash.programs == 0);
}

static void ecc_and_ambiguous_commit(void)
{
    ParamStoreState state, previous; ParamStoreBlob cfg, old, loaded; ParamStoreBootResult boot;
    blank(); (void)param_store_boot(&state, &io, &cfg); old = cfg;
    flash.bad_word[1] = PARAM_STORE_COMMIT_OFFSET; clean_control();
    boot = param_store_boot(&state, &io, &loaded);
    assert(boot.read_error && !boot.migration_needed && state.active_slot == 0);
    loaded.ir.roll_cd[0] = -123; clean_control(); flash.protected_slot = 0;
    assert(param_store_save(&state, &io, &loaded)); assert(state.active_slot == 1 && !flash.ecc_latched[1]);
    /* Newer committed page becomes unreadable: reboot selects older slot0;
     * a later edit safely reclaims slot1 instead of permanently blocking. */
    clean_control(); flash.bad_word[1] = PARAM_STORE_COMMIT_OFFSET;
    boot = param_store_boot(&state, &io, &loaded);
    assert(boot.read_error && state.active_slot == 0 && memcmp(&loaded, &old, sizeof(old)) == 0);
    clean_control(); loaded.eo.roll_cd[4] = 222; flash.protected_slot = 0;
    assert(param_store_save(&state, &io, &loaded) && state.active_slot == 1);
    /* The same recovery is allowed on first migration, with the exact legacy
     * page as survivor even if the inactive page has a torn ECC doubleword. */
    blank(); memcpy(flash.pages[1], legacy_fixture, sizeof(legacy_fixture));
    flash.bad_word[0] = PARAM_STORE_COMMIT_OFFSET; flash.protected_slot = 1;
    boot = param_store_boot(&state, &io, &loaded);
    assert(boot.read_error && boot.migration_committed && state.active_slot == 0);
    assert(memcmp(flash.pages[1], legacy_fixture, sizeof(legacy_fixture)) == 0);
    /* All copies unreadable: defaults in RAM only, no destructive recovery. */
    blank(); flash.bad_word[0] = 144; flash.bad_word[1] = 144;
    boot = param_store_boot(&state, &io, &loaded);
    assert(boot.read_error && boot.write_error && !state.initialized && flash.erases == 0);
    check_mounts(&loaded); assert(!param_store_save(&state, &io, &loaded));
    /* Uncommitted body's ECC must not be read merely to discover a record. */
    blank(); (void)param_store_boot(&state, &io, &cfg); clean_control(); flash.bad_word[1] = 0;
    boot = param_store_boot(&state, &io, &loaded);
    assert(!boot.read_error && !flash.ecc_latched[1]);
    /* Final marker completion is real but verification unavailable. */
    clean_control(); previous = state; old = cfg; cfg.eo.pitch_cd[0] = 111;
    flash.fail_reads_after_marker = true;
    assert(!param_store_save(&state, &io, &cfg));
    assert(state.last_error == PARAM_STORE_COMMIT_UNCERTAIN && same_metadata(&state, &previous));
    assert(cfg.write_count == old.write_count);
    clean_control(); flash.ecc_latched[1] = false;
    /* Retry without reboot: rescan selects physically committed slot1 and
     * writes slot0, never erasing the just-committed survivor. */
    flash.protected_slot = 1;
    assert(param_store_save(&state, &io, &cfg)); assert(state.active_slot == 0 && state.generation == 3);
}

static void failed_migration_retry(void)
{
    ParamStoreState state, reboot; ParamStoreBlob cfg, loaded; ParamStoreBootResult boot;
    unsigned at, erase_at = 0;
    blank(); memcpy(flash.pages[1], legacy_fixture, sizeof(legacy_fixture));
    (void)param_store_boot(&state, &io, &cfg);
    for (at = 0; at < flash.operations; ++at)
        if (flash.trace[at].kind == 'e') { erase_at = at + 1u; break; }
    assert(erase_at != 0u);
    blank(); memcpy(flash.pages[1], legacy_fixture, sizeof(legacy_fixture));
    flash.fail_at = erase_at; boot = param_store_boot(&state, &io, &cfg);
    assert(boot.write_error && !boot.migration_committed && state.legacy_active);
    check_mounts(&cfg);
    cfg.eo.pitch_cd[2] = 345; /* UI edit after failed persistence must survive. */
    clean_control(); flash.protected_slot = 1;
    assert(param_store_save(&state, &io, &cfg));
    clean_control(); boot = param_store_boot(&reboot, &io, &loaded);
    assert(!boot.migration_needed && loaded.eo.pitch_cd[2] == 345 && flash.programs == 0);
    /* Failed migration read: no defaults commit, then a fresh boot can recover. */
    blank(); memcpy(flash.pages[1], legacy_fixture, sizeof(legacy_fixture));
    flash.fail_at = 3; /* legacy read, after both marker probes */
    boot = param_store_boot(&state, &io, &cfg);
    assert(boot.read_error && boot.write_error && !state.initialized && flash.erases == 0);
    clean_control(); boot = param_store_boot(&state, &io, &cfg);
    assert(boot.source == PARAM_STORE_SOURCE_LEGACY && boot.migration_committed);
    assert(cfg.reserved1 == UINT32_C(0xdeadbeef));
}

static void commit_and_erase_boundaries(void)
{
    static const unsigned erase_cuts[] = { 1u, 143u, 144u, 147u, 151u, 152u, 2047u };
    Flash seed; ParamStoreState base, state; ParamStoreBlob cfg, old, desired, loaded;
    unsigned marker_op = 0, erase_op = 0, i;
    blank(); (void)param_store_boot(&base, &io, &old);
    old.eo.pitch_cd[0] = 10; assert(param_store_save(&base, &io, &old));
    clean_control(); seed = flash; desired = old; desired.eo.pitch_cd[0] = 20;
    state = base; cfg = desired; assert(param_store_save(&state, &io, &cfg));
    for (i = 0; i < flash.operations; ++i) {
        if (flash.trace[i].kind == 'e') erase_op = i + 1u;
        if (flash.trace[i].kind == 'p' && flash.trace[i].off == PARAM_STORE_COMMIT_OFFSET) marker_op = i + 1u;
    }
    assert(marker_op != 0u && erase_op != 0u);
    /* False return after the complete physical marker MUST be reconciled as
     * success, so callers never roll RAM back from a verifiable new record. */
    flash = seed; flash.fail_at = marker_op; flash.phase = 2;
    state = base; cfg = desired; assert(param_store_save(&state, &io, &cfg));
    assert(flash.failure_fired && state.active_slot != base.active_slot && cfg.write_count == old.write_count + 1u);
    ++fault_cases;
    for (i = 1; i < 8u; ++i) {
        flash = seed; flash.fail_at = marker_op; flash.phase = 1; flash.partial_bytes = i;
        flash.protected_slot = base.active_slot; state = base; cfg = desired;
        assert(!param_store_save(&state, &io, &cfg) && same_metadata(&state, &base));
        clean_control(); (void)param_store_boot(&state, &io, &loaded);
        assert(memcmp(&loaded, &old, sizeof(old)) == 0); ++fault_cases;
    }
    for (i = 0; i < sizeof(erase_cuts) / sizeof(erase_cuts[0]); ++i) {
        flash = seed; flash.fail_at = erase_op; flash.phase = 1; flash.partial_bytes = erase_cuts[i];
        flash.protected_slot = base.active_slot; state = base; cfg = desired;
        assert(!param_store_save(&state, &io, &cfg) && same_metadata(&state, &base));
        clean_control(); (void)param_store_boot(&state, &io, &loaded);
        assert(memcmp(&loaded, &old, sizeof(old)) == 0); ++fault_cases;
    }
}

static void invalid_and_blank(void)
{
    ParamStoreIo invalid = { 0 }; ParamStoreState state; ParamStoreBlob cfg; ParamStoreBootResult result;
    unsigned bad;
    memset(&state, 0xa5, sizeof(state)); memset(&cfg, 0xa5, sizeof(cfg));
    result = param_store_boot(&state, &invalid, &cfg);
    assert(result.read_error && !state.initialized && state.active_slot == -1);
    check_mounts(&cfg); assert(param_store_blob_valid(&cfg) && !param_store_save(&state, &invalid, &cfg));
    for (bad = 0; bad < 5u; ++bad) {
        blank(); memcpy(&cfg, legacy_fixture, sizeof(cfg));
        if (bad == 0u) cfg.magic ^= 1u;
        if (bad == 1u) cfg.crc32 ^= 1u;
        if (bad == 2u) { cfg.mode = 5; param_store_seal(&cfg); }
        if (bad == 3u) { cfg.eo.pitch_cd[0] = 501; param_store_seal(&cfg); }
        if (bad == 4u) { cfg.ir.feather_strength_q16 = 6553; param_store_seal(&cfg); }
        memcpy(flash.pages[1], &cfg, sizeof(cfg)); result = param_store_boot(&state, &io, &cfg);
        assert(result.source == PARAM_STORE_SOURCE_DEFAULTS && result.migration_committed);
        check_mounts(&cfg); assert(cfg.mode == 0x15 && cfg.write_count == 1);
    }
    blank(); result = param_store_boot(&state, &io, &cfg);
    assert(result.source == PARAM_STORE_SOURCE_DEFAULTS && result.migration_committed && state.active_slot == 0);
    clean_control(); assert(!param_store_boot(&state, &io, &cfg).migration_needed);
    assert(flash.erases == 0 && flash.programs == 0);
}

static void profile_json(void)
{
    ParamStoreBlob cfg; unsigned family, i;
    param_store_defaults(&cfg);
    printf("{\"profile_revision\":%u,\"mode\":%u", (unsigned)PARAM_STORE_PROFILE_REVISION, (unsigned)cfg.mode);
    for (family = 0; family < 2u; ++family) {
        const ParamBankQ16 *bank = family ? &cfg.ir : &cfg.eo;
        printf(",\"%s\":{\"yaw_cd\":[", family ? "ir" : "eo");
        for (i = 0; i < 6u; ++i) printf("%s%u", i ? "," : "", (unsigned)bank->yaw_cd[i]);
        printf("],\"pitch_cd\":[");
        for (i = 0; i < 6u; ++i) printf("%s%d", i ? "," : "", (int)bank->pitch_cd[i]);
        printf("],\"roll_cd\":[");
        for (i = 0; i < 6u; ++i) printf("%s%d", i ? "," : "", (int)bank->roll_cd[i]);
        printf("],\"overlap_px\":%u,\"feather_strength_q16\":%d}",
               (unsigned)bank->overlap_px, (int)bank->feather_strength_q16);
    }
    puts("}");
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--profile-json") == 0) { profile_json(); return 0; }
    layout_and_validation(); legacy_and_edits();
    power_and_callback_failures(false); power_and_callback_failures(true);
    corrupt_and_wrap(); ecc_and_ambiguous_commit(); failed_migration_retry();
    commit_and_erase_boundaries(); invalid_and_blank();
    printf("PASS param_store: %u operation interruption/failure cases; %u record bit flips; legacy ABI, migration, UI preservation, ECC recovery, commit ambiguity and generation wrap\n", fault_cases, corruption_cases);
    return 0;
}
