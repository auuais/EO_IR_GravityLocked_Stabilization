# Historical calibration storage review — 2026-10-16

The user selected one-time INI mounting migration on 2026-10-19. The resulting
two-page journal, linker reservation, flash adapter and UI compatibility change
are described in [GRAVITY_CALIBRATION_STORAGE.md](../GRAVITY_CALIBRATION_STORAGE.md).
The review below describes the original source before those changes and is
retained as historical evidence, not the current implementation status.

Read-only review on 2026-10-16 of the copied MCU source. The requested choice
between retaining stored calibration and applying the selected mounting profile
once is still pending. No parameter defaults, persistent layout, save policy,
flash erase behavior or linker reservation was changed by this review.

## Current source contract

`firmware/eo_osd_remote/Core/Src/mcu_fsm.c:379` defines a 44-byte ParamBankQ16
(including two bytes of alignment before feather strength). The packed v3
ParamStoreBlob at line 387 is 112 bytes: header through offset 11, mode at 12,
EO bank at 16, IR bank at 60, write_count at 104, reserved1 at 108. The magic is
`0x5041524D` and version is 3. CRC32 covers offset 12 through the end, including
reserved fields. Validation checks magic, exact version/length, valid mode,
pitch/roll bounds, overlap, feather strength and CRC.

`cfg_flash_address` at line 443 selects the final 2 KB of the device-reported
flash size. `cfg_save_to_flash` at line 545 erases that single page, programs
14 doublewords in increasing address order, then reads back and validates.
There is no second record, transactional commit word or fallback copy. A reset
during erase/program can invalidate the only record; next boot then initializes
all defaults. This conclusion follows from source, not a power-interruption test.

Boot at line 1099 loads the record, saves defaults if invalid, then forces mode
`0x15` and saves again for every valid load. Thus current boot behavior already
changes persisted mode and rewrites flash every boot. UI mode and bank saves
replace the same record. In-memory rollback after an unsuccessful save cannot
restore a page already erased.

The flash linker script still declares all 512 KB as executable FLASH; it does
not reserve the final parameter page. The current image is only about 71 KB, so
there is no observed overlap in this build. A future image-growth guard is needed
before relying on reserved parameter pages.

The copied HAL describes 2 KB pages and bank-relative page indices in
`Drivers/STM32G0xx_HAL_Driver/Inc/stm32g0xx_hal_flash.h:891`. G0C1 supports
runtime-dependent bank organization. The existing save routine leaves the erase
`Banks` field at zero and calculates a global page index; the HAL's
`FLASH_PageErase` uses an explicit bank selector and validates a per-bank page
range. This is a source-level mismatch requiring explicit bank/page calculation
and verification before modifying persistence. No conclusion is made about the
currently programmed device's option bytes or observed erase behavior.

## Proposed once-only mounting update, if selected

Preserve the entire valid loaded configuration and replace only the six yaw,
pitch and roll arrays in each camera bank. Preserve overlap, feather, mode and
all other unrelated fields. Record a specific mounting-profile revision inside
the CRC-covered persisted record. Future UI bank/mode edits must retain that
revision; later boots must not reapply the initial profile when it is present.
The current reserved1 field can carry such a marker without changing v3 size,
but adding only a marker does not resolve single-page power-failure loss.

For a power-failure-safe migration, a separate implementation should reserve two
flash pages and use a versioned journal with generation, profile revision, CRC
and a separate aligned doubleword commit marker written last. It should read
legacy v3 first and write the first migrated record into the other page, leaving
the legacy record untouched until the new record is fully validated. Subsequent
saves alternate pages and never erase the only committed copy. On restart, use
the newest fully committed valid record; an incomplete write leaves the previous
record available. Use explicit runtime bank and bank-relative page calculations,
and reserve the pages in the linker script. Test interruptions at every erase,
program and commit boundary with a host flash model before considering hardware.

The migration itself should not silently change the existing boot-mode policy.
The desire to preserve mode during migration and the inherited force-EO boot
policy must be resolved explicitly when that implementation is scoped. None of
this journal or policy proposal is part of the currently verified control change.
