#include "param_store_stm32.h"

#ifdef PARAM_STORE_STM32_TEST
#include "param_store_stm32_mock.h"
#else
#include "stm32g0xx_hal.h"
#if !defined(STM32G0C1xx) || !defined(FLASH_DBANK_SUPPORT)
#error "Parameter store requires the STM32G0C1RE 512KB dual-bank target"
#endif
extern uint8_t __param_store_start__;
extern uint8_t __param_store_end__;
#define STORE_LINK_START ((uintptr_t)&__param_store_start__)
#define STORE_LINK_END ((uintptr_t)&__param_store_end__)
#define STORE_READ_WORD(address) (*(volatile const uint32_t *)(uintptr_t)(address))
#define STORE_WRITE_ECC(reg, value) (*(reg) = (value))
#define STORE_CLEAR_SR(value) (FLASH->SR = (value))
#endif

#define STORE_START UINT32_C(0x0807F000)
#define STORE_END UINT32_C(0x08080000)
#define STORE_FLASH_BYTES UINT32_C(0x80000)
#define STORE_BANK_BYTES UINT32_C(0x40000)
#define ECC_FLAGS (FLASH_ECCR_ECCC | FLASH_ECCR_ECCD)

_Static_assert(PARAM_STORE_PAGE_BYTES == 2048u, "Journal page size mismatch");
_Static_assert(FLASH_PAGE_SIZE == 2048u, "Target page size mismatch");

typedef struct {
    bool initialized;
    uint32_t swap_option;
    volatile uint32_t busy;
    volatile uint32_t bad_slots;
    volatile uint32_t read_active;
    volatile uint32_t read_fault;
    volatile uint32_t read_bank;
    volatile uint32_t read_dw;
    volatile uint32_t read_slot;
} StoreHardware;

static StoreHardware hardware;

static bool geometry_valid(void)
{
    /* RM0444 table 12: 512KB is ALWAYS dual-bank, even if DUAL_BANK=0.
     * The vendored HAL derives FLASH_BANK_NB from density + DUAL_BANK. */
    return FLASH_SIZE == STORE_FLASH_BYTES && FLASH_BANK_NB == 2u &&
           FLASH_BANK_SIZE == STORE_BANK_BYTES &&
           STORE_LINK_START == STORE_START && STORE_LINK_END == STORE_END &&
           (FLASH->SR & FLASH_SR_OPTVERR) == 0u;
}

static bool other_nmi_pending(void)
{
    return (RCC->CIFR & (RCC_CIFR_CSSF | RCC_CIFR_LSECSSF)) != 0u ||
           (SYSCFG->CFGR2 & SYSCFG_CFGR2_SPF) != 0u;
}

static bool ecc_pending(void)
{
    return ((FLASH->ECCR | FLASH->ECC2R) & ECC_FLAGS) != 0u;
}

static bool begin_operation(void *ctx)
{
    uint32_t primask;
    bool ready;
    if (ctx != &hardware || __get_IPSR() != 0u) return false;
    primask = __get_PRIMASK();
    __disable_irq();
    ready = hardware.initialized && !hardware.busy && geometry_valid() &&
            (FLASH->OPTR & FLASH_OPTR_nSWAP_BANK) == hardware.swap_option &&
            (FLASH->SR & (FLASH_SR_BSY1 | FLASH_SR_BSY2 | FLASH_SR_CFGBSY)) == 0u &&
            !ecc_pending() && !other_nmi_pending();
    if (ready) hardware.busy = 1u;
    __set_PRIMASK(primask);
    return ready;
}

static bool range_valid(uint8_t slot, uint32_t offset, size_t length)
{
    return slot < 2u && offset <= PARAM_STORE_PAGE_BYTES &&
           length <= PARAM_STORE_PAGE_BYTES - offset;
}

/* All reserved addresses are in the upper LOGICAL half. Erase and ECC bank
 * registers identify PHYSICAL banks; program/read addresses stay logical.
 * nSWAP=1: upper half is bank 2; nSWAP=0: upper half is bank 1. */
static uint32_t physical_bank(void)
{
    return hardware.swap_option != 0u ? FLASH_BANK_2 : FLASH_BANK_1;
}

static bool claim_read_ecc(bool nmi)
{
    volatile uint32_t *reg;
    uint32_t own, other, flags;
    if (!hardware.read_active || other_nmi_pending()) return false;
    if (hardware.read_bank == FLASH_BANK_1) {
        reg = &FLASH->ECCR;
        own = FLASH->ECCR;
        other = FLASH->ECC2R;
    } else {
        reg = &FLASH->ECC2R;
        own = FLASH->ECC2R;
        other = FLASH->ECCR;
    }
    flags = own & ECC_FLAGS;
    /* Two simultaneously asserted classes are ambiguous because an ECC
     * register freezes its address until the pending flags are cleared. */
    if ((other & ECC_FLAGS) != 0u ||
        flags != (nmi ? FLASH_ECCR_ECCD : FLASH_ECCR_ECCC) ||
        (own & FLASH_ECCR_SYSF_ECC) != 0u ||
        (own & FLASH_ECCR_ADDR_ECC) != hardware.read_dw) return false;

    hardware.read_fault = 1u;
    hardware.bad_slots |= 1u << hardware.read_slot;
    /* W1C only the accepted event; preserve ECCCIE. Do not use an RMW that
     * could clear an unrelated flag. ADDR_ECC/SYSF_ECC are read-only. */
    STORE_WRITE_ECC(reg, (own & FLASH_ECCR_ECCCIE) | flags);
    __DSB();
    __ISB();
    return true;
}

bool param_store_stm32_handle_nmi(void)
{
    return claim_read_ecc(true);
}

static bool read_word(uint8_t slot, uint32_t address, uint32_t *out)
{
    uint32_t primask = __get_PRIMASK();
    uint32_t value;
    bool ok;
    __disable_irq();
    if (ecc_pending() || other_nmi_pending()) {
        __set_PRIMASK(primask);
        return false;
    }
    hardware.read_bank = physical_bank();
    hardware.read_dw = ((address - FLASH_BASE) % STORE_BANK_BYTES) / 8u;
    hardware.read_slot = slot;
    hardware.read_fault = 0u;
    hardware.read_active = 1u;
    __DSB();
    __ISB();
    value = STORE_READ_WORD(address);
    __DSB();
    __ISB();
    /* Single-bit corrections are conservatively rejected too. The matching
     * double-bit NMI sets read_fault before execution resumes here. */
    (void)claim_read_ecc(false);
    ok = hardware.read_fault == 0u && !ecc_pending() && !other_nmi_pending();
    hardware.read_active = 0u;
    __DSB();
    __set_PRIMASK(primask);
    if (ok) *out = value;
    return ok;
}

static bool store_read(void *ctx, uint8_t slot, uint32_t offset, void *out, size_t length)
{
    uint8_t *dst = out;
    uint32_t address;
    bool ok = true;
    if (!range_valid(slot, offset, length) || (out == NULL && length != 0u) ||
        !begin_operation(ctx)) return false;
    if ((hardware.bad_slots & (1u << slot)) != 0u) {
        hardware.busy = 0u;
        return false;
    }
    address = STORE_START + slot * PARAM_STORE_PAGE_BYTES + offset;
    while (length != 0u) {
        uint32_t word, start = address & 3u;
        size_t take = 4u - start;
        size_t i;
        if (take > length) take = length;
        if (!read_word(slot, address & ~UINT32_C(3), &word)) { ok = false; break; }
        for (i = 0u; i < take; ++i) dst[i] = (uint8_t)(word >> (8u * (start + (uint32_t)i)));
        dst += take;
        length -= take;
        address += (uint32_t)take;
    }
    hardware.busy = 0u;
    return ok;
}

static bool store_erase(void *ctx, uint8_t slot)
{
    FLASH_EraseInitTypeDef erase = {0};
    uint32_t page_error = UINT32_MAX;
    HAL_StatusTypeDef status, lock_status;
    if (slot >= 2u || __get_PRIMASK() != 0u || !begin_operation(ctx)) return false;
    erase.TypeErase = FLASH_TYPEERASE_PAGES;
    erase.Banks = physical_bank();
    erase.Page = 126u + slot;
    erase.NbPages = 1u;
    status = HAL_FLASH_Unlock();
    if (status == HAL_OK) {
        STORE_CLEAR_SR(FLASH_SR_ERRORS | FLASH_SR_EOP);
        status = HAL_FLASHEx_Erase(&erase, &page_error);
    }
    lock_status = HAL_FLASH_Lock();
    if (status == HAL_OK && page_error == UINT32_MAX && lock_status == HAL_OK)
        hardware.bad_slots &= ~(1u << slot);
    hardware.busy = 0u;
    return status == HAL_OK && page_error == UINT32_MAX && lock_status == HAL_OK;
}

static bool store_program(void *ctx, uint8_t slot, uint32_t offset, uint64_t data)
{
    HAL_StatusTypeDef status, lock_status;
    if (!range_valid(slot, offset, 8u) || (offset & 7u) != 0u ||
        __get_PRIMASK() != 0u || !begin_operation(ctx)) return false;
    if ((hardware.bad_slots & (1u << slot)) != 0u) {
        hardware.busy = 0u;
        return false;
    }
    status = HAL_FLASH_Unlock();
    if (status == HAL_OK) {
        STORE_CLEAR_SR(FLASH_SR_ERRORS | FLASH_SR_EOP);
        status = HAL_FLASH_Program(FLASH_TYPEPROGRAM_DOUBLEWORD,
                                  STORE_START + slot * PARAM_STORE_PAGE_BYTES + offset, data);
    }
    lock_status = HAL_FLASH_Lock();
    hardware.busy = 0u;
    return status == HAL_OK && lock_status == HAL_OK;
}

bool param_store_stm32_init(ParamStoreIo *io)
{
    if (io == NULL) return false;
    *io = (ParamStoreIo){0};
    if (__get_IPSR() != 0u || hardware.busy || !geometry_valid()) return false;
    if (hardware.initialized &&
        hardware.swap_option != (FLASH->OPTR & FLASH_OPTR_nSWAP_BANK)) return false;
    hardware.swap_option = FLASH->OPTR & FLASH_OPTR_nSWAP_BANK;
    hardware.initialized = true;
    io->ctx = &hardware;
    io->read = store_read;
    io->erase = store_erase;
    io->program = store_program;
    return true;
}

#ifdef PARAM_STORE_STM32_TEST
void param_store_stm32_test_reset(void)
{
    hardware = (StoreHardware){0};
}
#endif
