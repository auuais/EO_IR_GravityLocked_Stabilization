#ifndef PARAM_STORE_STM32_MOCK_H
#define PARAM_STORE_STM32_MOCK_H
#include <stdint.h>

/* Transport-only substitute for the target HAL/registers. The production
 * adapter, including all validation and ECC decisions, is compiled unchanged. */
typedef struct { volatile uint32_t SR, OPTR, ECCR, ECC2R; } MockFlash;
typedef struct { volatile uint32_t CIFR; } MockRcc;
typedef struct { volatile uint32_t CFGR2; } MockSyscfg;
extern MockFlash mock_flash;
extern MockRcc mock_rcc;
extern MockSyscfg mock_syscfg;
extern uint32_t mock_flash_bytes, mock_sales, mock_primask, mock_ipsr;
extern uintptr_t mock_link_start, mock_link_end;
#define FLASH (&mock_flash)
#define RCC (&mock_rcc)
#define SYSCFG (&mock_syscfg)
#define FLASH_BASE UINT32_C(0x08000000)
#define FLASH_SIZE mock_flash_bytes
#define FLASH_PAGE_SIZE 2048u
#define FLASH_OPTR_nSWAP_BANK UINT32_C(0x00100000)
#define FLASH_OPTR_DUAL_BANK UINT32_C(0x00200000)
/* Same density/DUAL_BANK expression as the vendored HAL. */
#define FLASH_BANK_NB (((mock_sales == 0u) || ((mock_sales == 1u) && ((FLASH->OPTR & FLASH_OPTR_DUAL_BANK) == 0u))) ? 1u : 2u)
#define FLASH_BANK_SIZE ((FLASH_BANK_NB == 1u) ? FLASH_SIZE : (FLASH_SIZE >> 1u))
#define FLASH_BANK_1 UINT32_C(0x00000004)
#define FLASH_BANK_2 UINT32_C(0x00008000)
#define FLASH_ECCR_ADDR_ECC UINT32_C(0x00007FFF)
#define FLASH_ECCR_SYSF_ECC UINT32_C(0x00100000)
#define FLASH_ECCR_ECCCIE UINT32_C(0x01000000)
#define FLASH_ECCR_ECCC UINT32_C(0x40000000)
#define FLASH_ECCR_ECCD UINT32_C(0x80000000)
#define FLASH_SR_EOP UINT32_C(0x00000001)
#define FLASH_SR_OPTVERR UINT32_C(0x00008000)
#define FLASH_SR_BSY1 UINT32_C(0x00010000)
#define FLASH_SR_BSY2 UINT32_C(0x00020000)
#define FLASH_SR_CFGBSY UINT32_C(0x00040000)
#define FLASH_SR_ERRORS UINT32_C(0x0000C3FA)
#define RCC_CIFR_CSSF UINT32_C(0x00000100)
#define RCC_CIFR_LSECSSF UINT32_C(0x00000200)
#define SYSCFG_CFGR2_SPF UINT32_C(0x00000100)
#define FLASH_TYPEERASE_PAGES 0u
#define FLASH_TYPEPROGRAM_DOUBLEWORD 1u

typedef enum { HAL_OK, HAL_ERROR, HAL_BUSY, HAL_TIMEOUT } HAL_StatusTypeDef;
typedef struct { uint32_t TypeErase, Banks, Page, NbPages; } FLASH_EraseInitTypeDef;
HAL_StatusTypeDef HAL_FLASH_Unlock(void);
HAL_StatusTypeDef HAL_FLASH_Lock(void);
HAL_StatusTypeDef HAL_FLASHEx_Erase(FLASH_EraseInitTypeDef *erase, uint32_t *page_error);
HAL_StatusTypeDef HAL_FLASH_Program(uint32_t type, uint32_t address, uint64_t data);
uint32_t mock_read_word(uint32_t address);
void mock_write_ecc(volatile uint32_t *reg, uint32_t value);
void mock_clear_sr(uint32_t value);
void param_store_stm32_test_reset(void);
#define STORE_LINK_START mock_link_start
#define STORE_LINK_END mock_link_end
#define STORE_READ_WORD(address) mock_read_word(address)
#define STORE_WRITE_ECC(reg, value) mock_write_ecc((reg), (value))
#define STORE_CLEAR_SR(value) mock_clear_sr(value)
#define __get_IPSR() mock_ipsr
#define __get_PRIMASK() mock_primask
#define __disable_irq() ((void)(mock_primask = 1u))
#define __set_PRIMASK(value) ((void)(mock_primask = (value)))
#define __DSB() ((void)0)
#define __ISB() ((void)0)
#endif
