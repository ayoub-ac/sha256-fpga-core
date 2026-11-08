// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
// Verilator C++ harness for hmac_sha256. Drives RFC 4231 HMAC-SHA-256 test
// vectors and 100 random vectors cross-validated against Python's hmac.
//
// Build:  see Makefile  (`make sim-hmac` or `make test-hmac`)
// Output: prints "+PASS" or "+FAIL <reason>" so the Makefile can grep.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

#include "verilated.h"
#include "Vhmac_test.h"
#include "hmac_random_vectors.h"

// ---------------------------------------------------------------------------
// FIPS-180-4 §5.1.1 software padder (same routine as sim_main.cpp).
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// Wide-port helpers.
// data_block_i is 512 bits = 16 uint32_t words. Byte 0 of the block lives
// in bits [511:504] (word[15] bits[31:24]).
// key_i is 256 bits = 8 uint32_t words. Byte 0 of the key in bits [255:248].
// ---------------------------------------------------------------------------
static void write_block(uint32_t* port_words, const uint8_t* bytes64) {
    for (int i = 0; i < 16; i++) port_words[i] = 0;
    for (int i = 0; i < 64; i++) {
        int bit_hi = 511 - 8*i;
        int word   = bit_hi / 32;
        int shift  = bit_hi - word * 32 - 7;
        port_words[word] |= static_cast<uint32_t>(bytes64[i]) << shift;
    }
}

static void write_key(uint32_t* port_words, const uint8_t* key, size_t key_len) {
    // Key occupies bits [255 : 256-8*key_len]; rest are don't-care.
    for (int i = 0; i < 8; i++) port_words[i] = 0;
    for (size_t i = 0; i < key_len; i++) {
        int bit_hi = 255 - 8 * static_cast<int>(i);
        int word   = bit_hi / 32;
        int shift  = bit_hi - word * 32 - 7;
        port_words[word] |= static_cast<uint32_t>(key[i]) << shift;
    }
}

static std::string mac_to_hex(const uint32_t* port_words) {
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
// Sim primitives
// ---------------------------------------------------------------------------
static vluint64_t g_time = 0;
static int g_failures = 0;

static void tick(Vhmac_test* dut) {
    dut->clk_i = 0;
    dut->eval();
    g_time++;
    dut->clk_i = 1;
    dut->eval();
    g_time++;
}

static void reset(Vhmac_test* dut) {
    dut->rst_ni       = 0;
    dut->data_valid_i = 0;
    dut->data_last_i  = 0;
    dut->key_len_i    = 0;
    for (int i = 0; i < 8;  i++) dut->key_i[i]        = 0;
    for (int i = 0; i < 16; i++) dut->data_block_i[i] = 0;
    for (int i = 0; i < 4;  i++) tick(dut);
    dut->rst_ni = 1;
    tick(dut);
}

// Compute one HMAC. Holds key stable from before the first data block until
// after mac_valid_o. Returns the MAC as a 64-char hex string.
static std::string run_hmac(Vhmac_test* dut,
                            const uint8_t* key, size_t key_len_bytes,
                            const uint8_t* msg, size_t msg_len_bytes,
                            const char* label, int max_total_cycles = 50000) {
    // Clamp key length to <=32 bytes (256 bits) per the wrapper's contract.
    if (key_len_bytes > 32) {
        std::fprintf(stderr, "[%s] key_len %zu > 32 bytes, clamping (test bug)\n",
                     label, key_len_bytes);
        key_len_bytes = 32;
    }

    // Drive key BEFORE the FSM leaves IDLE; latched_key is sampled while in
    // H_IDLE. Hold it stable through the inner-key block dispatch as well.
    write_key(dut->key_i, key, key_len_bytes);
    dut->key_len_i = static_cast<uint16_t>(key_len_bytes * 8);

    // Pad the message in software for HMAC's inner hash. The inner hash sees
    // (K' XOR ipad) || M; the wrapper feeds the K'^ipad block on its own,
    // so we only feed the M portion. The length encoded in the trailing 64
    // bits of the FIPS-180-4 padding must reflect the FULL inner-hash
    // message length, including the K'^ipad block (= 64 bytes / 512 bits)
    // plus M.
    //
    // Build the padded inner message: 512 bits of K'^ipad implicit + M +
    // padding. We DO NOT include the K'^ipad bytes ourselves (the wrapper
    // does), but we MUST account for them in the length field.
    //
    // Strategy: pad as if the message were 512 + 8*msg_len bits long, but
    // place only the M bytes in the buffer, starting where the padded
    // version of M alone would start within block boundaries. Since M
    // starts on a 512-bit boundary (after the K'^ipad block), the byte
    // positions within blocks are the same as if we were padding M alone -
    // we only need to bump the length field.

    uint64_t inner_total_bits = 512 + static_cast<uint64_t>(msg_len_bytes) * 8;
    size_t   tail   = msg_len_bytes % 64;
    size_t   pad_bytes = (tail < 56) ? (56 - tail) : ((64 - tail) + 56);
    size_t   total = msg_len_bytes + pad_bytes + 8;

    std::vector<uint8_t> buf(total, 0);
    if (msg_len_bytes > 0) std::memcpy(buf.data(), msg, msg_len_bytes);
    buf[msg_len_bytes] = 0x80;
    for (int k = 0; k < 8; k++) {
        buf[total - 8 + k] = (inner_total_bits >> (56 - 8*k)) & 0xff;
    }

    std::vector<std::vector<uint8_t>> blocks;
    for (size_t i = 0; i < total; i += 64) {
        blocks.emplace_back(buf.begin() + i, buf.begin() + i + 64);
    }

    int cycles_used = 0;
    // Present the FIRST block + data_valid before the FSM leaves H_IDLE,
    // so the wrapper sees the request and latches the key on its way out.
    // Subsequent blocks are presented when ready_o asserts in H_ACCEPT_DATA.
    for (size_t b = 0; b < blocks.size(); b++) {
        bool is_last = (b == blocks.size() - 1);

        write_block(dut->data_block_i, blocks[b].data());
        dut->data_last_i  = is_last ? 1 : 0;
        dut->data_valid_i = 1;

        // Wait for ready_o (in H_IDLE the wrapper now asserts ready_o on
        // the cycle it accepts; in H_ACCEPT_DATA same).
        // For block 0 we need at least one tick for the FSM to leave IDLE
        // and dispatch the inner-key block (which does not need our data
        // yet). Once we get ready_o high in H_ACCEPT_DATA, the data is
        // accepted on the next rising edge.
        while (!dut->ready_o) {
            tick(dut);
            if (++cycles_used > max_total_cycles) {
                std::fprintf(stderr, "[%s] timeout waiting for ready_o block %zu\n",
                             label, b);
                g_failures++;
                return "";
            }
        }
        // ready_o is high → transfer accepted on this rising edge.
        tick(dut);
        cycles_used++;
        dut->data_valid_i = 0;
        dut->data_last_i  = 0;
        for (int i = 0; i < 16; i++) dut->data_block_i[i] = 0;
    }

    // Wait for mac_valid_o
    while (!dut->mac_valid_o) {
        tick(dut);
        if (++cycles_used > max_total_cycles) {
            std::fprintf(stderr, "[%s] timeout waiting for mac_valid_o\n", label);
            g_failures++;
            return "";
        }
    }
    std::string mac = mac_to_hex(dut->mac_o);

    // Consume mac_valid_o (it pulses for one cycle)
    tick(dut);

    return mac;
}

// ---------------------------------------------------------------------------
// RFC 4231 HMAC-SHA-256 test vectors. Section 4.x.
// All 7 vectors. Cases 6 and 7 have keys longer than 64 bytes (they exceed
// the wrapper's 256-bit key cap), so this implementation pre-hashes those
// keys in software (per RFC 2104: K' = H(K) when |K| > B), and presents
// the 256-bit hashed key to the wrapper.
// ---------------------------------------------------------------------------
struct Rfc4231 {
    const char* name;
    const uint8_t* key;
    size_t         key_len;       // bytes (logical, before any pre-hash)
    const uint8_t* msg;
    size_t         msg_len;
    const char*    mac_hex;
};

static const uint8_t kKey1[] = {
    0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,
    0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,
    0x0b,0x0b,0x0b,0x0b
};
static const uint8_t kMsg1[] = "Hi There";

static const uint8_t kKey2[] = "Jefe";
static const uint8_t kMsg2[] = "what do ya want for nothing?";

static const uint8_t kKey3[] = {
    0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,
    0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,
    0xaa,0xaa,0xaa,0xaa
};
static const uint8_t kMsg3[50] = {
    0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,
    0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,
    0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,
    0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,
    0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd,0xdd
};

static const uint8_t kKey4[] = {
    0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,
    0x0b,0x0c,0x0d,0x0e,0x0f,0x10,0x11,0x12,0x13,0x14,
    0x15,0x16,0x17,0x18,0x19
};
static const uint8_t kMsg4[50] = {
    0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,
    0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,
    0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,
    0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,
    0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd,0xcd
};

static const uint8_t kKey5[] = {
    0x0c,0x0c,0x0c,0x0c,0x0c,0x0c,0x0c,0x0c,
    0x0c,0x0c,0x0c,0x0c,0x0c,0x0c,0x0c,0x0c,
    0x0c,0x0c,0x0c,0x0c
};
static const uint8_t kMsg5[] = "Test With Truncation";

// Cases 6 / 7 use 131-byte keys. Per RFC 2104, when |K| > B the key is
// pre-hashed: K' = H(K). Our wrapper caps key length at 256 bits, so we
// pre-compute SHA-256 of the 131-byte key in software and pass the 32-byte
// digest as the wrapper's key. Resulting MAC matches the RFC 4231 reference.
//   sha256(b'\xaa'*131).hexdigest() =
//     45ad4b37c6e2fc0a2cfcc1b5da524132ec707615c2cae1dbbc43c97aa521db81
static const uint8_t kKey6_hashed[32] = {
    0x45,0xad,0x4b,0x37,0xc6,0xe2,0xfc,0x0a,
    0x2c,0xfc,0xc1,0xb5,0xda,0x52,0x41,0x32,
    0xec,0x70,0x76,0x15,0xc2,0xca,0xe1,0xdb,
    0xbc,0x43,0xc9,0x7a,0xa5,0x21,0xdb,0x81
};
static const uint8_t kMsg6[] = "Test Using Larger Than Block-Size Key - Hash Key First";

static const uint8_t kMsg7[] =
    "This is a test using a larger than block-size key and a larger than "
    "block-size data. The key needs to be hashed before being used by the "
    "HMAC algorithm.";

static const Rfc4231 kRfc4231Vectors[] = {
    {"RFC4231 #1 (20-byte key, 'Hi There')",
     kKey1, sizeof(kKey1), kMsg1, sizeof(kMsg1) - 1,
     "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"},
    {"RFC4231 #2 ('Jefe' key, 28-byte msg)",
     kKey2, sizeof(kKey2) - 1, kMsg2, sizeof(kMsg2) - 1,
     "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"},
    {"RFC4231 #3 (20 0xaa key, 50 0xdd msg)",
     kKey3, sizeof(kKey3), kMsg3, sizeof(kMsg3),
     "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"},
    {"RFC4231 #4 (25-byte key 0x01..19, 50 0xcd msg)",
     kKey4, sizeof(kKey4), kMsg4, sizeof(kMsg4),
     "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"},
    {"RFC4231 #5 (truncation test, full 32-byte MAC)",
     kKey5, sizeof(kKey5), kMsg5, sizeof(kMsg5) - 1,
     // Note: RFC 4231 truncates this to 128 bits. We compare the full 256
     // bits against the un-truncated reference (computed via Python).
     "a3b6167473100ee06e0c796c2955552bfa6f7c0a6a8aef8b93f860aab0cd20c5"},
    {"RFC4231 #6 (131-byte 0xaa key pre-hashed, short msg)",
     kKey6_hashed, sizeof(kKey6_hashed), kMsg6, sizeof(kMsg6) - 1,
     // Reference: hmac.new(b'\xaa'*131, msg, sha256). With pre-hashed key
     // this matches HMAC's K' = H(K) branch. The expected MAC equals the
     // RFC 4231 case 6 reference.
     "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"},
    {"RFC4231 #7 (131-byte 0xaa key pre-hashed, long msg)",
     kKey6_hashed, sizeof(kKey6_hashed), kMsg7, sizeof(kMsg7) - 1,
     "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"},
};

static constexpr int kNumRfc4231 = sizeof(kRfc4231Vectors) / sizeof(kRfc4231Vectors[0]);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
static void test_rfc4231(Vhmac_test* dut) {
    std::printf("---- Test 1: RFC 4231 HMAC-SHA-256 vectors ----\n");
    for (int i = 0; i < kNumRfc4231; i++) {
        const Rfc4231& v = kRfc4231Vectors[i];
        std::string got = run_hmac(dut, v.key, v.key_len, v.msg, v.msg_len, v.name);
        if (got == v.mac_hex) {
            std::printf("  [PASS] %s\n", v.name);
        } else {
            std::printf("  [FAIL] %s\n", v.name);
            std::printf("         expected %s\n", v.mac_hex);
            std::printf("         got      %s\n", got.c_str());
            g_failures++;
        }
    }
}

static void test_random(Vhmac_test* dut) {
    std::printf("---- Test 2: 100 random vs hmac/hashlib ----\n");
    int passes = 0, fails = 0;
    for (size_t i = 0; i < kHmacRandomVectorCount; i++) {
        const HmacVec& v = kHmacRandomVectors[i];
        std::string got = run_hmac(dut, v.key, v.key_len, v.msg, v.msg_len, "random");
        if (got == v.mac_hex) {
            passes++;
        } else {
            fails++;
            if (fails <= 3) {
                std::printf("  [FAIL] random #%zu key_len=%zu msg_len=%zu\n",
                            i, v.key_len, v.msg_len);
                std::printf("         expected %s\n", v.mac_hex);
                std::printf("         got      %s\n", got.c_str());
            }
        }
    }
    std::printf("  random: %d / %zu pass\n", passes, kHmacRandomVectorCount);
    if (fails > 0) g_failures += fails;
}

static void test_edge_keys(Vhmac_test* dut) {
    std::printf("---- Test 3: edge cases (zero-length key, max-length key, max msg) ----\n");

    // Zero-length key (key_len_i = 0). hmac.new(b'', msg, sha256).
    {
        const uint8_t k[1] = {0};
        const uint8_t m[]  = "edge-zero-key";
        // hmac.new(b'', b'edge-zero-key', sha256).hexdigest()
        const char* expected =
            "be62ab9ed5f93ba308fdee74bfcea3b45363706b8b378c29d1dbde276d7e5f80";
        std::string got = run_hmac(dut, k, 0, m, sizeof(m) - 1, "zero-key");
        if (got == expected) {
            std::printf("  [PASS] zero-length key\n");
        } else {
            std::printf("  [FAIL] zero-length key\n");
            std::printf("         expected %s\n", expected);
            std::printf("         got      %s\n", got.c_str());
            g_failures++;
        }
    }

    // Max-length key (32 bytes / 256 bits) — all 0xff.
    {
        uint8_t k[32];
        std::memset(k, 0xff, sizeof(k));
        const uint8_t m[] = "edge-max-key";
        // hmac.new(b'\xff'*32, b'edge-max-key', sha256).hexdigest()
        const char* expected =
            "f9f98891157ae2ca4d7fead0b410fffee19124727e5284777855577697e15cb6";
        std::string got = run_hmac(dut, k, sizeof(k), m, sizeof(m) - 1, "max-key");
        if (got == expected) {
            std::printf("  [PASS] max-length (256-bit) key\n");
        } else {
            std::printf("  [FAIL] max-length (256-bit) key\n");
            std::printf("         expected %s\n", expected);
            std::printf("         got      %s\n", got.c_str());
            g_failures++;
        }
    }

    // Long message (1024 bytes of 'A') with a 16-byte key.
    {
        const uint8_t k[16] = {
            0x01,0x23,0x45,0x67,0x89,0xab,0xcd,0xef,
            0xfe,0xdc,0xba,0x98,0x76,0x54,0x32,0x10
        };
        std::vector<uint8_t> m(1024, 0x41);
        // hmac.new(k, b'A'*1024, sha256).hexdigest()
        const char* expected =
            "ed0c7c6439cd5a4d3a95e3f163488fff663f6fafc5ef86478056cd4ccc667378";
        std::string got = run_hmac(dut, k, sizeof(k), m.data(), m.size(), "long-msg");
        if (got == expected) {
            std::printf("  [PASS] 1024-byte message\n");
        } else {
            std::printf("  [FAIL] 1024-byte message\n");
            std::printf("         expected %s\n", expected);
            std::printf("         got      %s\n", got.c_str());
            g_failures++;
        }
    }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vhmac_test* dut = new Vhmac_test();
    reset(dut);

    test_rfc4231(dut);
    test_edge_keys(dut);
    test_random(dut);

    if (g_failures == 0) {
        std::printf("+PASS all hmac tests passed\n");
        delete dut;
        return 0;
    } else {
        std::printf("+FAIL %d hmac failures\n", g_failures);
        delete dut;
        return 1;
    }
}
