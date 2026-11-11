/* Rung 5: FreeRTOS on the CLINT tick. One controller task runs the checks one after the
 * other and prints each result; the others exist for it to test. Every number printed is
 * in core clocks, taken from mtime. What each check proves:
 *
 *   tick       vTaskDelay(10) lasts 10 ticks of mtime: the CLINT compare, the port's tick
 *              interrupt and the compare update are right
 *   preempt    a task made ready by a higher-priority wake-up runs at once, before the
 *              giver goes on (a context switch out of an interrupt-free path)
 *   yield      two equal tasks yielding through ecall, which must take strict turns: the
 *              exception trap entry, the context save and restore, and what one switch
 *              costs
 *   queue      two tasks passing a counter through queues: blocking, wake-up and the
 *              kernel's own locking, and what a round trip costs
 *   mutex      priority inheritance: a low task holding a mutex runs ahead of a medium
 *              one while a high one waits for it (order L H M, not L M H)
 *   timer      a software timer of 2 ticks fires every other tick
 *   notify     task notifications from a higher-priority giver
 *   latency    from the compare match to the tick hook (mtime at the hook less the compare
 *              value it came for) while a busy task runs shifts, multiplies and divides,
 *              which hold the interrupt off the longest. It is the hardware's delay plus
 *              the port's entry: the 30-register save, the stack switch and the compare
 *              update all come before the hook
 *
 * Stops with PASS through syscon. A failed check prints FAIL and stops with 1. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "semphr.h"
#include "timers.h"
#include "soc.h"

#define FAIL(...) do { printf("FAIL: " __VA_ARGS__); printf("\n"); exit(1); } while (0)
#define CLK_PER_TICK (CLK_HZ / configTICK_RATE_HZ)

static uint32_t now(void) { return (uint32_t)mtime_read(); }

/* ── hooks the kernel wants ──────────────────────────────────────────────── */
void vAssertCalled(const char *file, int line)
{
    printf("\nASSERT %s:%d\n", file, line);
    soc_fail(0xA5);
}
void vApplicationMallocFailedHook(void) { printf("\nmalloc failed\n"); soc_fail(0xA6); }
void vApplicationStackOverflowHook(TaskHandle_t t, char *name)
{
    (void)t;
    printf("\nstack overflow in %s\n", name);
    soc_fail(0xA7);
}
void vApplicationIdleHook(void) { }

/* The port calls these for what it does not handle. */
void freertos_risc_v_application_exception_handler(uint32_t mcause, uint32_t a1, uint32_t a2)
{
    /* The port's arguments are mcause, mepc + 4 and nothing: read the CSRs themselves. */
    uint32_t epc, tval;
    (void)a1; (void)a2;
    __asm__ volatile("csrr %0, mepc" : "=r"(epc));
    __asm__ volatile("csrr %0, mtval" : "=r"(tval));
    printf("\nEXCEPTION mcause=%08x mepc=%08x mtval=%08x\n", (unsigned)mcause, (unsigned)epc, (unsigned)tval);
    soc_fail(0xA8);
}
void freertos_risc_v_application_interrupt_handler(uint32_t mcause)
{
    printf("\nINTERRUPT mcause=%08x\n", (unsigned)mcause);
    soc_fail(0xA9);
}

/* Compare match to tick hook: the compare has already moved on to the next tick when the hook
 * runs, so the one that fired was a tick earlier. */
static volatile uint32_t lat_on, lat_n, lat_max, lat_sum;
void vApplicationTickHook(void)
{
    if (!lat_on)
        return;
    uint32_t fired_for = *reg32(CLINT_MTIMECMP) - CLK_PER_TICK;
    uint32_t lat = now() - fired_for;
    if (lat > lat_max)
        lat_max = lat;
    lat_sum += lat;
    lat_n++;
}

/* ── the check tasks ─────────────────────────────────────────────────────── */
static char evlog[16];
static volatile int evn;
static void ev(char c)
{
    taskENTER_CRITICAL();
    evlog[evn++] = c;
    evlog[evn] = 0;
    taskEXIT_CRITICAL();
}

static SemaphoreHandle_t sem, mtx;
static TaskHandle_t ctl;

static void hi_waiter(void *arg)
{
    (void)arg;
    xSemaphoreTake(sem, portMAX_DELAY);
    ev('H');
    vTaskDelete(NULL);
}

static volatile uint32_t yields[2];
static volatile int yield_stop;
/* Which yielder made each of the first 64 counts, in order. */
static volatile uint8_t yield_order[64];
static volatile uint32_t yield_seq;
static void yielder(void *arg)
{
    uint32_t *mine = arg;
    while (!yield_stop) {
        (*mine)++;
        if (yield_seq < 64)
            yield_order[yield_seq++] = (uint8_t)(mine - yields);
        taskYIELD();
    }
    vTaskDelete(NULL);
}

static QueueHandle_t qa, qb;
static volatile int q_stop;
static void q_peer(void *arg)
{
    (void)arg;
    uint32_t v;
    while (xQueueReceive(qa, &v, portMAX_DELAY) == pdTRUE) {
        if (q_stop)
            break;
        v++;
        xQueueSend(qb, &v, portMAX_DELAY);
    }
    vTaskDelete(NULL);
}

static void low_task(void *arg)
{
    (void)arg;
    xSemaphoreTake(mtx, portMAX_DELAY);
    ev('L');
    TickType_t t0 = xTaskGetTickCount();
    while (xTaskGetTickCount() < t0 + 3)           /* hold the mutex across three ticks */
        ;
    xSemaphoreGive(mtx);
    vTaskDelete(NULL);
}
static void high_task(void *arg)
{
    (void)arg;
    vTaskDelay(1);
    xSemaphoreTake(mtx, portMAX_DELAY);
    ev('H');
    xSemaphoreGive(mtx);
    vTaskDelete(NULL);
}
static void med_task(void *arg)
{
    (void)arg;
    vTaskDelay(1);
    ev('M');
    vTaskDelete(NULL);
}

static volatile uint32_t timer_hits;
static void timer_cb(TimerHandle_t t) { (void)t; timer_hits++; }

static volatile uint32_t notified;
static void notify_worker(void *arg)
{
    (void)arg;
    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        notified++;
    }
}

/* Work that holds interrupts off: shifts, multiplies and divides. */
static volatile uint32_t sink;
static void busy_task(void *arg)
{
    (void)arg;
    uint32_t x = 12345;
    for (;;) {
        x = (x << 31) | (x >> 1);
        x = x * 2654435761u + 7;
        x = x / 3 + (x % 7);
        sink = x;
    }
}

static void controller(void *arg)
{
    (void)arg;
    uint32_t t0, t1;

    printf("FreeRTOS %s, tick %d Hz = %u clocks\n", tskKERNEL_VERSION_NUMBER, configTICK_RATE_HZ,
           (unsigned)CLK_PER_TICK);

    /* tick */
    uint32_t c0, c1;
    __asm__ volatile("csrr %0, mcycle" : "=r"(c0));
    t0 = now();
    vTaskDelay(10);
    t1 = now();
    __asm__ volatile("csrr %0, mcycle" : "=r"(c1));
    uint32_t dt = t1 - t0;
    printf("tick: vTaskDelay(10) took %u mtime ticks, %u mcycle clocks (%u per tick)\n", (unsigned)dt,
           (unsigned)(c1 - c0), (unsigned)(dt / 10));
    /* mtime is the core clock (boot contract rule 7): mcycle says how long the delay really was */
    if ((c1 - c0 > dt ? c1 - c0 - dt : dt - (c1 - c0)) * 100 > dt)
        FAIL("mtime and mcycle disagree: %u and %u", (unsigned)dt, (unsigned)(c1 - c0));
    if (dt < 9 * CLK_PER_TICK || dt > 11 * CLK_PER_TICK + 20000)
        FAIL("a 10-tick delay is %u clocks", (unsigned)dt);

    /* preempt */
    sem = xSemaphoreCreateBinary();
    xTaskCreate(hi_waiter, "hi", configMINIMAL_STACK_SIZE, NULL, 4, NULL);
    ev('a');                                      /* hi_waiter has already run and blocked */
    xSemaphoreGive(sem);
    ev('b');
    printf("preempt: order %s\n", evlog);
    if (strcmp(evlog, "aHb"))
        FAIL("order %s, want aHb", evlog);

    /* yield */
    yield_stop = 0;
    xTaskCreate(yielder, "y1", configMINIMAL_STACK_SIZE, (void *)&yields[0], 2, NULL);
    xTaskCreate(yielder, "y2", configMINIMAL_STACK_SIZE, (void *)&yields[1], 2, NULL);
    yields[0] = yields[1] = 0;
    yield_seq = 0;
    t0 = now();
    vTaskDelay(3);
    t1 = now();
    uint32_t y0 = yields[0], y1 = yields[1], y = y0 + y1;
    yield_stop = 1;
    vTaskDelay(1);
    printf("yield: %u + %u yields in %u clocks, %u clocks each\n", (unsigned)y0, (unsigned)y1,
           (unsigned)(t1 - t0), y ? (unsigned)((t1 - t0) / y) : 0);
    /* Two equal-priority tasks that each give the CPU up with ecall take strict turns, so the
     * order of the counts alternates. If the ecall did not switch, one task would count on
     * alone: and the tick's time slice would hand the CPU over only once a tick, so the
     * totals could still come out equal. Count the places where the order changes hands. */
    uint32_t seq = yield_seq, alt = 0;
    for (uint32_t i = 1; i < seq; i++)
        alt += yield_order[i] != yield_order[i - 1];
    printf("yield: the order changed hands %u times in the first %u\n", (unsigned)alt, (unsigned)seq);
    if (seq < 64 || alt * 10 < (seq - 1) * 9)
        FAIL("the yielders did not take turns (%u changes in %u)", (unsigned)alt, (unsigned)seq);

    /* queue */
    qa = xQueueCreate(1, sizeof(uint32_t));
    qb = xQueueCreate(1, sizeof(uint32_t));
    xTaskCreate(q_peer, "qpeer", configMINIMAL_STACK_SIZE, NULL, 2, NULL);
    uint32_t v = 0;
    enum { ROUNDS = 100 };
    t0 = now();
    for (int i = 0; i < ROUNDS; i++) {
        xQueueSend(qa, &v, portMAX_DELAY);
        xQueueReceive(qb, &v, portMAX_DELAY);
    }
    t1 = now();
    q_stop = 1;
    xQueueSend(qa, &v, portMAX_DELAY);
    printf("queue: %d round trips, %u clocks each, counter %u\n", ROUNDS, (unsigned)((t1 - t0) / ROUNDS), (unsigned)v);
    if (v != ROUNDS)
        FAIL("counter %u, want %d", (unsigned)v, ROUNDS);

    /* mutex with priority inheritance: L takes it, H waits for it, M would starve L */
    mtx = xSemaphoreCreateMutex();
    evn = 0;
    evlog[0] = 0;
    xTaskCreate(low_task, "low", configMINIMAL_STACK_SIZE, NULL, 1, NULL);
    vTaskDelay(1);                                /* L runs, takes the mutex */
    xTaskCreate(high_task, "high", configMINIMAL_STACK_SIZE, NULL, 4, NULL);
    xTaskCreate(med_task, "med", configMINIMAL_STACK_SIZE, NULL, 2, NULL);
    vTaskDelay(6);
    printf("mutex: order %s\n", evlog);
    if (strcmp(evlog, "LHM"))
        FAIL("order %s, want LHM", evlog);

    /* timer: 2 ticks, over 10 */
    TimerHandle_t tm = xTimerCreate("tm", 2, pdTRUE, NULL, timer_cb);
    timer_hits = 0;
    xTimerStart(tm, 0);
    vTaskDelay(10);
    xTimerStop(tm, 0);
    printf("timer: %u callbacks in 10 ticks\n", (unsigned)timer_hits);
    if (timer_hits < 4 || timer_hits > 5)
        FAIL("timer fired %u times", (unsigned)timer_hits);

    /* notify */
    TaskHandle_t nw;
    xTaskCreate(notify_worker, "notify", configMINIMAL_STACK_SIZE, NULL, 4, &nw);
    for (int i = 0; i < 5; i++)
        xTaskNotifyGive(nw);
    printf("notify: %u of 5 taken\n", (unsigned)notified);
    if (notified != 5)
        FAIL("notified %u", (unsigned)notified);
    vTaskDelete(nw);

    /* latency under load */
    xTaskCreate(busy_task, "busy", configMINIMAL_STACK_SIZE, NULL, 1, NULL);
    lat_max = lat_sum = lat_n = 0;
    lat_on = 1;
    vTaskDelay(20);
    lat_on = 0;
    printf("latency: compare match to the tick hook %u clocks at most, %u on average, over %u ticks\n", (unsigned)lat_max,
           lat_n ? (unsigned)(lat_sum / lat_n) : 0, (unsigned)lat_n);
    if (lat_n < 15 || lat_max > 20000)
        FAIL("latency max %u over %u ticks", (unsigned)lat_max, (unsigned)lat_n);

    printf("PASS\n");
    soc_pass();
}

extern void freertos_risc_v_trap_handler(void);

int main(void)
{
    uart_init(UART_DIVISOR);
    /* The port leaves mtvec to the application (boot contract rule 1: before anything can trap). */
    __asm__ volatile("csrw mtvec, %0" :: "r"(freertos_risc_v_trap_handler));
    if (xTaskCreate(controller, "ctl", 2 * configMINIMAL_STACK_SIZE, NULL, 3, &ctl) != pdPASS)
        FAIL("cannot create the controller");
    vTaskStartScheduler();
    FAIL("the scheduler returned");
    return 1;
}
