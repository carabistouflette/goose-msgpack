/* SPDX-License-Identifier: Apache-2.0
 * A fixed-cost CPU workload, used as a contention probe.
 *
 * The point is not to measure anything about MessagePack. It is to answer one
 * question before a timing run: is the CPU this process is pinned to actually
 * free, and is its clock stable? A dependent chain of integer multiply-adds has
 * a cost that depends only on the core's clock and on whether something else is
 * competing for it, so its run-to-run dispersion is a direct contention signal.
 *
 *   cc -O2 bench/calibrate.c -o .build/bench/calibrate
 *   .build/bench/calibrate <iterations>
 *
 * Prints one line:
 *
 *   calibrate <iterations> <monotonic_ns> <thread_cpu_ns> <checksum>
 *
 * Both clocks are read around **the same loop**, so their ratio is the fraction
 * of the loop's wall time the thread actually got to run. That ratio is the
 * preemption signal. Measuring it from outside the process — parent wall time
 * against `wait4` CPU time — does not work: fork, exec and process teardown land
 * in both the numerator and the denominator, so a 4 ms workload with 1 ms of
 * startup reports a utilisation near 0.8 even on an idle core, and a 95% gate
 * built on it can never fire. The parent's rusage is still recorded, as
 * provenance, but it is not the gate.
 *
 * The checksum is folded into the output so the compiler cannot delete the
 * chain.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static uint64_t monotonic_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static uint64_t thread_cpu_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <iterations>\n", argv[0]);
        return 2;
    }
    long long iterations = atoll(argv[1]);
    if (iterations < 1) {
        fprintf(stderr, "calibrate: iterations must be positive\n");
        return 2;
    }

    /* A dependent chain: each step needs the previous result, so the cost is
     * latency-bound and cannot be hidden by instruction-level parallelism. */
    uint64_t x = 0x9e3779b97f4a7c15ull;

    /* Both clocks bracket the same loop, and nothing else. */
    uint64_t cpu_start = thread_cpu_ns();
    uint64_t wall_start = monotonic_ns();
    for (long long i = 0; i < iterations; i++) {
        x = x * 6364136223846793005ull + 1442695040888963407ull;
        x ^= x >> 29;
    }
    uint64_t wall_elapsed = monotonic_ns() - wall_start;
    uint64_t cpu_elapsed = thread_cpu_ns() - cpu_start;

    printf("calibrate %lld %llu %llu %llu\n", iterations,
           (unsigned long long)wall_elapsed,
           (unsigned long long)cpu_elapsed,
           (unsigned long long)x);
    return 0;
}
