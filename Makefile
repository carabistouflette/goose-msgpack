GOOSE ?= .toolchain/goose/build/goose
CC ?= gcc
SANITIZER_CC ?= gcc
ORACLE_CASES ?= 100000
BENCH_SAMPLES ?= 20
BENCH_BATCH ?= 64
BENCH_MS ?= 200
FUZZ_SECONDS ?= 120
FUZZ_RUNS ?= 100000
MUTATE_CASES ?= 20000
OUTPUT ?= .build/results.json
.NOTPARALLEL:
.PHONY: setup format check test test-debug sanitize bench bench-build bench-mpack bench-mpack-sanitize thirdparty triangulate fuzz mutate

setup:
	./scripts/setup-goose.sh

format:
	"$(GOOSE)" format msgpack.goose tests examples bench

check:
	"$(GOOSE)" format --check msgpack.goose tests examples bench
	"$(GOOSE)" check msgpack.goose
	"$(GOOSE)" check tests/api.goose
	"$(GOOSE)" check tests/oracle.goose
	"$(GOOSE)" check examples/plan.goose
	"$(GOOSE)" check bench/bench.goose
	python3 -m py_compile tests/oracle.py tests/wire.py tests/triangulate.py tests/fetch-thirdparty.py scripts/sanitize.py scripts/quickstart.py bench/measure.py bench/paired.py bench/contention.py bench/fixtures.py bench/fetch.py bench/build-baseline.py
	python3 tests/wire.py
	python3 tests/triangulate.py --selftest
	python3 bench/paired.py --selftest
	python3 bench/contention.py --selftest
	git diff --check

test:
	mkdir -p .build
	"$(GOOSE)" run tests/api.goose
	python3 tests/oracle.py --goose "$(abspath $(GOOSE))" --cases $(ORACLE_CASES) --output .build/oracle.json
	"$(GOOSE)" build tests/api.goose --standalone --cc "$(CC)" -O2 -o .build/api
	./.build/api
	"$(GOOSE)" build tests/oracle.goose --standalone --cc "$(CC)" -O2 -o .build/oracle
	python3 tests/oracle.py --binary .build/oracle --cases $(ORACLE_CASES) --output .build/oracle-native.json
	"$(GOOSE)" run examples/plan.goose
	"$(GOOSE)" build examples/plan.goose --standalone --cc "$(CC)" -O2 -o .build/plan
	./.build/plan
	python3 scripts/quickstart.py --goose "$(abspath $(GOOSE))"

test-debug:
	mkdir -p .build
	"$(GOOSE)" run tests/api.goose --debug
	python3 tests/oracle.py --goose "$(abspath $(GOOSE))" --debug --cases $(ORACLE_CASES) --output .build/oracle-debug.json
	"$(GOOSE)" build tests/api.goose --standalone --debug --cc "$(CC)" -o .build/api-debug
	./.build/api-debug
	"$(GOOSE)" run examples/plan.goose --debug
	python3 scripts/quickstart.py --goose "$(abspath $(GOOSE))" --debug

sanitize:
	python3 scripts/sanitize.py --goose "$(abspath $(GOOSE))" --cc "$(SANITIZER_CC)" --cases $(ORACLE_CASES) --output "$(OUTPUT)"

# Prepared, not measured. The benchmark operator runs `make bench` serially so no other
# process competes for the CPU. `bench-build` only compiles, and is safe in CI.
bench-build:
	python3 bench/fixtures.py --check
	python3 bench/fetch.py
	"$(GOOSE)" build bench/bench.goose --standalone --cc "$(CC)" -O2 -o .build/bench/msgpack-bench
	"$(GOOSE)" build bench/bench-competitor.goose --standalone --cc "$(CC)" -O2 -o .build/bench/msgpack-bench-competitor
	python3 bench/provenance.py record --binary .build/bench/msgpack-bench \
		--cc "$(CC)" --flags=-O2 --source msgpack.goose --source bench/bench.goose
	python3 bench/provenance.py record --binary .build/bench/msgpack-bench-competitor \
		--cc "$(CC)" --flags=-O2 --source msgpack.goose --source bench/bench-competitor.goose

# The MPack reference. Built twice: once as a plain -O2 compile, and once with
# the production macros stated explicitly, so the two can be shown to be the
# same configuration rather than assumed to be. `macros` prints the effective
# values and `budget-selftest` proves the contract column's budgets fire.
MPACK_SRC = .build/thirdparty/mpack/src
MPACK_CFLAGS = -O2 -std=gnu11 -DMPACK_EXTENSIONS=1 -Wall -Wextra -I $(MPACK_SRC)
MPACK_OBJS = $(MPACK_SRC)/mpack/mpack-common.c $(MPACK_SRC)/mpack/mpack-expect.c \
	$(MPACK_SRC)/mpack/mpack-node.c $(MPACK_SRC)/mpack/mpack-platform.c \
	$(MPACK_SRC)/mpack/mpack-reader.c $(MPACK_SRC)/mpack/mpack-writer.c

bench-mpack: thirdparty
	$(CC) $(MPACK_CFLAGS) bench/bench-mpack.c $(MPACK_OBJS) -o .build/bench/msgpack-bench-mpack
	$(CC) $(MPACK_CFLAGS) -DNDEBUG -DMPACK_DEBUG=0 -DMPACK_READ_TRACKING=0 \
		-DMPACK_WRITE_TRACKING=0 bench/bench-mpack.c $(MPACK_OBJS) \
		-o .build/bench/msgpack-bench-mpack-prod
	.build/bench/msgpack-bench-mpack macros
	.build/bench/msgpack-bench-mpack budget-selftest
	.build/bench/msgpack-bench-mpack safety-selftest
	.build/bench/msgpack-bench-mpack-prod budget-selftest
	python3 bench/provenance.py record --binary .build/bench/msgpack-bench-mpack \
		--cc "$(CC)" --flags="-O2 -std=gnu11 -DMPACK_EXTENSIONS=1" \
		--source bench/bench-mpack.c

# The comparator harness under AddressSanitizer and UndefinedBehaviorSanitizer.
# The five fixtures contain no bin and no ext, so the 35 verify rows never reach
# the bin/ext payload path; `safety-selftest` decodes truncated bin/ext/str
# payloads from exactly-sized buffers so an overrun lands on a redzone. Clang is
# used because gcc 16's libubsan needs a libstdc++ symbol this link does not pull
# in.
MPACK_SAN_CFLAGS = -O1 -g -std=gnu11 -DMPACK_EXTENSIONS=1 -Wall -Wextra \
	-I $(MPACK_SRC) -fsanitize=address,undefined -fno-omit-frame-pointer \
	-fno-sanitize-recover=all
bench-mpack-sanitize: thirdparty
	env -u LD_LIBRARY_PATH clang $(MPACK_SAN_CFLAGS) bench/bench-mpack.c \
		$(MPACK_OBJS) -o .build/bench/msgpack-bench-mpack-asan
	ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 UBSAN_OPTIONS=print_stacktrace=1 \
		.build/bench/msgpack-bench-mpack-asan safety-selftest
	ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 UBSAN_OPTIONS=print_stacktrace=1 \
		.build/bench/msgpack-bench-mpack-asan verify
	ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 UBSAN_OPTIONS=print_stacktrace=1 \
		.build/bench/msgpack-bench-mpack-asan budget-selftest

bench: bench-build
	GOOSE="$(abspath $(GOOSE))" python3 bench/measure.py --samples $(BENCH_SAMPLES) --batch $(BENCH_BATCH) --ms $(BENCH_MS)

# Third-party triangulation: msgpack-c, pinned, as an independent correctness
# oracle. Not part of `make test`: it clones a repository and builds a C
# library. `make triangulate` is the gate; it fails on any unclassified
# disagreement.
thirdparty:
	python3 tests/fetch-thirdparty.py

triangulate: thirdparty
	python3 tests/wire.py
	python3 tests/triangulate.py --selftest
	python3 tests/triangulate.py --goose "$(abspath $(GOOSE))" --cc "$(CC)"

# Coverage-guided fuzzing of the real Goose API, with the negative controls that
# prove the target can fail. Not part of `make test`: it takes minutes.
fuzz:
	python3 scripts/fuzz.py --goose "$(abspath $(GOOSE))" --seconds $(FUZZ_SECONDS) --runs $(FUZZ_RUNS) \
		--seed 20261107 --seed 20261108 \
		--defect no-input-budget --defect no-utf8-check --defect no-output-budget \
		--defect no-array-truncation --defect no-node-budget --defect no-depth-budget \
		--defect no-str-budget --defect asan-overread \
		--output .build/fuzz/results.json

# One targeted defect at a time, both suites. Not part of `make test`.
mutate:
	python3 scripts/mutate.py --goose "$(abspath $(GOOSE))" --cases $(MUTATE_CASES)
