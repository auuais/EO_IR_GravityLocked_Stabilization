#include "param_store_stm32.h"
#include "param_store_stm32_mock.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

MockFlash mock_flash;
MockRcc mock_rcc;
MockSyscfg mock_syscfg;
uint32_t mock_flash_bytes, mock_sales, mock_primask, mock_ipsr;
uintptr_t mock_link_start, mock_link_end;
static uint8_t memory[4096];
static ParamStoreIo io;
static unsigned checks, unlock_calls, lock_calls, erase_calls, program_calls, read_calls, ecc_clears;
static uint32_t last_program_address, last_program_type, last_ecc_write;
static uint64_t last_program_data;
static FLASH_EraseInitTypeDef last_erase;
static HAL_StatusTypeDef unlock_result, lock_result, erase_result, program_result;
static uint32_t erase_error;
static unsigned inject_kind;
static bool nmi_claimed, recursive_rejected;
#define CHECK(expr) do { ++checks; if (!(expr)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expr); exit(1); } } while (0)

static void reset_mock(uint32_t swap, uint32_t dual)
{
    param_store_stm32_test_reset();
    memset(&mock_flash, 0, sizeof(mock_flash));
    memset(&mock_rcc, 0, sizeof(mock_rcc));
    memset(&mock_syscfg, 0, sizeof(mock_syscfg));
    memset(memory, 0xFF, sizeof(memory));
    memset(&io, 0, sizeof(io));
    mock_flash_bytes = 512u * 1024u;
    mock_sales = 2u;
    mock_link_start = UINT32_C(0x0807F000);
    mock_link_end = UINT32_C(0x08080000);
    mock_flash.OPTR = (swap ? FLASH_OPTR_nSWAP_BANK : 0u) | (dual ? FLASH_OPTR_DUAL_BANK : 0u);
    mock_primask = mock_ipsr = 0u;
    unlock_calls = lock_calls = erase_calls = program_calls = read_calls = ecc_clears = 0u;
    unlock_result = lock_result = erase_result = program_result = HAL_OK;
    erase_error = UINT32_MAX;
    inject_kind = 0u;
    nmi_claimed = recursive_rejected = false;
    CHECK(param_store_stm32_init(&io));
}

HAL_StatusTypeDef HAL_FLASH_Unlock(void) { ++unlock_calls; return unlock_result; }
HAL_StatusTypeDef HAL_FLASH_Lock(void) { ++lock_calls; return lock_result; }
HAL_StatusTypeDef HAL_FLASHEx_Erase(FLASH_EraseInitTypeDef *erase, uint32_t *page_error)
{
    ++erase_calls;
    last_erase = *erase;
    *page_error = erase_error;
    if (erase_result == HAL_OK && erase_error == UINT32_MAX)
        memset(memory + (erase->Page - 126u) * 2048u, 0xFF, 2048u);
    return erase_result;
}
HAL_StatusTypeDef HAL_FLASH_Program(uint32_t type, uint32_t address, uint64_t data)
{
    ++program_calls;
    last_program_type = type;
    last_program_address = address;
    last_program_data = data;
    if (program_result == HAL_OK) memcpy(memory + address - UINT32_C(0x0807F000), &data, 8u);
    return program_result;
}
void mock_write_ecc(volatile uint32_t *reg, uint32_t value)
{
    const uint32_t flags = FLASH_ECCR_ECCC | FLASH_ECCR_ECCD;
    ++ecc_clears;
    last_ecc_write = value;
    *reg = (*reg & ~flags & ~FLASH_ECCR_ECCCIE) | (*reg & flags & ~value) | (value & FLASH_ECCR_ECCCIE);
}
void mock_clear_sr(uint32_t value) { FLASH->SR &= ~value; }

/* kind1 exact ECCD;2 ECCC;3 wrong bank;4 wrong word;5 SYSF;6 other bank
 * pending too;7 HSE CSS;8 LSE CSS;9 SRAM parity;10 both error classes;
 * 11 no ECC flag;12 recursive callback;13 ECCD on second32;14 ECCC second32. */
uint32_t mock_read_word(uint32_t address)
{
    uint32_t value, dw = ((address - FLASH_BASE) % UINT32_C(0x40000)) / 8u;
    volatile uint32_t *own = (FLASH->OPTR & FLASH_OPTR_nSWAP_BANK) ? &FLASH->ECC2R : &FLASH->ECCR;
    volatile uint32_t *other = (own == &FLASH->ECCR) ? &FLASH->ECC2R : &FLASH->ECCR;
    unsigned kind = inject_kind;
    ++read_calls;
    CHECK(mock_primask == 1u);
    CHECK(address >= UINT32_C(0x0807F000) && address <= UINT32_C(0x0807FFFC));
    CHECK((address & 3u) == 0u);
    memcpy(&value, memory + address - UINT32_C(0x0807F000), 4u);
    if ((kind == 13u || kind == 14u) && (address & 4u) == 0u) return value;
    inject_kind = 0u;
    if (kind == 12u) {
        uint32_t temp;
        recursive_rejected = !io.read(io.ctx, 0u, 0u, &temp, sizeof(temp));
        return value;
    }
    if (kind == 0u) return value;
    *own = FLASH_ECCR_ECCCIE | dw | ((kind == 2u || kind == 14u) ? FLASH_ECCR_ECCC : FLASH_ECCR_ECCD);
    if (kind == 3u) { *other = *own; *own = FLASH_ECCR_ECCCIE; }
    if (kind == 4u) *own ^= 1u;
    if (kind == 5u) *own |= FLASH_ECCR_SYSF_ECC;
    if (kind == 6u) *other = dw | FLASH_ECCR_ECCD;
    if (kind == 7u) RCC->CIFR = RCC_CIFR_CSSF;
    if (kind == 8u) RCC->CIFR = RCC_CIFR_LSECSSF;
    if (kind == 9u) SYSCFG->CFGR2 = SYSCFG_CFGR2_SPF;
    if (kind == 10u) *own |= FLASH_ECCR_ECCC;
    if (kind == 11u) *own = dw;
    if (kind != 2u && kind != 14u) {
        mock_ipsr = 2u;
        nmi_claimed = param_store_stm32_handle_nmi();
        mock_ipsr = 0u;
        /* An unclaimed hardware NMI never returns from the caller's fail-stop
         * handler. Returning in this MOCK only permits assertions of no clear. */
    }
    return value;
}

static void test_mapping(void)
{
    uint32_t swap, dual;
    for (swap = 0u; swap < 2u; ++swap) for (dual = 0u; dual < 2u; ++dual) {
        uint8_t slot;
        reset_mock(swap, dual);
        for (slot = 0u; slot < 2u; ++slot) {
            uint64_t result = 0u;
            const uint64_t pattern = UINT64_C(0x0123456789ABCDEF);
            CHECK(io.erase(io.ctx, slot));
            CHECK(last_erase.TypeErase == FLASH_TYPEERASE_PAGES);
            CHECK(last_erase.Banks == (swap ? FLASH_BANK_2 : FLASH_BANK_1));
            CHECK(last_erase.Page == 126u + slot && last_erase.NbPages == 1u);
            CHECK(io.program(io.ctx, slot, 2040u, pattern));
            CHECK(last_program_type == FLASH_TYPEPROGRAM_DOUBLEWORD);
            CHECK(last_program_address == UINT32_C(0x0807F000) + slot * 2048u + 2040u);
            CHECK(last_program_data == pattern);
            CHECK(io.read(io.ctx, slot, 2040u, &result, sizeof(result)));
            CHECK(result == pattern);
        }
        CHECK(unlock_calls == 4u && lock_calls == 4u);
    }
}

static void test_geometry_and_bounds(void)
{
    uint32_t word;
    ParamStoreIo invalid;
    unsigned kind;
    for (kind = 0u; kind < 7u; ++kind) {
        reset_mock(1u, 1u);
        if (kind == 0u) mock_flash_bytes = 256u * 1024u;
        if (kind == 1u) mock_flash_bytes = 128u * 1024u;
        if (kind == 2u) mock_sales = 0u;
        if (kind == 3u) mock_link_start -= 2048u;
        if (kind == 4u) mock_link_end += 2048u;
        if (kind == 5u) FLASH->SR = FLASH_SR_OPTVERR;
        if (kind == 6u) FLASH->OPTR ^= FLASH_OPTR_nSWAP_BANK;
        CHECK(!io.erase(io.ctx, 0u));
        CHECK(!io.program(io.ctx, 0u, 0u, 0u));
        CHECK(!io.read(io.ctx, 0u, 0u, &word, 4u));
        memset(&invalid, 0xA5, sizeof(invalid));
        CHECK(!param_store_stm32_init(&invalid));
        CHECK(invalid.ctx == NULL && invalid.read == NULL && invalid.erase == NULL && invalid.program == NULL);
        CHECK(unlock_calls == 0u && lock_calls == 0u && read_calls == 0u);
    }
    reset_mock(1u, 1u);
    CHECK(!param_store_stm32_init(NULL));
    CHECK(!io.erase(io.ctx, 2u));
    CHECK(!io.program(io.ctx, 2u, 0u, 0u));
    CHECK(!io.program(io.ctx, 0u, 1u, 0u));
    CHECK(!io.program(io.ctx, 0u, 2041u, 0u));
    CHECK(!io.program(io.ctx, 0u, UINT32_MAX, 0u));
    CHECK(!io.read(io.ctx, 2u, 0u, &word, 4u));
    CHECK(!io.read(io.ctx, 0u, 2047u, &word, 2u));
    CHECK(!io.read(io.ctx, 0u, UINT32_MAX, &word, 1u));
    CHECK(!io.read(io.ctx, 0u, 0u, &word, SIZE_MAX));
    CHECK(!io.read(io.ctx, 0u, 0u, NULL, 1u));
    CHECK(!io.read(NULL, 0u, 0u, &word, 4u));
    CHECK(io.read(io.ctx, 0u, 2048u, NULL, 0u));
    CHECK(unlock_calls == 0u && read_calls == 0u);
    mock_ipsr = 16u;
    CHECK(!io.read(io.ctx, 0u, 0u, &word, 4u));
    CHECK(!io.erase(io.ctx, 0u));
    mock_ipsr = 0u;
    mock_primask = 1u;
    CHECK(!io.erase(io.ctx, 0u));
    CHECK(!io.program(io.ctx, 0u, 0u, 0u));
    CHECK(io.read(io.ctx, 0u, 0u, &word, 4u));
    CHECK(mock_primask == 1u);
}

static void test_reads(void)
{
    uint8_t result[31];
    uint32_t i;
    reset_mock(1u, 1u);
    for (i = 0u; i < sizeof(memory); ++i) memory[i] = (uint8_t)i;
    CHECK(io.read(io.ctx, 0u, 1u, result, sizeof(result)));
    CHECK(memcmp(result, memory + 1u, sizeof(result)) == 0);
    CHECK(io.read(io.ctx, 1u, 2017u, result, sizeof(result)));
    CHECK(memcmp(result, memory + 2048u + 2017u, sizeof(result)) == 0);
    CHECK(mock_primask == 0u);
    inject_kind = 12u;
    CHECK(io.read(io.ctx, 0u, 0u, result, 4u));
    CHECK(recursive_rejected);
}

static void test_hal_failures(void)
{
    unsigned kind;
    for (kind = 0u; kind < 4u; ++kind) {
        reset_mock(1u, 1u);
        if (kind == 0u) unlock_result = HAL_ERROR;
        if (kind == 1u) erase_result = HAL_TIMEOUT;
        if (kind == 2u) lock_result = HAL_ERROR;
        if (kind == 3u) erase_error = 126u;
        CHECK(!io.erase(io.ctx, 0u));
        CHECK(unlock_calls == 1u && lock_calls == 1u);
        CHECK(erase_calls == (kind == 0u ? 0u : 1u));
    }
    for (kind = 0u; kind < 3u; ++kind) {
        reset_mock(1u, 1u);
        if (kind == 0u) unlock_result = HAL_ERROR;
        if (kind == 1u) program_result = HAL_TIMEOUT;
        if (kind == 2u) lock_result = HAL_ERROR;
        CHECK(!io.program(io.ctx, 0u, 0u, 0u));
        CHECK(unlock_calls == 1u && lock_calls == 1u);
        CHECK(program_calls == (kind == 0u ? 0u : 1u));
    }
    for (kind = 0u; kind < 3u; ++kind) {
        reset_mock(1u, 1u);
        FLASH->SR = kind == 0u ? FLASH_SR_BSY1 : (kind == 1u ? FLASH_SR_BSY2 : FLASH_SR_CFGBSY);
        CHECK(!io.erase(io.ctx, 0u));
        CHECK(unlock_calls == 0u && lock_calls == 0u);
    }
}

static void test_ecc(void)
{
    uint64_t result;
    uint32_t swap, kind;
    for (swap = 0u; swap < 2u; ++swap) for (kind = 1u; kind <= 14u; ++kind) {
        bool read_ok;
        unsigned calls;
        if (kind == 12u) continue;
        reset_mock(swap, 0u);
        result = UINT64_C(0x123456789ABCDEF0);
        inject_kind = kind;
        read_ok = io.read(io.ctx, 0u, 144u, &result, sizeof(result));
        CHECK(read_ok == (kind == 11u));
        CHECK(mock_primask == 0u);
        CHECK(nmi_claimed == (kind == 1u || kind == 13u));
        CHECK(ecc_clears == ((kind == 1u || kind == 2u || kind == 13u || kind == 14u) ? 1u : 0u));
        CHECK(!param_store_stm32_handle_nmi());
        if (kind == 1u || kind == 2u || kind == 13u || kind == 14u) {
            CHECK(last_ecc_write == (FLASH_ECCR_ECCCIE | ((kind == 2u || kind == 14u) ? FLASH_ECCR_ECCC : FLASH_ECCR_ECCD)));
            CHECK(read_calls == (kind >= 13u ? 2u : 1u));
            calls = read_calls;
            CHECK(!io.read(io.ctx, 0u, 0u, &result, 8u));
            CHECK(read_calls == calls); /* no buffered reread of suspect slot */
            CHECK(param_store_stm32_init(&io));
            CHECK(!io.read(io.ctx, 0u, 0u, &result, 8u));
            CHECK(read_calls == calls); /* re-init must not clear quarantine */
            CHECK(!io.program(io.ctx, 0u, 0u, 0u));
            CHECK(io.read(io.ctx, 1u, 0u, &result, 8u));
            erase_result = HAL_ERROR;
            CHECK(!io.erase(io.ctx, 0u));
            CHECK(!io.read(io.ctx, 0u, 0u, &result, 8u));
            erase_result = HAL_OK;
            CHECK(io.erase(io.ctx, 0u));
            CHECK(io.read(io.ctx, 0u, 0u, &result, 8u));
            CHECK(result == UINT64_MAX);
        }
    }
    reset_mock(1u, 1u);
    FLASH->ECC2R = FLASH_ECCR_ECCD | UINT32_C(0x7E12);
    CHECK(!param_store_stm32_handle_nmi());
    CHECK(!io.read(io.ctx, 0u, 144u, &result, 8u));
    CHECK(read_calls == 0u && ecc_clears == 0u);
    FLASH->ECC2R = FLASH_ECCR_ECCC | UINT32_C(0x7E12);
    CHECK(!io.read(io.ctx, 0u, 144u, &result, 8u));
    CHECK(read_calls == 0u && ecc_clears == 0u);
    reset_mock(1u, 1u);
    inject_kind = 1u;
    CHECK(!io.read(io.ctx, 1u, 2040u, &result, 8u));
    CHECK(nmi_claimed && ecc_clears == 1u);
    CHECK(!io.read(io.ctx, 1u, 0u, &result, 8u));
    CHECK(io.read(io.ctx, 0u, 0u, &result, 8u));
    lock_result = HAL_ERROR;
    CHECK(!io.erase(io.ctx, 1u));
    CHECK(!io.read(io.ctx, 1u, 0u, &result, 8u));
    lock_result = HAL_OK;
    CHECK(io.erase(io.ctx, 1u));
    CHECK(io.read(io.ctx, 1u, 0u, &result, 8u));
}

int main(void)
{
    test_mapping();
    test_geometry_and_bounds();
    test_reads();
    test_hal_failures();
    test_ecc();
    printf("PASS: STM32 parameter adapter (%u checks). Host mocks only; no physical flash/NMI qualification.\n", checks);
    return 0;
}
