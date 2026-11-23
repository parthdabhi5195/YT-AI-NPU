# ---- Summary ---- #
# Allows testing chip piece by piece instead of entire thing at once via terminal
# Makefile builds only top-level file, whereas this compiles 8 seperate sim units
# ---- #

cmake_minimum_required(VERSION 3.12)
project(npu_sim)

# Find Verilator
find_package(verilator HINTS $ENV{VERILATOR_ROOT})
if (NOT verilator_FOUND)
    message(FATAL_ERROR "Verilator not found. Set VERILATOR_ROOT or add to PATH.")
endif()

# SystemVerilog source files
set(RTL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../rtl)
set(SIM_DIR ${CMAKE_CURRENT_SOURCE_DIR})

# Shared RTL sources (packages, memory, compute engines)
# Groups hardware blocks found in all tests
set(SV_COMMON
    ${RTL_DIR}/pkg/npu_pkg.sv
    ${RTL_DIR}/pkg/isa_pkg.sv
    ${RTL_DIR}/pkg/fixed_pkg.sv
    ${RTL_DIR}/mem/sram_dp.sv
    ${RTL_DIR}/mem/banked_sram.sv
    ${RTL_DIR}/gemm/mac_int8.sv
    ${RTL_DIR}/gemm/pe.sv
    ${RTL_DIR}/gemm/systolic_array.sv
    ${RTL_DIR}/ops/vec_engine.sv
    ${RTL_DIR}/ops/reduce_max.sv
    ${RTL_DIR}/ops/reduce_sum.sv
    ${RTL_DIR}/ops/exp_lut.sv
    ${RTL_DIR}/ops/recip_lut.sv
    ${RTL_DIR}/ops/softmax_engine.sv
    ${RTL_DIR}/ops/mean_var_engine.sv
    ${RTL_DIR}/ops/rsqrt_lut.sv
    ${RTL_DIR}/ops/layernorm_engine.sv
    ${RTL_DIR}/ops/gelu_lut.sv
    ${RTL_DIR}/ops/gelu_engine.sv
    ${RTL_DIR}/ops/silu_lut.sv
    ${RTL_DIR}/ops/rmsnorm_engine.sv
    ${RTL_DIR}/ops/rope_engine.sv
)

# Top-level sim sources (includes bus, ctrl, full top)
# Heavy external bus and DMA interfaces. Separated, so smaller tests run faster
set(SV_TOP_EXTRA
    ${RTL_DIR}/bus/axi_types.sv
    ${RTL_DIR}/bus/axi_lite_regs.sv
    ${RTL_DIR}/bus/axi_dma_rd.sv
    ${RTL_DIR}/bus/axi_dma_wr.sv
    ${RTL_DIR}/mem/kv_cache_bank.sv
    ${RTL_DIR}/ctrl/addr_gen.sv
    ${RTL_DIR}/ctrl/scoreboard.sv
    ${RTL_DIR}/ctrl/barrier.sv
    ${RTL_DIR}/ctrl/ucode_fetch.sv
    ${RTL_DIR}/ctrl/ucode_decode.sv
    ${RTL_DIR}/gemm/gemm_ctrl.sv
    ${RTL_DIR}/gemm/gemm_post.sv
    ${RTL_DIR}/top.sv
)

# Mirrors VERILATOR_FLAGS from Makefile and the warning supressions
set(VERILATOR_COMMON_ARGS
    --cc
    --trace
    --trace-structs
    -Wall
    -Wno-UNUSED
    -Wno-UNDRIVEN
    -Wno-PINCONNECTEMPTY
    -Wno-DECLFILENAME
    -Wno-IMPORTSTAR
    -Wno-VARHIDDEN
    -Wno-WIDTH
    -Wno-BLKSEQ
    -Wno-UNSIGNED
    --x-assign unique
    --x-initial unique
    -DSIMULATION
    -I${RTL_DIR}/pkg
    -I${RTL_DIR}/bus
    -I${RTL_DIR}/mem
    -I${RTL_DIR}/ctrl
    -I${RTL_DIR}/gemm
    -I${RTL_DIR}/ops
)

# Pairs a C++ testbench with a specific SystemVerilog wrapper .sv for each target.
# ---- Target 1: Control Plane Smoke Test (original top-level) ----
add_executable(npu_sim tb_top.cpp)
# testing AXI4-Lite registers, AXI4 DMA, and NOP microcode on top.sv
verilate(npu_sim
    SOURCES ${SV_COMMON} ${SV_TOP_EXTRA}
    TOP_MODULE top
    PREFIX Vtop
    VERILATOR_ARGS ${VERILATOR_COMMON_ARGS}
)

# ---- Target 2: Engine Compute Tests ----
add_executable(engine_sim tb_engines.cpp)
# Testing gelu, softamx, layernorm, vec, and systolic_array
verilate(engine_sim
    SOURCES ${SV_COMMON} ${SIM_DIR}/engine_tb_top.sv
    TOP_MODULE engine_tb_top
    PREFIX Vengine_tb_top
    VERILATOR_ARGS ${VERILATOR_COMMON_ARGS}
)

# Control plane RTL needed for integration test (without bus/AXI/top.sv)
# lightweight microcode control logic (separated from heavy SV_TOP_EXTRA)
set(SV_CTRL
    ${RTL_DIR}/ctrl/scoreboard.sv
    ${RTL_DIR}/ctrl/barrier.sv
    ${RTL_DIR}/ctrl/ucode_fetch.sv
    ${RTL_DIR}/ctrl/ucode_decode.sv
)

# ---- Target 3: Integration Test (single attention head) ----
add_executable(integration_sim tb_integration.cpp)
# Adds Integrating SV_CTRL around softmax_engine to test single attention head
verilate(integration_sim
    SOURCES ${SV_COMMON} ${SV_CTRL} ${SIM_DIR}/integration_top.sv
    TOP_MODULE integration_top
    PREFIX Vintegration_top
    VERILATOR_ARGS ${VERILATOR_COMMON_ARGS}
)

# ---- Target 4: GPT-2 Transformer Block Test ----
add_executable(gpt2_block_sim tb_gpt2_block.cpp)
# testing transformer and overriding hardware parameters
verilate(gpt2_block_sim
    SOURCES ${SV_COMMON} ${SV_CTRL} ${SIM_DIR}/gpt2_block_top.sv
    TOP_MODULE gpt2_block_top
    PREFIX Vgpt2_block_top
    VERILATOR_ARGS ${VERILATOR_COMMON_ARGS}
        -GSRAM0_DEPTH=65536
)

# ---- Target 5: GPT-2 Inference Demo ----
# Reuses gpt2_block_top.sv with larger SRAMs for full sequence support
add_executable(demo_infer tb_demo_infer.cpp)

verilate(demo_infer
    SOURCES ${SV_COMMON} ${SV_CTRL} ${SIM_DIR}/gpt2_block_top.sv
    TOP_MODULE gpt2_block_top
    PREFIX Vgpt2_block_top
    VERILATOR_ARGS ${VERILATOR_COMMON_ARGS}
        -GSRAM0_DEPTH=65536
        -GSRAM1_DEPTH=8192
)

# ---- Target 6: KV Cache Correctness Test ----
# Verifies that KV-cached decode produces bit-exact results vs full-recompute
add_executable(kv_cache_sim tb_kv_cache_sim.cpp)
# Key-Value Testing
verilate(kv_cache_sim
    SOURCES ${SV_COMMON} ${SV_CTRL} ${SIM_DIR}/gpt2_block_top.sv
    TOP_MODULE gpt2_block_top
    PREFIX Vgpt2_block_top
    VERILATOR_ARGS ${VERILATOR_COMMON_ARGS}
        -GSRAM0_DEPTH=65536
        -GSRAM1_DEPTH=8192
)

# ---- Target 7: LLaMA Transformer Block Test ----
add_executable(llama_block_sim tb_llama_block.cpp)

verilate(llama_block_sim
    SOURCES ${SV_COMMON} ${SV_CTRL} ${SIM_DIR}/llama_block_top.sv
    TOP_MODULE llama_block_top
    PREFIX Vllama_block_top
    VERILATOR_ARGS ${VERILATOR_COMMON_ARGS}
        -GSRAM0_DEPTH=65536
        -GSRAM1_DEPTH=8192
)

# ---- Target 8: LLaMA Inference Demo ----
# Full autoregressive LLaMA inference (4 blocks + final RMSNorm + lm_head)
add_executable(llama_demo_infer tb_llama_demo_infer.cpp)

verilate(llama_demo_infer
    SOURCES ${SV_COMMON} ${SV_CTRL} ${SIM_DIR}/llama_block_top.sv
    TOP_MODULE llama_block_top
    PREFIX Vllama_block_top
    VERILATOR_ARGS ${VERILATOR_COMMON_ARGS}
        -GSRAM0_DEPTH=65536
        -GSRAM1_DEPTH=8192
)
