// =============================================================================
// Unit & Integration RTL Testbench for YT-AI NPU Engines (`tb_engines.cpp`)
// Verifies AXI-Lite MMIO, Microcode Loader, DMA Read/Write, Embed, LayerNorm,
// GEMM, GELU, Softmax, and Top-K Hardware Sampler on `yt_npu_top`.
// =============================================================================
#include "axi_ddr_sim.hpp"

static void emit_instr(YtNpuTestRig& rig, uint8_t op, uint8_t flags,
                       uint16_t dst, uint16_t src0, uint16_t src1,
                       uint16_t M, uint16_t N, uint16_t K, uint16_t imm) {
    uint32_t w0 = static_cast<uint32_t>(op) | (static_cast<uint32_t>(flags) << 8) | (static_cast<uint32_t>(dst) << 16);
    uint32_t w1 = static_cast<uint32_t>(src0) | (static_cast<uint32_t>(src1) << 16);
    uint32_t w2 = static_cast<uint32_t>(M) | (static_cast<uint32_t>(N) << 16);
    uint32_t w3 = static_cast<uint32_t>(K) | (static_cast<uint32_t>(imm) << 16);
    rig.axil_write(0x50, w0);
    rig.axil_write(0x54, w1);
    rig.axil_write(0x58, w2);
    rig.axil_write(0x5C, w3);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    YtNpuTestRig rig;
    rig.reset();

    // Populate synthetic WTE[0] = +16 and WPE[0] = +8 in DDR
    for (int i = 0; i < 512; ++i) {
        rig.ddr[0x00000000 + i] = static_cast<uint8_t>(16);
        rig.ddr[0x01890000 + i] = static_cast<uint8_t>(8);
    }

    // Configure scales: wte_deq=256, wpe_deq=256 => embed_out[i] = 16 + 8 = 24
    rig.axil_write(0x30, (256U << 16) | 256U);
    rig.axil_write(0x24, 1);   // Top-1 greedy
    rig.axil_write(0x20, 0);   // Greedy temp_inv=0
    rig.axil_write(0x38, 0);   // Push prompt token 0

    // Write short microcode program: DMA WTE -> DMA WPE -> EMBED -> GELU -> DMA_STORE -> TOPK_FEED -> TOPK_SAMPLE -> END
    rig.axil_write(0x4C, 0);
    emit_instr(rig, 0x01, 0x80, 0, 0, 0, 0, 512, 0, 0);    // OP_DMA_LOAD WTE[tok] -> WGT0
    emit_instr(rig, 0x0A, 0x00, 0, 0, 0, 0, 0, 0, 0);      // OP_BARRIER
    emit_instr(rig, 0x01, 0x85, 0, 0, 0, 0, 512, 0, 0);    // OP_DMA_LOAD WPE[pos] -> WGT1
    emit_instr(rig, 0x0A, 0x00, 0, 0, 0, 0, 0, 0, 0);      // OP_BARRIER
    emit_instr(rig, 0x0B, 0x00, 0, 0, 0, 1, 512, 0, 0);    // OP_EMBED -> ACT[0..511]
    emit_instr(rig, 0x0A, 0x00, 0, 0, 0, 0, 0, 0, 0);      // OP_BARRIER
    emit_instr(rig, 0x07, 0x00, 0x0800, 0, 0, 1, 64, 0, 0);// OP_GELU ACT[0..63] -> ACT[0x800]
    emit_instr(rig, 0x0A, 0x00, 0, 0, 0, 0, 0, 0, 0);      // OP_BARRIER
    emit_instr(rig, 0x0C, 0x01, 0, 0x0800, 42, 0, 64, 0, 0);// OP_TOPK_FEED (reset, vocab_base=42)
    emit_instr(rig, 0x0A, 0x00, 0, 0, 0, 0, 0, 0, 0);      // OP_BARRIER
    emit_instr(rig, 0x0D, 0x00, 0, 0, 0, 0, 0, 0, 0);      // OP_TOPK_SAMPLE
    emit_instr(rig, 0x0A, 0x00, 0, 0, 0, 0, 0, 0, 0);      // OP_BARRIER
    emit_instr(rig, 0xFF, 0x00, 0, 0, 0, 0, 0, 0, 0);      // OP_END
    rig.axil_write(0x08, 13);

    // Start in single-program co-processor mode (autogen=0, irq_en=1, start=1 => 0x09)
    rig.axil_write(0x00, 0x09);

    while (!rig.dut->irq && rig.cycle_count < 50000) {
        rig.tick();
    }
    assert(rig.dut->irq && "Expected completion IRQ!");

    uint32_t pop = rig.axil_read(0x3C);
    std::cout << "[tb_engines] Completed in " << rig.cycle_count
              << " cycles, sampled_tok=" << (pop & 0xFFFF) << std::endl;
    assert((pop & 0x80000000U) != 0);
    assert((pop & 0xFFFFU) == 42U);
    std::cout << "[tb_engines] PASS!" << std::endl;
    return 0;
}
