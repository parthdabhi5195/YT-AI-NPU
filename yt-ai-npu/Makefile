# =============================================================================
# YT-AI Custom Silicon NPU Top-Level Makefile
# Targets: quantize | compile | lint | verify | gds | sim | openlane | clean
# =============================================================================

PYTHON ?= /Library/Frameworks/Python.framework/Versions/3.14/bin/python3
ifeq ($(wildcard $(PYTHON)),)
PYTHON := python3
endif

CKPT ?= "../../YT AI SLM/GPT Architecture/yt-ai-slm/best_model_params.pt"

.PHONY: all quantize compile lint verify silicon sim openlane clean

all: lint verify silicon

quantize:
	$(PYTHON) python/tools/export_quantize_yt_ai.py --ckpt $(CKPT) --out-dir build

compile: quantize
	$(PYTHON) python/tools/ucode_compiler.py

lint:
	$(PYTHON) python/tests/lint_rtl.py

verify:
	$(PYTHON) python/tests/verify_yt_ai_npu.py

silicon:
	$(PYTHON) asic/scripts/export_3d_silicon.py

sim:
	mkdir -p sim/verilator/build
	cd sim/verilator/build && cmake .. && $(MAKE) -j4
	./sim/verilator/build/tb_engines
	./sim/verilator/build/tb_yt_block build

openlane:
	./asic/scripts/run_silicon_flow.sh

clean:
	rm -rf build/*.hex build/tb_golden_* sim/verilator/build
