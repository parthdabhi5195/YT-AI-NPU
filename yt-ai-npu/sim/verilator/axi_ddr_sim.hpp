// =============================================================================
// Cycle-Accurate 64 MB 128-Bit AXI4 DDR Slave & AXI4-Lite Host Driver (`axi_ddr_sim.hpp`)
// Drives `Vyt_npu_top` in Verilator C++17 testbenches.
// =============================================================================
#pragma once

#include <cassert>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "Vyt_npu_top.h"

class YtNpuTestRig {
public:
    static constexpr size_t DDR_BYTES = 64ULL * 1024ULL * 1024ULL;

    Vyt_npu_top* dut;
    std::vector<uint8_t> ddr;
    uint64_t cycle_count = 0;

    // AXI4 Read Burst State
    bool     rd_active = false;
    uint32_t rd_addr   = 0;
    uint16_t rd_rem    = 0;

    // AXI4 Write Burst State
    bool     wr_active = false;
    uint32_t wr_addr   = 0;
    bool     wr_bvalid = false;

    YtNpuTestRig() : dut(new Vyt_npu_top), ddr(DDR_BYTES, 0) {
        dut->clk            = 0;
        dut->rst_n          = 0;
        dut->s_axil_awaddr  = 0;
        dut->s_axil_awprot  = 0;
        dut->s_axil_awvalid = 0;
        dut->s_axil_wdata   = 0;
        dut->s_axil_wstrb   = 0xF;
        dut->s_axil_wvalid  = 0;
        dut->s_axil_bready  = 1;
        dut->s_axil_araddr  = 0;
        dut->s_axil_arprot  = 0;
        dut->s_axil_arvalid = 0;
        dut->s_axil_rready  = 0;

        dut->m_axi_arready  = 0;
        dut->m_axi_rid      = 0;
        dut->m_axi_rresp    = 0;
        dut->m_axi_rlast    = 0;
        dut->m_axi_rvalid   = 0;
        std::memset(dut->m_axi_rdata, 0, sizeof(dut->m_axi_rdata));

        dut->m_axi_awready  = 0;
        dut->m_axi_wready   = 0;
        dut->m_axi_bid      = 0;
        dut->m_axi_bresp    = 0;
        dut->m_axi_bvalid   = 0;
    }

    ~YtNpuTestRig() { delete dut; }

    void reset(int cycles = 8) {
        dut->rst_n = 0;
        for (int i = 0; i < cycles; ++i) tick();
        dut->rst_n = 1;
        for (int i = 0; i < 4; ++i) tick();
    }

    void tick() {
        // Combinational AXI slave ready/valid setup before posedge
        dut->m_axi_arready = !rd_active;
        dut->m_axi_awready = !wr_active && !wr_bvalid;
        dut->m_axi_wready  = wr_active;
        dut->m_axi_bvalid  = wr_bvalid;
        dut->m_axi_bresp   = 0;

        if (rd_active) {
            dut->m_axi_rvalid = 1;
            dut->m_axi_rlast  = (rd_rem == 1);
            std::memcpy(dut->m_axi_rdata, &ddr[rd_addr & (DDR_BYTES - 1)], 16);
        } else {
            dut->m_axi_rvalid = 0;
            dut->m_axi_rlast  = 0;
        }

        dut->clk = 0;
        dut->eval();

        // Sample handshakes just prior to posedge
        const bool ar_fire = dut->m_axi_arvalid && dut->m_axi_arready;
        const uint32_t ar_addr_lat = dut->m_axi_araddr;
        const uint16_t ar_beats    = static_cast<uint16_t>(dut->m_axi_arlen) + 1;
        const bool r_fire  = rd_active && dut->m_axi_rready;

        const bool aw_fire = dut->m_axi_awvalid && dut->m_axi_awready;
        const uint32_t aw_addr_lat = dut->m_axi_awaddr;
        const bool w_fire  = wr_active && dut->m_axi_wvalid;
        const bool w_last  = dut->m_axi_wlast;
        uint8_t w_bytes[16];
        std::memcpy(w_bytes, dut->m_axi_wdata, 16);
        const bool b_fire  = wr_bvalid && dut->m_axi_bready;

        dut->clk = 1;
        dut->eval();
        ++cycle_count;

        // Update AXI slave state after posedge
        if (ar_fire) {
            rd_active = true;
            rd_addr   = ar_addr_lat & ~0xFU;
            rd_rem    = ar_beats;
        } else if (r_fire) {
            rd_addr += 16;
            --rd_rem;
            if (rd_rem == 0) rd_active = false;
        }

        if (aw_fire) {
            wr_active = true;
            wr_addr   = aw_addr_lat & ~0xFU;
        }
        if (w_fire) {
            std::memcpy(&ddr[wr_addr & (DDR_BYTES - 1)], w_bytes, 16);
            wr_addr += 16;
            if (w_last) {
                wr_active = false;
                wr_bvalid = true;
            }
        }
        if (b_fire) {
            wr_bvalid = false;
        }
    }

    void axil_write(uint32_t addr, uint32_t data) {
        dut->s_axil_awaddr  = addr;
        dut->s_axil_awvalid = 1;
        dut->s_axil_wdata   = data;
        dut->s_axil_wvalid  = 1;
        dut->s_axil_bready  = 1;

        bool aw_done = false, w_done = false;
        for (int timeout = 0; timeout < 100; ++timeout) {
            dut->eval();
            if (dut->s_axil_awvalid && dut->s_axil_awready) aw_done = true;
            if (dut->s_axil_wvalid  && dut->s_axil_wready)  w_done  = true;
            tick();
            if (aw_done) dut->s_axil_awvalid = 0;
            if (w_done)  dut->s_axil_wvalid  = 0;
            if (aw_done && w_done && dut->s_axil_bvalid) {
                tick();
                return;
            }
        }
        throw std::runtime_error("AXI-Lite write timeout");
    }

    uint32_t axil_read(uint32_t addr) {
        dut->s_axil_araddr  = addr;
        dut->s_axil_arvalid = 1;
        dut->s_axil_rready  = 1;

        bool ar_done = false;
        for (int timeout = 0; timeout < 100; ++timeout) {
            dut->eval();
            if (dut->s_axil_arvalid && dut->s_axil_arready) ar_done = true;
            tick();
            if (ar_done) dut->s_axil_arvalid = 0;
            if (dut->s_axil_rvalid) {
                uint32_t rdata = dut->s_axil_rdata;
                tick();
                dut->s_axil_rready = 0;
                return rdata;
            }
        }
        throw std::runtime_error("AXI-Lite read timeout");
    }

    void load_ddr_binary(const std::string& path, uint32_t offset = 0) {
        std::ifstream ifs(path, std::ios::binary | std::ios::ate);
        if (!ifs) throw std::runtime_error("Cannot open binary file: " + path);
        const size_t sz = static_cast<size_t>(ifs.tellg());
        if (offset + sz > DDR_BYTES) throw std::runtime_error("Binary exceeds 64 MB DDR");
        ifs.seekg(0);
        ifs.read(reinterpret_cast<char*>(&ddr[offset]), static_cast<std::streamsize>(sz));
    }

    uint32_t load_ucode_hex(const std::string& hex_path) {
        std::ifstream ifs(hex_path);
        if (!ifs) throw std::runtime_error("Cannot open ucode hex: " + hex_path);
        axil_write(0x4C, 0); // REG_UCODE_WR_ADDR = 0
        uint32_t count = 0;
        std::string line;
        while (std::getline(ifs, line)) {
            if (line.size() < 32) continue;
            uint32_t w3 = std::stoul(line.substr(0, 8),  nullptr, 16);
            uint32_t w2 = std::stoul(line.substr(8, 8),  nullptr, 16);
            uint32_t w1 = std::stoul(line.substr(16, 8), nullptr, 16);
            uint32_t w0 = std::stoul(line.substr(24, 8), nullptr, 16);
            axil_write(0x50, w0);
            axil_write(0x54, w1);
            axil_write(0x58, w2);
            axil_write(0x5C, w3); // Triggers 128-bit write + auto-increment
            ++count;
        }
        axil_write(0x08, count); // REG_UCODE_LEN
        return count;
    }
};
