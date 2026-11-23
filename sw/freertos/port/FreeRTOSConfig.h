/* FreeRTOS on AlphaOneSoC (docs/ROADMAP.md 9.2, rung 5): the upstream RISC-V port
 * (portable/GCC/RISC-V, the RV32I_CLINT_no_extensions chip file), M-mode only, the CLINT's
 * mtime as the tick source. The tick comes from mtime, which counts core clocks, so the
 * clock goes in here as it is documented (62.5 MHz, ROADMAP section 0). */
#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#include <stdint.h>

#define configCPU_CLOCK_HZ                   62500000UL
#define configMTIME_BASE_ADDRESS             0x0200BFF8UL
#define configMTIMECMP_BASE_ADDRESS          0x02004000UL

/* 100 Hz: the tick interrupt is a few hundred instructions at about 40 clocks each from
 * PSRAM (the hook is reached after about 6,000 clocks, see freertos_test.c), so a 1 kHz
 * tick, 62,500 clocks apart, would take well over a tenth of the CPU. */
#define configTICK_RATE_HZ                   100
#define configUSE_PREEMPTION                 1
#define configUSE_TIME_SLICING               1
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 0
#define configMAX_PRIORITIES                 5
#define configMINIMAL_STACK_SIZE             256
#define configISR_STACK_SIZE_WORDS           512
#define configMAX_TASK_NAME_LEN              12
#define configTICK_TYPE_WIDTH_IN_BITS        TICK_TYPE_WIDTH_32_BITS
#define configIDLE_SHOULD_YIELD              1

#define configSUPPORT_STATIC_ALLOCATION      0
#define configSUPPORT_DYNAMIC_ALLOCATION     1
#define configTOTAL_HEAP_SIZE                (96 * 1024)
#define configAPPLICATION_ALLOCATED_HEAP     0

#define configUSE_MUTEXES                    1
#define configUSE_RECURSIVE_MUTEXES          0
#define configUSE_COUNTING_SEMAPHORES        1
#define configUSE_TASK_NOTIFICATIONS         1
#define configUSE_TIMERS                     1
#define configTIMER_TASK_PRIORITY            (configMAX_PRIORITIES - 1)
#define configTIMER_QUEUE_LENGTH             8
#define configTIMER_TASK_STACK_DEPTH         configMINIMAL_STACK_SIZE
#define configQUEUE_REGISTRY_SIZE            0

#define configUSE_IDLE_HOOK                  1
#define configUSE_TICK_HOOK                  1
#define configUSE_MALLOC_FAILED_HOOK         1
#define configCHECK_FOR_STACK_OVERFLOW       2
#define configUSE_TRACE_FACILITY             0
#define configGENERATE_RUN_TIME_STATS        0

void vAssertCalled(const char *file, int line);
#define configASSERT(x)                      do { if (!(x)) vAssertCalled(__FILE__, __LINE__); } while (0)

#define INCLUDE_vTaskDelay                   1
#define INCLUDE_vTaskDelayUntil              1
#define INCLUDE_vTaskDelete                  1
#define INCLUDE_vTaskPrioritySet             1
#define INCLUDE_uxTaskPriorityGet            1
#define INCLUDE_xTaskGetSchedulerState       1
#define INCLUDE_xTaskGetCurrentTaskHandle    1
#define INCLUDE_xTimerPendFunctionCall       0
#define INCLUDE_vTaskSuspend                 1

#endif
