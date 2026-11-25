# =============================================================================
# YT-AI Custom Silicon NPU Top-Level Makefile
# Targets: quantize | compile | lint | verify | gds | sim | openlane | clean
# =============================================================================

# =============================================================================
# Summary: 
# Just a shortcut menu of terminal commands	for building, testing, and
# exporting NPU
# =============================================================================

# uses Python 3.14 if present at folder, else falls back to python3
PYTHON ?= /Library/Frameworks/Python.framework/Versions/3.14/bin/python3
ifeq ($(wildcard $(PYTHON)),)
PYTHON := python3
endif

# Defaults to the trained PyTorch checkpoint
CKPT ?= "../../YT AI SLM/GPT Architecture/yt-ai-slm/best_model_params.pt"

# tells make these names are actions rather than files on disc
.PHONY: all quantize compile lint verify silicon sim openlane clean

# make all: checks RTL, verifies NPU math vs PyTorch, and exports chip layout
all: lint verify silicon

# make quantize: converts PyTorch checkpoint into INT8 weights
quantize:
	$(PYTHON) python/tools/export_quantize_yt_ai.py --ckpt $(CKPT) --out-dir build

# make compile: depends on quantize running first, then compiles the 128-bit microcode .hex file
compile: quantize
	$(PYTHON) python/tools/ucode_compiler.py

# make lint: checks all 25 SystemVerilog files for syntax/port mismatches and verifies SFU math
lint:
	$(PYTHON) python/tests/lint_rtl.py

# make verify: runs the Python NPU simulator end-to-end against PyTorch FP32 and exports test vectors for C++ sim
verify:
	$(PYTHON) python/tests/verify_yt_ai_npu.py

# make silicon: generates the .gds floorplan, .svg die diagram, and .stl 3D-printable chip model in asic/output/.
silicon:
	$(PYTHON) asic/scripts/export_3d_silicon.py

# make sim: compiles the SV RTL into C++ via Verilator and runs smoke test and 1-layer real-weights test tb_yt_block
sim:
	mkdir -p sim/verilator/build
	cd sim/verilator/build && cmake .. && $(MAKE) -j4
	./sim/verilator/build/tb_engines
	./sim/verilator/build/tb_yt_block build

# make openlane: runs export_3d_silicon.py, then launches Openlane 2 ASIC (native or Docker) if installed
openlane:
	./asic/scripts/run_silicon_flow.sh

# make clean: deletes compiled .hex, golden test vectors, and the verilator build/ folder
clean:
	rm -rf build/*.hex build/tb_golden_* sim/verilator/build
