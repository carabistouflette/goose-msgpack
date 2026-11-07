GOOSE ?= .toolchain/goose/build/goose
CC ?= gcc
SANITIZER_CC ?= gcc
ORACLE_CASES ?= 100000
PLAN_CASES ?= 512
BENCH_SAMPLES ?= 7
BENCH_BATCH ?= 64
BENCH_MS ?= 200
OUTPUT ?= .build/results.json
.NOTPARALLEL:
.PHONY: setup format check test test-debug sanitize bench bench-build

setup:
	./scripts/setup-goose.sh

format:
	"$(GOOSE)" format msgpack.goose tests examples bench

check:
	python3 scripts/check-task-vendor.py
	"$(GOOSE)" format --check msgpack.goose tests examples bench
	"$(GOOSE)" check msgpack.goose
	"$(GOOSE)" check tests/api.goose
	"$(GOOSE)" check tests/oracle.goose
	"$(GOOSE)" check examples/plan.goose
	"$(GOOSE)" check tests/plan_consumer.goose
	"$(GOOSE)" check tests/plan_model.goose
	"$(GOOSE)" check bench/bench.goose
	python3 -m py_compile tests/oracle.py scripts/sanitize.py scripts/quickstart.py bench/measure.py bench/fixtures.py bench/fetch.py
	python3 -m py_compile scripts/check-task-vendor.py tests/plan_model.py tests/plan_process.py tests/plan_process_test.py
	git diff --check

test:
	mkdir -p .build
	python3 tests/plan_process_test.py
	"$(GOOSE)" run tests/plan_consumer.goose
	"$(GOOSE)" build tests/plan_consumer.goose --standalone --cc "$(CC)" -O2 -o .build/plan-consumer
	./.build/plan-consumer
	python3 tests/plan_model.py --goose "$(abspath $(GOOSE))" --cc "$(CC)" --cases $(PLAN_CASES)
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
	"$(GOOSE)" run tests/plan_consumer.goose --debug
	"$(GOOSE)" build tests/plan_consumer.goose --standalone --debug --cc "$(CC)" -o .build/plan-consumer-debug
	./.build/plan-consumer-debug
	python3 tests/plan_model.py --goose "$(abspath $(GOOSE))" --cc "$(CC)" --debug --cases $(PLAN_CASES)
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
