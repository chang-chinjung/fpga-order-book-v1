VERILATOR ?= verilator
PYTHON    ?= python3
YOSYS     ?= yosys
NEXTPNR   ?= nextpnr-ecp5
VCOV      ?= verilator_coverage

TOP       := tb_order_book_v1
RTL       := rtl/bram_sdp.sv rtl/bitmap_best.sv rtl/order_book_v1.sv
SYNTH_RTL := $(RTL) rtl/order_book_v1_top.sv
SRC       := $(RTL) tb/tb_order_book_v1.sv
SYNTH_TOP := order_book_v1_top
JSON      := build/order_book_v1_ecp5.json
FREQ_MHZ  ?= 130
SEED      ?= 42
RAND_N    ?= 10000

.PHONY: all stim lint sim coverage mutate synth pnr pnr-3seeds clean

all: lint sim

stim:
	$(PYTHON) model/book_v1_model.py --n $(RAND_N) --seed $(SEED) --dir build

lint:
	$(VERILATOR) --lint-only --timing -Wall --top-module order_book_v1 $(RTL)
	$(VERILATOR) --lint-only --timing -Wall --top-module $(SYNTH_TOP) $(SYNTH_RTL)
	$(VERILATOR) --lint-only --timing -Wall --top-module $(TOP) $(SRC)

sim: stim
	mkdir -p build
	$(VERILATOR) --binary --timing --assert -j 0 --output-split 2000 -Wall -CFLAGS "-O0" \
		--top-module $(TOP) --Mdir build/sim $(SRC)
	./build/sim/V$(TOP)

coverage: stim
	mkdir -p build/cov
	$(VERILATOR) --binary --timing --assert --coverage-line -j 0 --output-split 2000 -Wall -CFLAGS "-O0" \
		--top-module $(TOP) --Mdir build/cov $(SRC)
	./build/cov/V$(TOP)
	$(VCOV) --write-info build/cov/lcov.info coverage.dat
	$(VCOV) --annotate build/cov/annotated coverage.dat
	$(PYTHON) tools/cov_report.py build/cov/lcov.info --min-rtl 95.0

mutate: stim
	$(PYTHON) tools/mutate_v1.py

synth:
	mkdir -p build
	$(YOSYS) -p "read_verilog -sv $(SYNTH_RTL); synth_ecp5 -top $(SYNTH_TOP) -json $(JSON)" \
		2>&1 | tee build/synth.log

pnr: synth
	$(NEXTPNR) --85k --package CABGA756 --json $(JSON) \
		--freq $(FREQ_MHZ) --placer-heap-timingweight 50 --textcfg build/order_book_v1.config \
		2>&1 | tee build/pnr.log

pnr-3seeds: synth
	@for s in 1 2 3; do \
		echo "=== nextpnr-ecp5 seed=$$s target=$(FREQ_MHZ) MHz ==="; \
		$(NEXTPNR) --85k --package CABGA756 --json $(JSON) \
			--freq $(FREQ_MHZ) --seed $$s --placer-heap-timingweight 50 \
			--textcfg build/order_book_v1_s$$s.config \
			2>&1 | tee build/pnr_s$$s.log | grep -E "Max frequency|ERROR:"; \
	done

clean:
	rm -rf build coverage.dat
