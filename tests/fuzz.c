// SPDX-License-Identifier: Apache-2.0
// libFuzzer driver for tests/fuzz.goose.
//
// The generated Goose C is compiled with -D_Exit=goose_fuzz_exit, so a Goose
// assertion or bounds failure ends in abort() instead of _Exit(). libFuzzer
// treats abort() as a crash and writes the exact triggering input to the
// artifact path, which is what makes a contract violation reproducible.
//
// This file is compiled *without* that define, so its own _Exit is the real
// one: the remap must not recurse.
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "msgpack-fuzz.h"

_Noreturn void goose_fuzz_exit(int status) {
    if (status != 0) abort();
    _Exit(status);
}

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    goose_init(*argc, *argv);
    atexit(goose_exit);
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size > INT64_MAX) return 0;
#ifdef GOOSE_FUZZ_SELF_TEST
    // Only the self-test build has this branch, so a campaign never pays for
    // it. It proves the assertion path reaches libFuzzer with the input kept.
    static const uint8_t probe[] = "libFuzzer Goose assertion bridge probe";
    if (size == sizeof(probe) - 1 && memcmp(data, probe, size) == 0)
        fuzz_assertion_probe(0);
#endif
    (void)fuzz_parse((sl_u8){(uint8_t *)data, (int64_t)size});
    return 0;
}
