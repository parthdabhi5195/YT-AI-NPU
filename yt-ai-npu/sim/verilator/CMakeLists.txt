cmake_minimum_required(VERSION 3.16)
project(yt_ai_npu_sim LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(verilator HINTS $ENV{VERILATOR_ROOT} REQUIRED)

set(RTL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../rtl)

# Package-first RTL source list (100% synthesizable, zero stubs)
set(YT_NPU_RTL_SRCS
    ${RTL_DIR}/pkg/yt_npu_pkg.sv
    ${RTL_DIR}/pkg/yt_isa_pkg.sv
    ${RTL_DIR}/mem/yt_sram_1r1w.sv
    ${RTL_DIR}/mem/yt_pingpong_wgt.sv
    ${RTL_DIR}/gemm/yt_mac_w8a16.sv
    ${RTL_DIR}/gemm/yt_pe.sv
    ${RTL_DIR}/gemm/yt_systolic_array.sv
    ${RTL_DIR}/gemm/yt_gemm_engine.sv
    ${RTL_DIR}/ops/yt_rsqrt_lut.sv
    ${RTL_DIR}/ops/yt_exp_lut.sv
    ${RTL_DIR}/ops/yt_recip_lut.sv
    ${RTL_DIR}/ops/yt_gelu_lut.sv
    ${RTL_DIR}/ops/yt_layernorm_engine.sv
    ${RTL_DIR}/ops/yt_softmax_engine.sv
    ${RTL_DIR}/ops/yt_gelu_engine.sv
    ${RTL_DIR}/ops/yt_vec_engine.sv
    ${RTL_DIR}/ops/yt_embed_engine.sv
    ${RTL_DIR}/ops/yt_topk_sampler.sv
    ${RTL_DIR}/bus/yt_axi_lite_regs.sv
    ${RTL_DIR}/bus/yt_axi_dma_rd.sv
    ${RTL_DIR}/bus/yt_axi_dma_wr.sv
    ${RTL_DIR}/ctrl/yt_scoreboard.sv
    ${RTL_DIR}/ctrl/yt_ucode_fetch.sv
    ${RTL_DIR}/ctrl/yt_ucode_decode.sv
    ${RTL_DIR}/ctrl/yt_token_sequencer.sv
    ${RTL_DIR}/yt_npu_top.sv
)

set(VFLAGS -Wall -Wno-fatal --x-assign unique --x-initial unique -O3)

function(add_npu_tb TB_NAME TB_SRC)
    add_executable(${TB_NAME} ${TB_SRC})
    target_include_directories(${TB_NAME} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    verilate(${TB_NAME}
        SOURCES ${YT_NPU_RTL_SRCS}
        TOP_MODULE yt_npu_top
        PREFIX Vyt_npu_top
        VERILATOR_ARGS ${VFLAGS}
    )
endfunction()

add_npu_tb(tb_engines    tb_engines.cpp)
add_npu_tb(tb_yt_block   tb_yt_block.cpp)
add_npu_tb(tb_yt_autogen tb_yt_autogen.cpp)
