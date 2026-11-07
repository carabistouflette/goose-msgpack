// SPDX-License-Identifier: Apache-2.0
// MPack performance reference for goose-msgpack.
//
// MPack (https://github.com/ludocode/mpack, pinned at
// c9d1820ecfdbc3954c60a218492251e457cc1f86, 1.1.1) is the C implementation that
// is explicitly designed and documented around performance. It is the relevant
// performance reference: if this library is slower than MPack on the same work,
// that is the number worth reporting.
//
//   cc -O2 -std=gnu11 -DMPACK_EXTENSIONS=1 -I <mpack>/src
//      bench/bench-mpack.c <mpack>/src/mpack/*.c -o bench-mpack
//
// MPACK_EXTENSIONS is enabled because goose-msgpack supports the ext family; a
// reference built without it would be comparing against a smaller library.
//   bench-mpack verify
//   bench-mpack checksum
//   bench-mpack macros
//   bench-mpack <batch> <ms>
//   bench-mpack contract <batch> <ms>
//   bench-mpack contract-wide <batch> <ms>
//
// Output contract, identical to bench/bench.goose so the same reader parses both:
//
//   verify    fixture <name> bytes <n> hex <hex>
//   checksum  sum <fixture> <op> <value>   |   na <fixture> <op>
//   time      time <fixture> <op> <n> <dt_ns>
//
// `n` and `dt_ns` are totals; the reader divides exactly once.
//
// What is compared, and what is not
// ---------------------------------
//
// The rows are the same ten as bench.goose: encode into a reused buffer and into
// a fresh one, decode with a fresh reader and with a reused one, and six
// invalid-input rows. The decode path is a **token traversal, not a DOM**: it
// uses mpack_read_tag() and skips payloads, so it never builds a tree. That is
// the comparable shape, because goose-msgpack is a token reader.
//
// Three columns, and what each one is allowed to claim
// ---------------------------------------------------
//
//   raw            MPack's tag API as a caller would use it: read a tag, skip
//                  the payload. No UTF-8 check, no budgets, no full-input
//                  check. This is the *matched valid workload*: same bytes,
//                  same rows, same traversal shape. It is NOT the same contract.
//   contract       The same traversal plus the checks a goose-msgpack caller
//                  gets from `msgpack::init(r, data)` with default Limits:
//                  input 1 MiB, 65536 nodes, depth 32, str/bin 256 KiB,
//                  container 65536, and exactly one root with no trailing
//                  bytes. Every budget is checked at the same point Goose
//                  checks it.
//   contract-wide  The same, with goose-msgpack's hard maxima instead
//                  (64 MiB, 1048576 nodes, depth 256, str/bin 16 MiB,
//                  container 1048576), which is what tests/triangulate.goose
//                  configures.
//
// The gap between `raw` and `contract` is the cost of the contract, measured
// rather than argued. The gap between `contract` and `contract-wide` is the
// cost of the wider limits, which should be zero: the checks are comparisons
// against constants, not work proportional to the limits.
//
// Where the contract genuinely differs, and why
// ---------------------------------------------
//
//   - **UTF-8.** MPack's default tag API does not validate a str payload:
//     mpack_skip_bytes() skips it. MPack *does* offer a checked API —
//     mpack_read_utf8_inplace() — and `contract` mode uses it. So "MPack does
//     not validate UTF-8" is true of the raw tag API and false of the library.
//     The checked call is a real cost and it is inside the measured loop.
//   - **Budgets.** MPack has no input, node, str, bin or container budget, so
//     `contract` mode implements them in the traversal. All of them are
//     constant-cost comparisons. A declared length CAN be refused before the
//     payload is read: mpack_read_tag() consumes only the header, so the
//     length is known and the payload is still unread. `contract` mode does
//     exactly that, at the same point Goose does it.
//   - **Full input.** MPack has no `finish`. The caller compares
//     mpack_reader_remaining() to zero, which is constant cost, and `contract`
//     mode does it.
//   - **Depth.** MPack's tracking stack (`mpack_track_t.elements`) is a
//     heap-allocated growable array, but it only exists when
//     MPACK_READ_TRACKING is 1, and that defaults to 0 unless MPACK_DEBUG is
//     on. The default build therefore does not allocate for tracking; the
//     `macros` mode prints the effective values so this is checked, not
//     assumed. goose-msgpack's frame stack is an inline i64[256] inside the
//     Reader value, so it never allocates either way.
//   - **Empty containers.** goose-msgpack's max_depth bounds open non-empty
//     frames, so an empty array or map does not consume depth. The traversal
//     here increments depth only for a non-empty container, which is the same
//     rule.
//
// The `macros` mode exists because a comparison against a debug build is not a
// comparison. It prints the effective MPACK_* values and the reader size, so
// the build under measurement is identified rather than assumed.
#include <mpack/mpack.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// ---------------------------------------------------------------------------
// Fixtures: the same five values bench/bench.goose builds, from the same table.
// ---------------------------------------------------------------------------

typedef struct {
    const char* name;
    uint32_t tasks;
    uint32_t edges;
    uint32_t members;
    uint32_t member_bytes;
} fixture_t;

static const fixture_t FIXTURES[] = {
    {"plan-small",     4,    3,    0,  0},
    {"plan-medium",   64,  128,    0,  0},
    {"plan-large",  1024, 4096,    0,  0},
    {"strings-16x32",  0,    0,   16, 32},
    {"strings-4x256",  0,    0,    4, 256},
};
#define FIXTURE_COUNT ((int)(sizeof(FIXTURES) / sizeof(FIXTURES[0])))

// The two goose-msgpack limit presets, copied from msgpack.goose so the budgets
// are the same numbers and not merely similar ones.
//
//   DEFAULT  struct Limits { .. }            -- what msgpack::init(r, data) uses
//   WIDEST   the MAX_* constants             -- what tests/triangulate.goose sets
//
// `contract` mode uses DEFAULT and `contract-wide` uses WIDEST, so the reader
// can see whether the limit values themselves cost anything.
typedef struct {
    uint64_t input_bytes;
    uint64_t nodes;
    uint64_t depth;
    uint64_t str_bytes;
    uint64_t bin_bytes;
    uint64_t container_len;
} limits_t;

static const limits_t LIMITS_DEFAULT = {
    1048576u, 65536u, 32u, 262144u, 262144u, 65536u,
};
static const limits_t LIMITS_WIDEST = {
    67108864u, 1048576u, 256u, 16777216u, 16777216u, 1048576u,
};

static void write_manifest(mpack_writer_t* w, const fixture_t* f) {
    uint32_t concurrency = f->tasks / 2;
    if (concurrency < 1) concurrency = 1;
    uint32_t modulus = f->tasks ? f->tasks : 1;

    mpack_start_map(w, 6);
    mpack_write_cstr(w, "format");
    mpack_write_cstr(w, "goose-task-plan");
    mpack_write_cstr(w, "version");
    mpack_write_uint(w, 1);
    mpack_write_cstr(w, "count");
    mpack_write_uint(w, f->tasks);
    mpack_write_cstr(w, "concurrency");
    mpack_write_uint(w, concurrency);
    mpack_write_cstr(w, "edges");
    mpack_start_array(w, f->edges);
    for (uint32_t i = 0; i < f->edges; i++) {
        mpack_start_array(w, 2);
        mpack_write_uint(w, i % modulus);
        mpack_write_uint(w, (i * 7u + 1u) % modulus);
        mpack_finish_array(w);
    }
    mpack_finish_array(w);
    mpack_write_cstr(w, "labels");
    mpack_start_map(w, f->members);
    // The filler is built once, outside the loop. Filling a 4096-byte buffer for
    // every member would make the comparator do work proportional to the buffer
    // rather than to the value, and a 32-byte member would pay 4096 bytes of
    // memset that goose-msgpack never does.
    static char pad[4096];
    static bool pad_ready = false;
    if (!pad_ready) {
        memset(pad, 'x', sizeof pad);
        pad_ready = true;
    }
    for (uint32_t i = 0; i < f->members; i++) {
        char key[16];
        int n = snprintf(key, sizeof key, "k%u", i);
        mpack_write_str(w, key, (uint32_t)n);
        // The value is `member_bytes` copies of 'x'.
        uint32_t left = f->member_bytes;
        mpack_start_str(w, left);
        while (left > 0) {
            uint32_t chunk = left < sizeof pad ? left : (uint32_t)sizeof pad;
            mpack_write_bytes(w, pad, chunk);
            left -= chunk;
        }
        mpack_finish_str(w);
    }
    mpack_finish_map(w);
    mpack_finish_map(w);
}

// Build one fixture into a growable buffer. Caller frees.
static char* build_fixture(const fixture_t* f, size_t* out_size) {
    char* data = NULL;
    size_t size = 0;
    mpack_writer_t writer;
    mpack_writer_init_growable(&writer, &data, &size);
    write_manifest(&writer, f);
    if (mpack_writer_destroy(&writer) != mpack_ok) {
        fprintf(stderr, "writer failed for %s\n", f->name);
        exit(2);
    }
    *out_size = size;
    return data;
}

// ---------------------------------------------------------------------------
// The traversal. Token stream, no DOM.
// ---------------------------------------------------------------------------

#define FNV_OFFSET 0xcbf29ce484222325ull
#define FNV_PRIME  0x100000001b3ull

typedef struct {
    uint64_t remaining;
    uint8_t is_map;
} frame_t;

// Fold one token into the running hash. `kind` is the tag type, `span` the bytes
// the token consumed. This is the anti-elimination barrier: it depends on every
// token, so the compiler cannot delete the traversal.
static inline uint64_t fold(uint64_t h, uint64_t kind, uint64_t span) {
    h = (h ^ kind) * FNV_PRIME;
    h = (h ^ span) * FNV_PRIME;
    return h;
}

// The first and last byte of a payload, so the fold depends on the content and
// not only on its length.
//
// Precondition: `len` bytes at `payload` are readable. The caller must have
// checked `mpack_reader_error` after the read or skip that produced them; a
// truncated payload leaves `payload` pointing at a buffer that is shorter than
// the declared length, and `payload[len - 1]` would then read past it.
static inline uint64_t sample(const char* payload, size_t len) {
    if (len == 0) return 0;
    return ((uint64_t)(uint8_t)payload[0] << 8) | (uint64_t)(uint8_t)payload[len - 1];
}

// Fold the **decoded value** of a tag, not only its kind and span.
//
// A barrier that folds only the kind and the span leaves the checksum unchanged
// for a reader that returns the right type at the right offset with the wrong
// value, so a broken decoder would benchmark as a fast one. `mutant` zeroes the
// value before folding, which is the negative control for exactly that failure.
static inline uint64_t fold_value(uint64_t h, const mpack_tag_t* tag,
                                  const char* payload, bool mutant) {
    uint64_t value = 0;
    uint64_t extra = 0;
    switch (tag->type) {
    case mpack_type_nil:    value = 0; break;
    case mpack_type_bool:   value = tag->v.b ? 1u : 0u; break;
    case mpack_type_int:    value = (uint64_t)tag->v.i; break;
    case mpack_type_uint:   value = tag->v.u; break;
    case mpack_type_float: {
        // The wire bits are the value; the equality bit makes the fold depend on
        // the decoded float and not only on the bytes it came from.
        uint32_t bits;
        memcpy(&bits, &tag->v.f, sizeof bits);
        value = bits;
        if (tag->v.f != tag->v.f) extra = 0xffff;  // NaN: no equality to check
        break;
    }
    case mpack_type_double: {
        uint64_t bits;
        memcpy(&bits, &tag->v.d, sizeof bits);
        value = bits;
        if (tag->v.d != tag->v.d) extra = 0xffff;
        break;
    }
    case mpack_type_str:
    case mpack_type_bin:
        value = (uint64_t)tag->v.l;
        extra = sample(payload, tag->v.l);
        break;
    case mpack_type_ext:
        value = ((uint64_t)(uint8_t)tag->exttype << 32) | (uint64_t)tag->v.l;
        extra = sample(payload, tag->v.l);
        break;
    case mpack_type_array:
    case mpack_type_map:
        value = (uint64_t)tag->v.n;
        break;
    default:
        break;
    }
    if (mutant) { value = 0; extra = 0; }
    h = (h ^ value) * FNV_PRIME;
    h = (h ^ extra) * FNV_PRIME;
    return h;
}

// Walk one document. Returns the fold, or a refusal code folded in.
//
// `lim` is NULL for the raw column (no budgets, no UTF-8 check, no full-input
// check) and a limits preset for the contract columns. Every budget is checked
// at the point goose-msgpack checks it:
//
//   input      before the reader is created
//   node       after the tag is read, before the payload
//   str / bin  after the tag is read, before the payload is taken
//   container  after the tag is read, before the frame is pushed
//   depth      when a non-empty container is pushed
//   full input after the root closes
//
// The declared-length checks are possible because mpack_read_tag() consumes
// only the header: the length is known and the payload is still unread.
// The refusal code of the last drain() call, or 0 if it accepted. The return
// value is a hash with the code folded in, so a caller that wants to know *why*
// a document was refused reads this instead of trying to un-XOR the hash.
static uint64_t g_refusal = 0;

static uint64_t drain(const char* data, size_t len, const limits_t* lim,
                      bool full_checksum, bool mutant) {
    g_refusal = 0;
    if (lim && (uint64_t)len > lim->input_bytes) { g_refusal = 0x1000; return 0x1000; }

    mpack_reader_t reader;
    mpack_reader_init_data(&reader, data, len);

    uint64_t h = FNV_OFFSET;
    uint64_t nodes = 0;
    uint64_t depth = 0;

    frame_t stack[512];
    int sp = 0;
    // 64-bit: a map's element count is doubled, and a 32-bit field would wrap
    // for a large map before the container budget could refuse it.
    uint64_t remaining = 1;
    uint8_t is_map = 0;

    for (;;) {
        if (remaining == 0) {
            if (sp == 0) break;
            if (is_map) mpack_done_map(&reader); else mpack_done_array(&reader);
            frame_t f = stack[--sp];
            remaining = f.remaining;
            is_map = f.is_map;
            if (lim) depth--;
            continue;
        }

        const char* rest = NULL;
        size_t before = mpack_reader_remaining(&reader, &rest);

        mpack_tag_t tag = mpack_read_tag(&reader);
        if (mpack_reader_error(&reader) != mpack_ok) {
            mpack_reader_destroy(&reader);
            g_refusal = 0x200;
            return h ^ 0x200;
        }
        remaining--;
        nodes++;
        if (lim && nodes > lim->nodes) {
            mpack_reader_destroy(&reader);
            g_refusal = 0x1001;
            return h ^ 0x1001;
        }

        // The header span: bytes the tag itself consumed. Payload bytes are
        // folded separately below, so this stays the token's own width.
        size_t span = before - mpack_reader_remaining(&reader, &rest);
        // The payload starts where the header ended, and is still unread.
        const char* payload = rest;

        switch (tag.type) {
        case mpack_type_nil:
        case mpack_type_bool:
        case mpack_type_int:
        case mpack_type_uint:
        case mpack_type_float:
        case mpack_type_double:
            h = fold(h, (uint64_t)tag.type, span);
            h = fold_value(h, &tag, payload, mutant);
            break;

        case mpack_type_str:
            // Declared length, refused before the payload is read.
            if (lim && (uint64_t)tag.v.l > lim->str_bytes) {
                mpack_reader_destroy(&reader);
                g_refusal = 0x1004;
                return h ^ 0x1004;
            }
            if (lim) {
                // The checked API: validates UTF-8 and flags mpack_error_data
                // on a bad sequence. This is the honest counterpart of
                // goose-msgpack's InvalidUtf8, and it is inside the loop.
                const char* p = mpack_read_utf8_inplace(&reader, tag.v.l);
                if (mpack_reader_error(&reader) != mpack_ok) {
                    mpack_reader_destroy(&reader);
                    g_refusal = 0x200;
                    return h ^ 0x200;
                }
                if (full_checksum) {
                    for (uint32_t i = 0; i < tag.v.l; i++) h = (h ^ (uint8_t)p[i]) * FNV_PRIME;
                }
            } else {
                mpack_skip_bytes(&reader, tag.v.l);
                // A truncated payload must be refused *before* anything samples
                // it. `sample()` reads the last declared byte, which is not in
                // the buffer when the skip ran off the end.
                if (mpack_reader_error(&reader) != mpack_ok) {
                    mpack_reader_destroy(&reader);
                    g_refusal = 0x200;
                    return h ^ 0x200;
                }
                // The payload has already been skipped; fold its length so the
                // checksum still depends on the content size.
                if (full_checksum) h = (h ^ tag.v.l) * FNV_PRIME;
            }
            mpack_done_str(&reader);
            if (mpack_reader_error(&reader) != mpack_ok) {
                mpack_reader_destroy(&reader);
                g_refusal = 0x200;
                return h ^ 0x200;
            }
            h = fold(h, (uint64_t)tag.type, span);
            h = fold_value(h, &tag, payload, mutant);
            break;

        case mpack_type_bin:
            if (lim && (uint64_t)tag.v.l > lim->bin_bytes) {
                mpack_reader_destroy(&reader);
                g_refusal = 0x1005;
                return h ^ 0x1005;
            }
            mpack_skip_bytes(&reader, tag.v.l);
            if (mpack_reader_error(&reader) != mpack_ok) {
                mpack_reader_destroy(&reader);
                g_refusal = 0x200;
                return h ^ 0x200;
            }
            if (full_checksum) h = (h ^ tag.v.l) * FNV_PRIME;
            mpack_done_bin(&reader);
            if (mpack_reader_error(&reader) != mpack_ok) {
                mpack_reader_destroy(&reader);
                g_refusal = 0x200;
                return h ^ 0x200;
            }
            h = fold(h, (uint64_t)tag.type, span);
            h = fold_value(h, &tag, payload, mutant);
            break;

        case mpack_type_ext:
            // goose-msgpack has no separate ext budget; an ext payload is
            // bounded by the input budget, which was checked up front.
            mpack_skip_bytes(&reader, tag.v.l);
            if (mpack_reader_error(&reader) != mpack_ok) {
                mpack_reader_destroy(&reader);
                g_refusal = 0x200;
                return h ^ 0x200;
            }
            if (full_checksum) h = (h ^ tag.v.l) * FNV_PRIME;
            mpack_done_ext(&reader);
            if (mpack_reader_error(&reader) != mpack_ok) {
                mpack_reader_destroy(&reader);
                g_refusal = 0x200;
                return h ^ 0x200;
            }
            h = fold(h, (uint64_t)tag.type, span);
            h = fold_value(h, &tag, payload, mutant);
            break;

        case mpack_type_array:
        case mpack_type_map: {
            h = fold(h, (uint64_t)tag.type, span);
            h = fold_value(h, &tag, payload, mutant);
            uint64_t count = tag.v.n;
            if (lim && count > lim->container_len) {
                mpack_reader_destroy(&reader);
                g_refusal = 0x1006;
                return h ^ 0x1006;
            }
            if (count == 0) {
                // An empty container does not consume depth, matching
                // goose-msgpack's rule that max_depth bounds open non-empty
                // frames.
                if (tag.type == mpack_type_map) mpack_done_map(&reader);
                else mpack_done_array(&reader);
                break;
            }
            if (lim) {
                depth++;
                if (depth > lim->depth) {
                    mpack_reader_destroy(&reader);
                    g_refusal = 0x1002;
                    return h ^ 0x1002;
                }
            }
            if (sp >= (int)(sizeof stack / sizeof stack[0])) {
                mpack_reader_destroy(&reader);
                g_refusal = 0x1007;
                return h ^ 0x1007;
            }
            stack[sp].remaining = remaining;
            stack[sp].is_map = is_map;
            sp++;
            // A map's element count is doubled here, after the container budget
            // has bounded it, so the multiplication cannot wrap.
            remaining = tag.type == mpack_type_map ? count * 2u : count;
            is_map = tag.type == mpack_type_map ? 1 : 0;
            break;
        }

        default:
            mpack_reader_destroy(&reader);
            g_refusal = 0x200;
            return h ^ 0x200;
        }

    }

    // Full-input contract: exactly one value, no trailing bytes.
    const char* rest = NULL;
    size_t left = mpack_reader_remaining(&reader, &rest);
    if (lim && left != 0) {
        mpack_reader_destroy(&reader);
        g_refusal = 0x1003;
        return h ^ 0x1003;
    }
    if (mpack_reader_destroy(&reader) != mpack_ok) { g_refusal = 0x200; return h ^ 0x200; }
    return h;
}

// ---------------------------------------------------------------------------
// Timing
// ---------------------------------------------------------------------------

static int64_t clock_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000ll + ts.tv_nsec;
}

// Globals the timed closures read, so the closures take no arguments.
static const char* g_data = NULL;
static size_t g_len = 0;
static char* g_out = NULL;
static size_t g_out_cap = 0;
static const fixture_t* g_fixture = NULL;
static const limits_t* g_lim = NULL;
static bool g_mutant = false;

static uint64_t enc_reused(void) {
    mpack_writer_t w;
    mpack_writer_init(&w, g_out, g_out_cap);
    write_manifest(&w, g_fixture);
    size_t written = (size_t)(w.position - w.buffer);
    if (mpack_writer_destroy(&w) != mpack_ok) return 0;
    return (uint64_t)written;
}

static uint64_t enc_fresh(void) {
    char* data = NULL;
    size_t size = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &data, &size);
    write_manifest(&w, g_fixture);
    if (mpack_writer_destroy(&w) != mpack_ok) return 0;
    uint64_t h = (uint64_t)size;
    free(data);
    return h;
}

static uint64_t dec_fresh(void) { return drain(g_data, g_len, g_lim, false, g_mutant); }
static uint64_t dec_reused(void) { return drain(g_data, g_len, g_lim, false, g_mutant); }

static const char* g_trunc_end = NULL;
static size_t g_trunc_end_len = 0;
static const char* g_trunc_start = NULL;
static size_t g_trunc_start_len = 0;
static const char* g_trunc_middle = NULL;
static size_t g_trunc_middle_len = 0;
static const char* g_corrupt_start = NULL;
static size_t g_corrupt_start_len = 0;
static const char* g_corrupt_middle = NULL;
static size_t g_corrupt_middle_len = 0;
static const char* g_corrupt_end = NULL;
static size_t g_corrupt_end_len = 0;

static uint64_t dec_trunc_end(void) { return drain(g_trunc_end, g_trunc_end_len, g_lim, false, g_mutant); }
static uint64_t dec_trunc_start(void) { return drain(g_trunc_start, g_trunc_start_len, g_lim, false, g_mutant); }
static uint64_t dec_trunc_middle(void) { return drain(g_trunc_middle, g_trunc_middle_len, g_lim, false, g_mutant); }
static uint64_t dec_corrupt_start(void) { return drain(g_corrupt_start, g_corrupt_start_len, g_lim, false, g_mutant); }
static uint64_t dec_corrupt_middle(void) { return drain(g_corrupt_middle, g_corrupt_middle_len, g_lim, false, g_mutant); }
static uint64_t dec_corrupt_end(void) { return drain(g_corrupt_end, g_corrupt_end_len, g_lim, false, g_mutant); }

typedef uint64_t (*op_t)(void);

// Returns the raw totals, never a pre-divided rate. The reader divides once.
static void time_batch(op_t op, const char* name, const char* op_name,
                       int64_t batch, int64_t ms) {
    uint64_t sink = 0;
    for (int64_t k = 0; k < batch; k++) sink += op();

    int64_t n = 0;
    int64_t dt = 0;
    int64_t end = clock_ns() + ms * 1000000ll;
    for (;;) {
        int64_t t0 = clock_ns();
        for (int64_t k = 0; k < batch; k++) sink += op();
        dt += clock_ns() - t0;
        n += batch;
        if (clock_ns() >= end) break;
    }
    printf("time %s %s %lld %lld\n", name, op_name, (long long)n, (long long)dt);
    // Keep the sink observable so the loop cannot be eliminated.
    if (sink == 0xdeadbeefcafef00dull) printf("sink %llu\n", (unsigned long long)sink);
}

// ---------------------------------------------------------------------------
// Modes
// ---------------------------------------------------------------------------

static void put_hex(const char* data, size_t len) {
    static const char digits[] = "0123456789abcdef";
    for (size_t i = 0; i < len; i++) {
        unsigned char b = (unsigned char)data[i];
        putchar(digits[b >> 4]);
        putchar(digits[b & 0xf]);
    }
}

// The build under measurement, printed rather than assumed. A comparison against
// a debug build is not a comparison, so the effective configuration is part of
// the record.
static int mode_macros(void) {
    printf("macro MPACK_DEBUG %d\n", (int)MPACK_DEBUG);
    printf("macro MPACK_READ_TRACKING %d\n", (int)MPACK_READ_TRACKING);
    printf("macro MPACK_WRITE_TRACKING %d\n", (int)MPACK_WRITE_TRACKING);
    printf("macro MPACK_EXTENSIONS %d\n", (int)MPACK_EXTENSIONS);
    printf("macro MPACK_STDLIB %d\n", (int)MPACK_STDLIB);
    printf("macro MPACK_STRINGS %d\n", (int)MPACK_STRINGS);
    printf("macro MPACK_READER %d\n", (int)MPACK_READER);
    printf("macro MPACK_WRITER %d\n", (int)MPACK_WRITER);
    printf("macro MPACK_MALLOC %s\n",
           MPACK_READ_TRACKING || MPACK_WRITE_TRACKING ? "used" : "unused");
    printf("size mpack_reader_t %zu\n", sizeof(mpack_reader_t));
    printf("size mpack_writer_t %zu\n", sizeof(mpack_writer_t));
    printf("size mpack_tag_t %zu\n", sizeof(mpack_tag_t));
    return 0;
}

static void build_invalid(const char* data, size_t len);

static void put_invalid_row(const char* name, const char* op,
                            const char* data, size_t len) {
    printf("invalid %s %s bytes %zu hex ", name, op, len);
    put_hex(data, len);
    printf("\n");
}

static int mode_verify(void) {
    for (int i = 0; i < FIXTURE_COUNT; i++) {
        size_t size = 0;
        char* data = build_fixture(&FIXTURES[i], &size);
        printf("fixture %s bytes %zu hex ", FIXTURES[i].name, size);
        put_hex(data, size);
        printf("\n");
        // The invalid variants are published too, so the reader can prove both
        // binaries measure the same invalid inputs rather than assuming it.
        build_invalid(data, size);
        put_invalid_row(FIXTURES[i].name, "truncated-end", g_trunc_end, g_trunc_end_len);
        put_invalid_row(FIXTURES[i].name, "truncated-start", g_trunc_start, g_trunc_start_len);
        put_invalid_row(FIXTURES[i].name, "truncated-middle", g_trunc_middle, g_trunc_middle_len);
        put_invalid_row(FIXTURES[i].name, "corrupt-start", g_corrupt_start, g_corrupt_start_len);
        put_invalid_row(FIXTURES[i].name, "corrupt-middle", g_corrupt_middle, g_corrupt_middle_len);
        put_invalid_row(FIXTURES[i].name, "corrupt-end", g_corrupt_end, g_corrupt_end_len);
        free(data);
    }
    return 0;
}

// Build the six invalid variants from a valid document, the same way
// bench/bench.goose does: truncate at the end, at the start and in the middle;
// corrupt a byte at the start, in the middle and at the end.
//
// Each variant is allocated to its exact length. A fixed 64 KiB buffer would
// hide a read past the logical end inside the allocation, so AddressSanitizer
// could not see it — and reading past the end of a truncated payload is exactly
// the defect this harness must not have. With an exact allocation the overrun
// lands on the redzone and the sanitizer reports it.
static char* g_variant[6];

static void set_variant(int slot, const char* src, size_t len) {
    free(g_variant[slot]);
    g_variant[slot] = malloc(len ? len : 1);
    if (!g_variant[slot]) { fprintf(stderr, "out of memory\n"); exit(2); }
    if (len) memcpy(g_variant[slot], src, len);
}

static void build_invalid(const char* data, size_t len) {
    if (len < 2) { fprintf(stderr, "fixture too small\n"); exit(2); }
    size_t mid = len / 2;

    // truncated-end: drop the last byte.
    set_variant(0, data, len - 1);
    g_trunc_end = g_variant[0]; g_trunc_end_len = len - 1;

    // truncated-start: drop the first byte.
    set_variant(1, data + 1, len - 1);
    g_trunc_start = g_variant[1]; g_trunc_start_len = len - 1;

    // truncated-middle: drop a byte in the middle.
    set_variant(2, data, len - 1);
    memmove(g_variant[2] + mid, data + mid + 1, len - mid - 1);
    g_trunc_middle = g_variant[2]; g_trunc_middle_len = len - 1;

    // corrupt-start / -middle / -end: the reserved marker 0xc1, exactly as
    // bench/bench.goose builds them. A bit flip would be a different input: it
    // leaves a valid marker in place, so the decoder walks the whole document
    // instead of refusing at the first byte, and the row would compare a
    // refusal against a traversal.
    set_variant(3, data, len); g_variant[3][0] = (char)0xc1;
    g_corrupt_start = g_variant[3]; g_corrupt_start_len = len;
    set_variant(4, data, len); g_variant[4][mid] = (char)0xc1;
    g_corrupt_middle = g_variant[4]; g_corrupt_middle_len = len;
    set_variant(5, data, len); g_variant[5][len - 1] = (char)0xc1;
    g_corrupt_end = g_variant[5]; g_corrupt_end_len = len;
}

// Byte-wise FNV-1a, the same function bench/bench.goose uses for its encode
// rows. Two writers that produce the same bytes produce the same value here,
// which is what makes the encode column comparable across implementations.
static uint64_t fnv1a(uint64_t h, const char* data, size_t len) {
    for (size_t i = 0; i < len; i++) h = (h ^ (uint8_t)data[i]) * FNV_PRIME;
    return h;
}

static int mode_checksum(bool mutant) {
    g_mutant = mutant;
    for (int i = 0; i < FIXTURE_COUNT; i++) {
        size_t size = 0;
        char* data = build_fixture(&FIXTURES[i], &size);
        g_data = data; g_len = size; g_fixture = &FIXTURES[i];
        g_out_cap = size + 4096;
        g_out = malloc(g_out_cap);
        if (!g_out) { fprintf(stderr, "out of memory\n"); return 2; }
        build_invalid(data, size);

        // The encode rows hash the produced bytes, not the byte count, so the
        // value is comparable with bench.goose's encode checksum.
        {
            mpack_writer_t w;
            mpack_writer_init(&w, g_out, g_out_cap);
            write_manifest(&w, &FIXTURES[i]);
            size_t written = (size_t)(w.position - w.buffer);
            if (mpack_writer_destroy(&w) != mpack_ok) return 2;
            printf("sum %s encode-reused %llu\n", FIXTURES[i].name,
                   (unsigned long long)fnv1a(FNV_OFFSET, g_out, written));
        }
        {
            char* fresh = NULL;
            size_t fsize = 0;
            mpack_writer_t w;
            mpack_writer_init_growable(&w, &fresh, &fsize);
            write_manifest(&w, &FIXTURES[i]);
            if (mpack_writer_destroy(&w) != mpack_ok) return 2;
            printf("sum %s encode-fresh %llu\n", FIXTURES[i].name,
                   (unsigned long long)fnv1a(FNV_OFFSET, fresh, fsize));
            free(fresh);
        }
        printf("sum %s decode-fresh %llu\n", FIXTURES[i].name,
               (unsigned long long)drain(data, size, NULL, true, g_mutant));
        printf("sum %s decode-reused %llu\n", FIXTURES[i].name,
               (unsigned long long)drain(data, size, NULL, true, g_mutant));
        printf("sum %s decode-truncated-end %llu\n", FIXTURES[i].name,
               (unsigned long long)drain(g_trunc_end, g_trunc_end_len, NULL, true, g_mutant));
        printf("sum %s decode-truncated-start %llu\n", FIXTURES[i].name,
               (unsigned long long)drain(g_trunc_start, g_trunc_start_len, NULL, true, g_mutant));
        printf("sum %s decode-truncated-middle %llu\n", FIXTURES[i].name,
               (unsigned long long)drain(g_trunc_middle, g_trunc_middle_len, NULL, true, g_mutant));
        printf("sum %s decode-corrupt-start %llu\n", FIXTURES[i].name,
               (unsigned long long)drain(g_corrupt_start, g_corrupt_start_len, NULL, true, g_mutant));
        printf("sum %s decode-corrupt-middle %llu\n", FIXTURES[i].name,
               (unsigned long long)drain(g_corrupt_middle, g_corrupt_middle_len, NULL, true, g_mutant));
        printf("sum %s decode-corrupt-end %llu\n", FIXTURES[i].name,
               (unsigned long long)drain(g_corrupt_end, g_corrupt_end_len, NULL, true, g_mutant));

        free(g_out); g_out = NULL;
        free(data);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Budget negative controls
// ---------------------------------------------------------------------------
//
// A budget that never fires is not a budget. Each case below builds an input
// that exceeds exactly one limit and asserts the refusal code, so the contract
// column is shown to enforce the same rules goose-msgpack enforces rather than
// merely to contain comparisons that happen to be true on valid input.
//
// The empty-container case is the one that distinguishes "structural depth"
// from "open non-empty frames": a chain of 40 non-empty arrays is refused at
// depth 32, while an array holding 40 empty arrays is accepted, because an
// empty container opens no frame.

typedef struct {
    const char* name;
    uint64_t got;
    uint64_t want;
} control_t;

static int mode_budget_selftest(void) {
    control_t cases[16];
    int n = 0;
    char* data = NULL;
    size_t size = 0;
    mpack_writer_t w;

#define BEGIN() do { data = NULL; size = 0; mpack_writer_init_growable(&w, &data, &size); } while (0)
#define END()   do { if (mpack_writer_destroy(&w) != mpack_ok) { fprintf(stderr, "writer failed\n"); return 2; } } while (0)
#define RECORD(label, expected) do { \
        cases[n].name = (label); \
        (void)drain(data, size, &LIMITS_DEFAULT, false, false); \
        cases[n].got = g_refusal; \
        cases[n].want = (expected); \
        n++; \
    } while (0)

    // 1. Input budget: 2 MiB of bytes against a 1 MiB limit.
    {
        size_t big = 2u * 1024u * 1024u;
        char* buf = malloc(big);
        if (!buf) return 2;
        memset(buf, 0xc0, big);
        cases[n].name = "input-budget";
        (void)drain(buf, big, &LIMITS_DEFAULT, false, false);
        cases[n].got = g_refusal;
        cases[n].want = 0x1000;
        n++;
        free(buf);
    }

    // 2. Node budget: a map of 40000 entries is 80001 nodes, under the
    //    container limit of 65536, so the node budget is what fires.
    BEGIN();
    mpack_start_map(&w, 40000);
    for (uint32_t i = 0; i < 40000; i++) { mpack_write_uint(&w, i); mpack_write_nil(&w); }
    mpack_finish_map(&w);
    END();
    RECORD("node-budget", 0x1001);
    free(data);

    // 3. Depth budget: 40 nested non-empty arrays against a depth of 32.
    BEGIN();
    for (int i = 0; i < 40; i++) mpack_start_array(&w, 1);
    mpack_write_nil(&w);
    for (int i = 0; i < 40; i++) mpack_finish_array(&w);
    END();
    RECORD("depth-budget", 0x1002);
    free(data);

    // 4. Empty containers do not consume depth: one array holding 40 empty
    //    arrays is accepted, because no empty container opens a frame.
    BEGIN();
    mpack_start_array(&w, 40);
    for (int i = 0; i < 40; i++) { mpack_start_array(&w, 0); mpack_finish_array(&w); }
    mpack_finish_array(&w);
    END();
    {
        (void)drain(data, size, &LIMITS_DEFAULT, false, false);
        cases[n].name = "empty-containers-no-depth";
        cases[n].got = g_refusal;  // 0 = accepted
        cases[n].want = 0;
        n++;
    }
    free(data);

    // 5. Str budget: a 300000-byte str against a 262144-byte limit.
    BEGIN();
    mpack_start_str(&w, 300000);
    for (int i = 0; i < 300000; i++) mpack_write_u8(&w, 'x');
    mpack_finish_str(&w);
    END();
    RECORD("str-budget", 0x1004);
    free(data);

    // 6. Bin budget: a 300000-byte bin against a 262144-byte limit.
    BEGIN();
    mpack_start_bin(&w, 300000);
    for (int i = 0; i < 300000; i++) mpack_write_u8(&w, 0x00);
    mpack_finish_bin(&w);
    END();
    RECORD("bin-budget", 0x1005);
    free(data);

    // 7. Container budget: an array declaring 70000 elements. Only the header
    //    is needed, because the check fires before any element is read.
    BEGIN();
    mpack_start_array(&w, 70000);
    END();
    RECORD("container-budget", 0x1006);
    free(data);

    // 8. Full input: a valid document followed by one extra byte.
    BEGIN();
    mpack_write_uint(&w, 1);
    END();
    {
        char* trailing = malloc(size + 1);
        if (!trailing) return 2;
        memcpy(trailing, data, size);
        trailing[size] = 0xc0;
        cases[n].name = "trailing-byte";
        (void)drain(trailing, size + 1, &LIMITS_DEFAULT, false, false);
        cases[n].got = g_refusal;
        cases[n].want = 0x1003;
        n++;
        free(trailing);
    }
    free(data);

    // 9. Invalid UTF-8 in a str is refused by the checked API. The payload is
    //    written as raw bytes so the document is well formed: a 2-byte str
    //    holding 0xc3 0x28, which is a truncated 2-byte sequence.
    BEGIN();
    {
        static const char bad[] = {(char)0xc3, (char)0x28};
        mpack_start_str(&w, 2);
        mpack_write_bytes(&w, bad, 2);
        mpack_finish_str(&w);
    }
    END();
    RECORD("invalid-utf8", 0x200);
    free(data);

    // 10. A valid small document is accepted: the controls above must not be
    //     passing because everything is refused.
    BEGIN();
    mpack_start_map(&w, 1);
    mpack_write_cstr(&w, "k");
    mpack_write_uint(&w, 5);
    mpack_finish_map(&w);
    END();
    {
        (void)drain(data, size, &LIMITS_DEFAULT, false, false);
        cases[n].name = "valid-small-accepted";
        cases[n].got = g_refusal;  // 0 = accepted
        cases[n].want = 0;
        n++;
    }
    free(data);

#undef BEGIN
#undef END
#undef RECORD

    int failures = 0;
    for (int i = 0; i < n; i++) {
        bool ok = cases[i].got == cases[i].want;
        printf("%s %s got 0x%llx want 0x%llx\n", ok ? "ok" : "FAIL",
               cases[i].name, (unsigned long long)cases[i].got,
               (unsigned long long)cases[i].want);
        if (!ok) failures++;
    }
    printf("budget self-check %s: %d cases, %d failures\n",
           failures ? "FAILED" : "ok", n, failures);
    return failures ? 1 : 0;
}

// Truncated payloads, decoded directly.
//
// The five fixtures contain no bin and no ext, so the 35 verify rows never reach
// the bin/ext payload path at all. A harness that samples a payload before
// checking the reader error would read past the end of a truncated bin and the
// verify rows would not notice. Each case here is allocated to its exact length,
// so AddressSanitizer sees the overrun instead of hiding it in a 64 KiB buffer.
static int mode_safety_selftest(void) {
    static const struct { const char* name; const char* bytes; size_t len; } cases[] = {
        { "bin8-truncated",   "\xc4\x05" "ab",                 4 },
        { "bin16-truncated",  "\xc5\x00\x05" "ab",             5 },
        { "bin32-truncated",  "\xc6\x00\x00\x00\x05" "ab",     7 },
        { "ext8-truncated",   "\xc7\x05\x01" "ab",             5 },
        { "ext16-truncated",  "\xc8\x00\x05\x01" "ab",         6 },
        { "ext32-truncated",  "\xc9\x00\x00\x00\x05\x01" "ab", 8 },
        { "fixstr-truncated", "\xa5" "ab",                     3 },
        { "str8-truncated",   "\xd9\x05" "ab",                 4 },
        { "str16-truncated",  "\xda\x00\x05" "ab",             5 },
        { "str32-truncated",  "\xdb\x00\x00\x00\x05" "ab",     7 },
    };
    const int n = (int)(sizeof cases / sizeof cases[0]);
    int failures = 0;
    for (int i = 0; i < n; i++) {
        for (int contract = 0; contract < 2; contract++) {
            const limits_t* lim = contract ? &LIMITS_DEFAULT : NULL;
            // Exactly sized: a read past the declared payload lands on the
            // redzone rather than in unused space.
            char* buf = malloc(cases[i].len);
            if (!buf) { fprintf(stderr, "out of memory\n"); return 2; }
            memcpy(buf, cases[i].bytes, cases[i].len);
            (void)drain(buf, cases[i].len, lim, true, false);
            uint64_t got = g_refusal;
            free(buf);
            bool ok = got != 0;
            printf("%s %s/%s got 0x%llx want a refusal\n", ok ? "ok" : "FAIL",
                   cases[i].name, contract ? "contract" : "raw",
                   (unsigned long long)got);
            if (!ok) failures++;
        }
    }
    printf("safety self-check %s: %d cases, %d failures\n",
           failures ? "FAILED" : "ok", n * 2, failures);
    return failures ? 1 : 0;
}

static int mode_time(int64_t batch, int64_t ms, const limits_t* lim) {
    g_lim = lim;
    for (int i = 0; i < FIXTURE_COUNT; i++) {
        size_t size = 0;
        char* data = build_fixture(&FIXTURES[i], &size);
        g_data = data; g_len = size; g_fixture = &FIXTURES[i];
        g_out_cap = size + 4096;
        g_out = malloc(g_out_cap);
        if (!g_out) { fprintf(stderr, "out of memory\n"); return 2; }
        build_invalid(data, size);

        const char* name = FIXTURES[i].name;
        time_batch(enc_reused, name, "encode-reused", batch, ms);
        time_batch(enc_fresh, name, "encode-fresh", batch, ms);
        time_batch(dec_fresh, name, "decode-fresh", batch, ms);
        time_batch(dec_reused, name, "decode-reused", batch, ms);
        time_batch(dec_trunc_end, name, "decode-truncated-end", batch, ms);
        time_batch(dec_trunc_start, name, "decode-truncated-start", batch, ms);
        time_batch(dec_trunc_middle, name, "decode-truncated-middle", batch, ms);
        time_batch(dec_corrupt_start, name, "decode-corrupt-start", batch, ms);
        time_batch(dec_corrupt_middle, name, "decode-corrupt-middle", batch, ms);
        time_batch(dec_corrupt_end, name, "decode-corrupt-end", batch, ms);

        free(g_out); g_out = NULL;
        free(data);
    }
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s verify|checksum|checksum-mutant|macros|budget-selftest"
                        "|safety-selftest"
                        "|contract <batch> <ms>|contract-wide <batch> <ms>|<batch> <ms>\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "verify") == 0) return mode_verify();
    if (strcmp(argv[1], "checksum") == 0) return mode_checksum(false);
    if (strcmp(argv[1], "checksum-mutant") == 0) return mode_checksum(true);
    if (strcmp(argv[1], "macros") == 0) return mode_macros();
    if (strcmp(argv[1], "budget-selftest") == 0) return mode_budget_selftest();
    if (strcmp(argv[1], "safety-selftest") == 0) return mode_safety_selftest();
    if (strcmp(argv[1], "contract") == 0) {
        if (argc != 4) { fprintf(stderr, "contract needs <batch> <ms>\n"); return 2; }
        return mode_time(atoll(argv[2]), atoll(argv[3]), &LIMITS_DEFAULT);
    }
    if (strcmp(argv[1], "contract-wide") == 0) {
        if (argc != 4) { fprintf(stderr, "contract-wide needs <batch> <ms>\n"); return 2; }
        return mode_time(atoll(argv[2]), atoll(argv[3]), &LIMITS_WIDEST);
    }
    if (argc != 3) { fprintf(stderr, "time mode needs <batch> <ms>\n"); return 2; }
    return mode_time(atoll(argv[1]), atoll(argv[2]), NULL);
}
