#ifndef PARAM_STORE_STM32_H
#define PARAM_STORE_STM32_H

#include "param_store.h"

/* STM32G0C1RE only: two reserved logical 2KB pages, 0x0807F000/0x0807F800.
 * init checks factory flash size, HAL bank geometry and linker reservation.
 * It clears *io on failure. Call from thread mode; erase/program also require
 * interrupts enabled so the HAL timeout tick can run. No option bytes change.
 * The adapter serializes callbacks and rejects a changed bank mapping.
 */
bool param_store_stm32_init(ParamStoreIo *io);

/* Call FIRST from NMI_Handler; return from NMI only when this returns true.
 * Claims only a matching ECCD during one guarded parameter word read. CSS,
 * SRAM parity, other-bank/system-flash faults and all unguarded NMIs remain
 * unhandled, for the caller's existing fail-stop path. The failed slot is
 * quarantined in RAM until successfully erased; no NMI writes flash data.
 * This is not a general flash fault handler or proof of power-fail recovery.
 */
bool param_store_stm32_handle_nmi(void);

#endif
