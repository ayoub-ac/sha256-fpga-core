// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// Verilator C++ harness for sha256_padder. Verifies that the padder produces
// FIPS-180-4 §5.1.1 compliant output for a range of tail lengths.
//
// We compare the padder's emitted block(s) against a software pad written
// directly from FIPS-180-4 §5.1.1 (same routine used in sim_main.cpp).

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

#include "verilated.h"
#include "Vsha256_padder_tb.h"

static vluint64_t g_time = 0;
static int g_failures = 0;

static void tick(Vsha256_padder_tb* dut) {
    dut->clk_i = 0;
    dut->eval();
    g_time++;
    dut->clk_i = 1;
    dut->eval();
    g_time++;
}

static void reset(Vsha256_padder_tb* dut) {
    dut->rst_ni = 0;
    dut->start_i = 0;
    dut->block_ready_i = 0;
    dut->tail_len_i = 0;
    dut->total_bits_i = 0;
    for (int i = 0; i < 16; i++) dut->tail_bytes_i[i] = 0;
    for (int i = 0; i < 4; i++) tick(dut);
    dut->rst_ni = 1;
    tick(dut);
}

// Software pad: mirror of sim_main.cpp's sw_pad. Returns padded blocks.
static std::vector<std::vector<uint8_t>>
sw_pad(const uint8_t* msg, size_t msg_len) {
    uint64_t L_bits = static_cast<uint64_t>(msg_len) * 8;
    size_t   tail   = msg_len % 64;
    size_t   pad_bytes;
    if (tail < 56) pad_bytes = 56 - tail;
    else           pad_bytes = (64 - tail) + 56;
    size_t total = msg_len + pad_bytes + 8;

    std::vector<uint8_t> buf(total, 0);
    if (msg_len > 0) std::memcpy(buf.data(), msg, msg_len);
    buf[msg_len] = 0x80;
    for (int k = 0; k < 8; k++) {
        buf[total - 8 + k] = (L_bits >> (56 - 8*k)) & 0xff;
    }

    std::vector<std::vector<uint8_t>> out;
    for (size_t i = 0; i < total; i += 64) {
        out.emplace_back(buf.begin() + i, buf.begin() + i + 64);
    }
    return out;
}

// Set tail_bytes_i: byte index i lives at bits [503 - 8*i -: 8].
static void set_tail(uint32_t* port_words, const uint8_t* bytes, size_t len) {
    // tail_bytes_i is 504 bits = 63 bytes = 16 32-bit words (15 full + 1 partial).
    // Verilator stores wide signals little-endian word order.
    // Total bit width 504 = 16 words covers bits [503:0]; word[15] holds [503:480].
    int n_words = 16;
    for (int i = 0; i < n_words; i++) port_words[i] = 0;
    for (size_t i = 0; i < len; i++) {
        int bit_hi = 503 - 8*static_cast<int>(i);
        int word   = bit_hi / 32;
        int shift  = bit_hi - word * 32 - 7;
        port_words[word] |= static_cast<uint32_t>(bytes[i]) << shift;
    }
}

// Read 64-byte block from block_o (16 words, little-endian word order).
static void read_block(const uint32_t* port_words, uint8_t* out) {
    for (int i = 0; i < 64; i++) {
        int bit_hi = 511 - 8*i;
        int word   = bit_hi / 32;
        int shift  = bit_hi - word * 32 - 7;
        out[i] = (port_words[word] >> shift) & 0xff;
    }
}

// total_bits_i is a 64-bit scalar (QData/uint64_t in Verilator).

// Run one tail through the padder. Compare emitted blocks against software pad.
static bool run_tail(Vsha256_padder_tb* dut,
                     const uint8_t* msg, size_t msg_len,
                     const char* label) {
    // Total bits include all upstream blocks + tail. For unit test, msg is
    // the WHOLE message — no upstream — so tail_len = msg_len % 64 and the
    // upstream blocks (msg_len / 64 of them) are NOT fed to the padder; we
    // only check that the final block(s) the padder produces match the
    // last-block(s) of the full software pad.
    uint64_t total_bits = static_cast<uint64_t>(msg_len) * 8;
    size_t   tail_len = msg_len % 64;
    const uint8_t* tail_ptr = msg + (msg_len - tail_len);

    auto sw_blocks = sw_pad(msg, msg_len);
    size_t expected_blocks = (tail_len < 56) ? 1 : 2;
    if (sw_blocks.size() < expected_blocks) {
        std::fprintf(stderr, "[%s] sw_pad produced fewer blocks than expected\n", label);
        return false;
    }
    // The padder produces ONLY the tail-related blocks (the last 1 or 2 of
    // sw_blocks). When tail_len == 0 we still produce a single
    // pad+length block.
    if (tail_len == 0) expected_blocks = 1;

    // Drive request
    set_tail(dut->tail_bytes_i, tail_ptr, tail_len);
    dut->tail_len_i = static_cast<uint8_t>(tail_len);
    dut->total_bits_i = total_bits;
    dut->start_i = 1;
    dut->block_ready_i = 0;
    tick(dut);
    dut->start_i = 0;

    // Collect blocks
    std::vector<std::vector<uint8_t>> got_blocks;
    int safety = 1000;
    while (got_blocks.size() < expected_blocks && safety-- > 0) {
        if (dut->block_valid_o) {
            std::vector<uint8_t> blk(64);
            read_block(dut->block_o, blk.data());
            got_blocks.push_back(blk);
            dut->block_ready_i = 1;
            tick(dut);
            dut->block_ready_i = 0;
        } else {
            tick(dut);
        }
    }
    if (got_blocks.size() != expected_blocks) {
        std::fprintf(stderr, "[%s] expected %zu blocks, got %zu\n",
                     label, expected_blocks, got_blocks.size());
        return false;
    }

    // Compare against the last expected_blocks of sw_blocks
    size_t base = sw_blocks.size() - expected_blocks;
    for (size_t i = 0; i < expected_blocks; i++) {
        if (sw_blocks[base + i] != got_blocks[i]) {
            std::fprintf(stderr, "[%s] block %zu mismatch\n", label, i);
            std::fprintf(stderr, "  expected: ");
            for (int b = 0; b < 64; b++) std::fprintf(stderr, "%02x", sw_blocks[base+i][b]);
            std::fprintf(stderr, "\n  got:      ");
            for (int b = 0; b < 64; b++) std::fprintf(stderr, "%02x", got_blocks[i][b]);
            std::fprintf(stderr, "\n");
            return false;
        }
    }
    return true;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vsha256_padder_tb* dut = new Vsha256_padder_tb();
    reset(dut);

    std::printf("---- Test: padder FIPS-180-4 §5.1.1 conformance ----\n");

    // Cover all interesting tail lengths: 0 (empty), 1, 16, 55, 56, 57, 63
    static const size_t lens[] = {0, 1, 16, 55, 56, 57, 63};
    for (size_t L : lens) {
        std::vector<uint8_t> msg(L);
        for (size_t i = 0; i < L; i++) msg[i] = static_cast<uint8_t>(i);
        char label[64];
        std::snprintf(label, sizeof(label), "len=%zu", L);
        bool ok = run_tail(dut, msg.data(), L, label);
        if (ok) std::printf("  [PASS] %s\n", label);
        else  { std::printf("  [FAIL] %s\n", label); g_failures++; }
        // Reset padder state between cases for cleanliness
        reset(dut);
    }

    if (g_failures == 0) {
        std::printf("+PASS all padder tests passed\n");
        delete dut;
        return 0;
    } else {
        std::printf("+FAIL %d failures\n", g_failures);
        delete dut;
        return 1;
    }
}
