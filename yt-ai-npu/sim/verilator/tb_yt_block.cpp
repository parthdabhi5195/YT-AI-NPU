// =============================================================================
// 1-Layer Real YT-AI Checkpoint + Tied 50,257-Vocab LM-Head RTL Testbench
// (`tb_yt_block.cpp`)
// Loads `build/yt_ai_weights.bin` & `build/yt_ai_1layer_program.hex` into
// `yt_npu_top` and verifies cycle-accurate RTL output matches Python golden!
// =============================================================================
#include "axi_ddr_sim.hpp"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const std::string build_dir = (argc > 1) ? argv[1] : "../../build";

    YtNpuTestRig rig;
    rig.reset();

    std::cout << "[tb_yt_block] Loading 51.4 MB YT-AI quantized DDR image..." << std::endl;
    rig.load_ddr_binary(build_dir + "/yt_ai_weights.bin", 0);
    uint32_t ulen = rig.load_ucode_hex(build_dir + "/yt_ai_1layer_program.hex");
    std::cout << "[tb_yt_block] Loaded " << ulen << " 128-bit microcode instructions." << std::endl;

    // Scales from `build/tb_golden_meta.json` (wte_deq=712, wpe_deq=722, lm=178>>14)
    rig.axil_write(0x30, (722U << 16) | 712U);
    rig.axil_write(0x34, (14U << 8)   | 178U);
    rig.axil_write(0x18, 1);    // REG_PROMPT_LEN = 1
    rig.axil_write(0x1C, 1);    // REG_MAX_NEW_TOKENS = 1
    rig.axil_write(0x20, 0);    // REG_TEMP_INV_Q88 = 0 (greedy)
    rig.axil_write(0x24, 1);    // REG_TOP_K = 1
    rig.axil_write(0x38, 7454); // Prompt token "Once"

    // Launch autonomous mode + IRQ enable + START (0x0D)
    rig.axil_write(0x00, 0x0D);

    while (!rig.dut->irq) {
        rig.tick();
        if ((rig.cycle_count % 1000000ULL) == 0) {
            std::cout << "  ... simulated " << (rig.cycle_count / 1000000ULL) << "M cycles" << std::endl;
        }
    }

    uint32_t pop = rig.axil_read(0x3C);
    uint32_t hw_tok = pop & 0xFFFFU;
    std::cout << "[tb_yt_block] Finished in " << rig.cycle_count
              << " cycles! Sampled token ID = " << hw_tok << " (expected 356)" << std::endl;
    assert((pop & 0x80000000U) != 0);
    assert(hw_tok == 356U);
    std::cout << "[tb_yt_block] PASS!" << std::endl;
    return 0;
}
