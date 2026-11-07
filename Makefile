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
.PHONY: setup format check test test-debug sanitize bench bench-build

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
	python3 -m py_compile tests/oracle.py scripts/sanitize.py scripts/quickstart.py bench/measure.py bench/fixtures.py bench/fetch.py bench/build-baseline.py
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

bench: bench-build
	GOOSE="$(abspath $(GOOSE))" python3 bench/measure.py --samples $(BENCH_SAMPLES) --batch $(BENCH_BATCH) --ms $(BENCH_MS)

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
