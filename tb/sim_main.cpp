// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
// Verilator C++ harness for sha256_core. Drives FIPS-180-4 / NIST CAVP test
// vectors against the DUT and verifies digest, multi-block streaming,
// reset-mid-hash behavior, and back-to-back hashing.
//
// This harness pads messages in software (per FIPS-180-4 §5.1.1) and feeds
// the resulting 512-bit blocks into the core. The core is responsible for
// the actual SHA-256 computation; software padding lets us isolate the core
// from the padder for first-principles verification.
//
// Build: see Makefile (`make sim` or `make test`).
// Output: prints "+PASS" or "+FAIL <reason>" so the Makefile can grep.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

#include "verilated.h"
#include "Vsha256_core_tb.h"
#include "Vsha256_core_tb___024root.h"
#include "Vsha256_core_tb_sha256_core_tb.h"
#include "Vsha256_core_tb_sha256_core_cov.h"
#include "random_vectors.h"

// ---------------------------------------------------------------------------
// Software SHA-256 padder (FIPS-180-4 §5.1.1).
// Returns a vector of 64-byte blocks. The first byte of the message ends up
// in the most-significant byte of the first block (block 0, byte 0).
// ---------------------------------------------------------------------------
static std::vector<std::vector<uint8_t>>
sw_pad(const uint8_t* msg, size_t msg_len) {
    // Total length after padding = ceil((msg_len + 1 + 8) / 64) * 64.
    uint64_t L_bits = static_cast<uint64_t>(msg_len) * 8;
    size_t   tail   = msg_len % 64;
    size_t   pad_bytes;
    if (tail < 56) {
        pad_bytes = 56 - tail;            // 0x80 + zeros until byte 56
    } else {
        pad_bytes = (64 - tail) + 56;     // 0x80 + zeros, then full block of zeros up to byte 56
    }
    size_t total = msg_len + pad_bytes + 8;

    std::vector<uint8_t> buf(total, 0);
    if (msg_len > 0) std::memcpy(buf.data(), msg, msg_len);
    buf[msg_len] = 0x80;
    // 64-bit big-endian length appended at end
    for (int k = 0; k < 8; k++) {
        buf[total - 8 + k] = (L_bits >> (56 - 8*k)) & 0xff;
    }

    // Slice into 64-byte blocks
    std::vector<std::vector<uint8_t>> out;
    for (size_t i = 0; i < total; i += 64) {
        out.emplace_back(buf.begin() + i, buf.begin() + i + 64);
    }
    return out;
}

// ---------------------------------------------------------------------------
// 256-bit / 512-bit helpers. Verilator stores wide signals as uint32_t[N]
// with word[0] = bits [31:0]. For our 512-bit block_i (16 words) and 256-bit
// digest_o (8 words), we map MSB-first byte layout: byte 0 of the input is
// in bits [511:504] of block_i, which is word[15] bits [31:24].
// ---------------------------------------------------------------------------
static void write_block_i(uint32_t* port_words, const uint8_t* bytes64) {
    // Byte index `i` lives in bits [511 - 8*i -: 8].
    // Word index = (511 - 8*i) / 32 ; shift = (511 - 8*i) % 32 - 7.
    for (int i = 0; i < 16; i++) port_words[i] = 0;
    for (int i = 0; i < 64; i++) {
        int bit_hi = 511 - 8*i;
        int word   = bit_hi / 32;
        int shift  = bit_hi - word * 32 - 7;
        port_words[word] |= static_cast<uint32_t>(bytes64[i]) << shift;
    }
}

static std::string digest_to_hex(const uint32_t* port_words) {
    // digest_o is 256 bits = 8 words. word[7] = bits [255:224] = first 32 bits
    // of the digest in canonical FIPS notation (which is H[0]).
    char buf[65];
    for (int byte = 0; byte < 32; byte++) {
        int bit_hi = 255 - 8*byte;
        int word   = bit_hi / 32;
        int shift  = bit_hi - word * 32 - 7;
        unsigned b = (port_words[word] >> shift) & 0xff;
        std::snprintf(buf + 2*byte, 3, "%02x", b);
    }
    buf[64] = 0;
    return std::string(buf);
}

// ---------------------------------------------------------------------------
// Simulation primitives
// ---------------------------------------------------------------------------
static vluint64_t g_time = 0;
static int g_failures = 0;

static void tick(Vsha256_core_tb* dut) {
    dut->clk_i = 0;
    dut->eval();
    g_time++;
    dut->clk_i = 1;
    dut->eval();
    g_time++;
}

static void reset(Vsha256_core_tb* dut) {
    dut->rst_ni  = 0;
    dut->init_i  = 0;
    dut->next_i  = 0;
    dut->valid_i = 0;
    for (int i = 0; i < 16; i++) dut->block_i[i] = 0;
    for (int i = 0; i < 4;  i++) tick(dut);
    dut->rst_ni = 1;
    tick(dut);
}

// Run a single message through the core. Pads in software, feeds blocks
// one at a time. Returns the digest as a 64-character hex string.
static std::string run_msg(Vsha256_core_tb* dut,
                           const uint8_t* msg, size_t msg_len,
                           const char* label, int max_cycles_per_block = 200) {
    auto blocks = sw_pad(msg, msg_len);
    std::string digest_hex;

    for (size_t b = 0; b < blocks.size(); b++) {
        const bool is_first = (b == 0);

        // Wait for ready_o
        int waited = 0;
        while (!dut->ready_o) {
            tick(dut);
            if (++waited > max_cycles_per_block) {
                std::fprintf(stderr, "[%s] timeout waiting for ready_o on block %zu\n",
                             label, b);
                g_failures++;
                return "";
            }
        }

        write_block_i(dut->block_i, blocks[b].data());
        dut->init_i  = is_first ? 1 : 0;
        dut->next_i  = is_first ? 0 : 1;
        dut->valid_i = 1;
        tick(dut);
        dut->init_i  = 0;
        dut->next_i  = 0;
        dut->valid_i = 0;
        for (int i = 0; i < 16; i++) dut->block_i[i] = 0;

        // Wait for valid_o
        waited = 0;
        while (!dut->valid_o) {
            tick(dut);
            if (++waited > max_cycles_per_block) {
                std::fprintf(stderr, "[%s] timeout waiting for valid_o on block %zu\n",
                             label, b);
                g_failures++;
                return "";
            }
        }

        digest_hex = digest_to_hex(dut->digest_o);

        // Consume valid_o (it pulses for one cycle)
        tick(dut);
    }

    return digest_hex;
}

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------
struct NistVec {
    const char* name;
    const char* msg_ascii;   // if non-null, take ascii bytes; else use msg_hex
    const char* msg_hex;
    const char* digest_hex;
};

static const NistVec kFipsVectors[] = {
    {
        "FIPS-180-4 App.B.1 (\"abc\")",
        "abc", nullptr,
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    },
    {
        "Empty message",
        "", nullptr,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    },
    {
        "FIPS-180-4 App.B.2 (448-bit)",
        "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", nullptr,
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    },
};
static constexpr int kNumFips = sizeof(kFipsVectors) / sizeof(kFipsVectors[0]);

// NIST CAVP SHA256ShortMsg.rsp — selected entries.
// Source: csrc.nist.gov, Cryptographic Algorithm Validation Program.
// Format: msg_hex is the message in hex; if msg_bits == 0, msg_hex is empty.
struct CavpVec {
    const char* name;
    int         msg_bits;
    const char* msg_hex;
    const char* digest_hex;
};

static const CavpVec kCavpVectors[] = {
    {"CAVP SHA256ShortMsg L=8",   8,
     "d3",
     "28969cdfa74a12c82f3bad960b0b000aca2ac329deea5c2328ebc6f2ba9802c1"},
    {"CAVP SHA256ShortMsg L=16",  16,
     "11af",
     "5ca7133fa735326081558ac312c620eeca9970d1e70a4b95533d956f072d1f98"},
    {"CAVP SHA256ShortMsg L=24",  24,
     "b4190e",
     "dff2e73091f6c05e528896c4c831b9448653dc2ff043528f6769437bc7b975c2"},
    {"CAVP SHA256ShortMsg L=80",  80,
     "74cb9381d89f5aa73368",
     "73d6fad1caaa75b43b21733561fd3958bdc555194a037c2addec19dc2d7a52bd"},
    {"CAVP SHA256ShortMsg L=128", 128,
     "0a27847cdc98bd6f62220b046edd762b",
     "80c25ec1600587e7f28b18b1b18e3cdc89928e39cab3bc25e4d4a4c139bcedc4"},
    {"CAVP SHA256ShortMsg L=256", 256,
     "5a86b737eaea8ee976a0a24da63e7ed7eefad18a101c1211e2b3650c5187c2a8",
     "790c8db3ac3ae6f88b4ad076855de48ab0799fa5d2ea5bcf37ac324dcfa70a2e"},
    {"CAVP SHA256ShortMsg L=512 (one full block)", 512,
     "5a86b737eaea8ee976a0a24da63e7ed7eefad18a101c1211e2b3650c5187c2a8a650547208251f6d4237e661c7bf4c77f335390394c37fa1a9f9be836ac28509",
     "42e61e174fbb3897d6dd6cef3dd2802fe67b331953b06114a65c772859dfc1aa"},
    {"CAVP SHA256ShortMsg L=520 (just over one block)", 520,
     "5a86b737eaea8ee976a0a24da63e7ed7eefad18a101c1211e2b3650c5187c2a8a650547208251f6d4237e661c7bf4c77f335390394c37fa1a9f9be836ac285093d",
     "4028067fe71d399f15537eacc69511ac3a2a6e5c2c488a0c04a19029a4d40153"},
    {"CAVP SHA256ShortMsg L=1304 (multi-block)", 1304,
     "451101250ec6f26652249d59dc974b7361d571a8101cdfd36aba3b5854d3ae086b5fdd4597721b66e3c0dc5d8c606d9657d0e323283a5217d1f53f2f284f57b85c8a61ac8924711f895c5ed90ef17745ed2d728abd22a5f7a13479a462d71b56c19a74a40b655c58edfe0a188ad2cf46cbf30524f65d423c837dd1ff2bf462ac4198007345bb44dbb7b1c861298cdf61982a833afc728fae1eda2f87aa2c9480858bec",
     "3c593aa539fdcdae516cdf2f15000f6634185c88f505b39775fb9ab137a10aa2"},
};

static constexpr int kNumCavp = sizeof(kCavpVectors) / sizeof(kCavpVectors[0]);

// ---------------------------------------------------------------------------
// Hex parsing helper
// ---------------------------------------------------------------------------
static std::vector<uint8_t> hex_to_bytes(const char* hex) {
    std::vector<uint8_t> out;
    if (!hex) return out;
    size_t len = std::strlen(hex);
    out.reserve(len / 2);
    for (size_t i = 0; i + 1 < len; i += 2) {
        unsigned v;
        if (std::sscanf(hex + i, "%2x", &v) != 1) {
            std::fprintf(stderr, "bad hex byte at %zu in '%s'\n", i, hex);
            return out;
        }
        out.push_back(static_cast<uint8_t>(v));
    }
    return out;
}

// ---------------------------------------------------------------------------
// Test cases
// ---------------------------------------------------------------------------
static void test_fips_vectors(Vsha256_core_tb* dut) {
    std::printf("---- Test 1: FIPS-180-4 Appendix B vectors ----\n");
    for (int i = 0; i < kNumFips; i++) {
        const NistVec& v = kFipsVectors[i];
        std::vector<uint8_t> msg;
        size_t msg_len;
        if (v.msg_ascii != nullptr) {
            msg.assign(v.msg_ascii, v.msg_ascii + std::strlen(v.msg_ascii));
            msg_len = msg.size();
        } else {
            msg = hex_to_bytes(v.msg_hex);
            msg_len = msg.size();
        }
        std::string got = run_msg(dut, msg.data(), msg_len, v.name);
        if (got == v.digest_hex) {
            std::printf("  [PASS] %s\n", v.name);
        } else {
            std::printf("  [FAIL] %s\n", v.name);
            std::printf("         expected %s\n", v.digest_hex);
            std::printf("         got      %s\n", got.c_str());
            g_failures++;
        }
    }
}

static void test_cavp_vectors(Vsha256_core_tb* dut) {
    std::printf("---- Test 2: NIST CAVP SHA256ShortMsg vectors ----\n");
    for (int i = 0; i < kNumCavp; i++) {
        const CavpVec& v = kCavpVectors[i];
        std::vector<uint8_t> msg = hex_to_bytes(v.msg_hex);
        std::string got = run_msg(dut, msg.data(), msg.size(), v.name);
        if (got == v.digest_hex) {
            std::printf("  [PASS] %s\n", v.name);
        } else {
            std::printf("  [FAIL] %s\n", v.name);
            std::printf("         expected %s\n", v.digest_hex);
            std::printf("         got      %s\n", got.c_str());
            g_failures++;
        }
    }
}

static void test_random_vectors(Vsha256_core_tb* dut) {
    std::printf("---- Test 3: Cross-validation against hashlib (1000 random) ----\n");
    int passes = 0;
    int fails  = 0;
    for (size_t i = 0; i < kRandomVectorCount; i++) {
        const RandomVec& v = kRandomVectors[i];
        std::string got = run_msg(dut, v.msg, v.msg_len, "random");
        if (got == v.digest_hex) {
            passes++;
        } else {
            fails++;
            if (fails <= 3) {
                std::printf("  [FAIL] random #%zu len=%zu\n", i, v.msg_len);
                std::printf("         expected %s\n", v.digest_hex);
                std::printf("         got      %s\n", got.c_str());
            }
        }
    }
    std::printf("  random: %d / %zu pass\n", passes, kRandomVectorCount);
    if (fails > 0) g_failures += fails;
}

static void test_multi_block(Vsha256_core_tb* dut) {
    std::printf("---- Test 4: Multi-block (long messages) ----\n");
    // Hash a 1024-byte message of 0x41 ('A')
    std::vector<uint8_t> msg(1024, 0x41);
    // hashlib.sha256(b'A' * 1024).hexdigest()
    const char* expected =
        "6ab72eeb9e77b07540897e0c8d6d23ec8eef0f8c3a47e1b3f4e93443d9536bed";
    std::string got = run_msg(dut, msg.data(), msg.size(), "1024xA");
    if (got == expected) {
        std::printf("  [PASS] 1024-byte all-0x41\n");
    } else {
        std::printf("  [FAIL] 1024-byte all-0x41\n");
        std::printf("         expected %s\n", expected);
        std::printf("         got      %s\n", got.c_str());
        g_failures++;
    }
}

static void test_back_to_back(Vsha256_core_tb* dut) {
    std::printf("---- Test 5: Back-to-back hashing (init -> blocks -> init) ----\n");
    const char* m1 = "abc";
    const char* m2 = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    const char* d1 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const char* d2 = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1";

    std::string got1 = run_msg(dut,
                               reinterpret_cast<const uint8_t*>(m1),
                               std::strlen(m1), "back-to-back #1");
    std::string got2 = run_msg(dut,
                               reinterpret_cast<const uint8_t*>(m2),
                               std::strlen(m2), "back-to-back #2");
    if (got1 == d1 && got2 == d2) {
        std::printf("  [PASS] back-to-back hashes preserved correctly\n");
    } else {
        std::printf("  [FAIL] back-to-back\n");
        if (got1 != d1) {
            std::printf("    #1 expected %s\n    #1 got      %s\n", d1, got1.c_str());
        }
        if (got2 != d2) {
            std::printf("    #2 expected %s\n    #2 got      %s\n", d2, got2.c_str());
        }
        g_failures++;
    }
}

static void test_reset_mid_hash(Vsha256_core_tb* dut) {
    std::printf("---- Test 6: Reset mid-hash, then re-hash cleanly ----\n");
    // Start a long hash, abort mid-way with reset, then hash a known message.
    std::vector<uint8_t> long_msg(2000, 0x55);
    auto blocks = sw_pad(long_msg.data(), long_msg.size());
    // Feed first block, wait for valid_o, then DO NOT consume — instead
    // feed second block while it's still busy (the FSM will not accept).
    int waited = 0;
    while (!dut->ready_o) { tick(dut); if (++waited > 100) break; }
    write_block_i(dut->block_i, blocks[0].data());
    dut->init_i  = 1;
    dut->next_i  = 0;
    dut->valid_i = 1;
    tick(dut);
    dut->init_i  = 0;
    dut->valid_i = 0;
    for (int i = 0; i < 16; i++) dut->block_i[i] = 0;
    // Wait a few cycles, then yank the reset
    for (int i = 0; i < 30; i++) tick(dut);
    reset(dut);

    // Now run "abc" — should give the canonical digest.
    const char* m = "abc";
    const char* expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    std::string got = run_msg(dut, reinterpret_cast<const uint8_t*>(m),
                              std::strlen(m), "post-reset abc");
    if (got == expected) {
        std::printf("  [PASS] post-reset hash correct\n");
    } else {
        std::printf("  [FAIL] post-reset hash\n");
        std::printf("         expected %s\n", expected);
        std::printf("         got      %s\n", got.c_str());
        g_failures++;
    }
}

static void test_single_byte(Vsha256_core_tb* dut) {
    std::printf("---- Test 7: Single-byte input edge case ----\n");
    // sha256(b'\xbd') = 68325720aabd7c82f30f554b313d0570c95accbb7dc4b5aae11204c08ffe732b
    const uint8_t msg[1] = {0xbd};
    const char* expected =
        "68325720aabd7c82f30f554b313d0570c95accbb7dc4b5aae11204c08ffe732b";
    std::string got = run_msg(dut, msg, 1, "single byte");
    if (got == expected) {
        std::printf("  [PASS] single-byte 0xbd\n");
    } else {
        std::printf("  [FAIL] single-byte 0xbd\n");
        std::printf("         expected %s\n", expected);
        std::printf("         got      %s\n", got.c_str());
        g_failures++;
    }
}

// ---------------------------------------------------------------------------
// Functional coverage report. Reads the per-bin flags from the coverage
// collector via Verilator's flat-public-rw access and prints a coverage line.
// ---------------------------------------------------------------------------
static void report_coverage(const Vsha256_core_tb* dut) {
    auto* cov = dut->rootp->sha256_core_tb->u_cov;
    struct Bin { const char* name; uint8_t hit; };
    Bin bins[] = {
        {"state_idle",     cov->c_state_idle},
        {"state_run",      cov->c_state_run},
        {"state_update",   cov->c_state_update},
        {"state_done",     cov->c_state_done},
        {"single_block",   cov->c_single_block},
        {"multi_block",    cov->c_multi_block},
        {"back_to_back",   cov->c_back_to_back},
        {"reset_mid_hash", cov->c_reset_mid_hash},
    };
    int total = sizeof(bins) / sizeof(bins[0]);
    int hit = 0;
    std::printf("\n---- Functional coverage ----\n");
    for (int i = 0; i < total; i++) {
        std::printf("  [%s] %-15s\n", bins[i].hit ? "HIT " : "MISS", bins[i].name);
        if (bins[i].hit) hit++;
    }
    std::printf("Coverage: %d/%d bins (%.1f%%)\n",
                hit, total, 100.0 * hit / total);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vsha256_core_tb* dut = new Vsha256_core_tb();
    reset(dut);

    test_fips_vectors(dut);
    test_cavp_vectors(dut);
    test_multi_block(dut);
    test_back_to_back(dut);
    test_single_byte(dut);
    test_reset_mid_hash(dut);
    test_random_vectors(dut);   // longest, run last

    report_coverage(dut);

    if (g_failures == 0) {
        std::printf("+PASS all tests passed\n");
        delete dut;
        return 0;
    } else {
        std::printf("+FAIL %d failures\n", g_failures);
        delete dut;
        return 1;
    }
}
