// =============================================================================
// Full 8-Layer YT-AI 51.2M Autonomous Story Generation RTL Testbench
// (`tb_yt_autogen.cpp`)
// Drives full multi-token story generation on `yt_npu_top` with `top_k=200`,
// `temperature=0.8` (`temp_inv_q88=320`), and automatic `<|endoftext|>` stop!
// =============================================================================
#include "axi_ddr_sim.hpp"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const std::string build_dir = (argc > 1) ? argv[1] : "../../build";
    const uint32_t max_new_tokens = (argc > 2) ? static_cast<uint32_t>(std::stoul(argv[2])) : 4;

    YtNpuTestRig rig;
    rig.reset();

    std::cout << "[tb_yt_autogen] Loading YT-AI 51.2M quantized weights & 8-layer microcode..." << std::endl;
    rig.load_ddr_binary(build_dir + "/yt_ai_weights.bin", 0);
    uint32_t ulen = rig.load_ucode_hex(build_dir + "/yt_ai_full_program.hex");
    std::cout << "[tb_yt_autogen] Loaded " << ulen << " microcode instructions." << std::endl;

    // Push GPT-2 prompt tokens for "Once upon a time" ([7454, 2402, 257, 640])
    const uint32_t prompt[] = {7454, 2402, 257, 640};
    for (uint32_t t : prompt) rig.axil_write(0x38, t);

    rig.axil_write(0x30, (722U << 16) | 712U); // Calibrated YT-AI WTE/WPE dequant scales
    rig.axil_write(0x34, (14U << 8)   | 178U); // Calibrated YT-AI LM-head scales
    rig.axil_write(0x18, 4);              // REG_PROMPT_LEN = 4
    rig.axil_write(0x1C, max_new_tokens); // REG_MAX_NEW_TOKENS
    rig.axil_write(0x20, 320);            // REG_TEMP_INV_Q88 = 320 (T = 0.8)
    rig.axil_write(0x24, 200);            // REG_TOP_K = 200
    rig.axil_write(0x28, 0xCAFEBEEFU);    // RNG seed lo
    rig.axil_write(0x2C, 0x20265120U);    // RNG seed hi

    // Launch full autonomous token sequencer!
    rig.axil_write(0x00, 0x0D);

    while (!rig.dut->irq) {
        rig.tick();
        if ((rig.cycle_count % 5000000ULL) == 0) {
            uint32_t gen_so_far = rig.axil_read(0x40);
            std::cout << "  ... " << (rig.cycle_count / 1000000ULL)
                      << "M cycles | generated_tokens=" << gen_so_far << std::endl;
        }
    }

    uint32_t total_gen = rig.axil_read(0x40);
    std::cout << "[tb_yt_autogen] Generation complete! Generated " << total_gen << " tokens: [";
    for (uint32_t i = 0; i < total_gen; ++i) {
        uint32_t tok = rig.axil_read(0x3C) & 0xFFFFU;
        std::cout << tok << (i + 1 < total_gen ? ", " : "");
    }
    std::cout << "] in " << rig.cycle_count << " cycles." << std::endl;
    return 0;
}
