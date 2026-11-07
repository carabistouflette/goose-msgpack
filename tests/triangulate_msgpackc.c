// SPDX-License-Identifier: Apache-2.0
// Third-party triangulation oracle: msgpack-c, the C implementation maintained
// by the official msgpack organisation.
//
// The point is to break the correlated-defect risk of a single model. The
// differential oracle in tests/oracle.py is an independent reimplementation of
// the same contract, but it was written for this library and can share a
// misreading of the specification with it. msgpack-c was written by someone
// else, is used by other projects, and is maintained.
//
//   cc -O2 -I <msgpack-c>/include tests/triangulate_msgpackc.c \
//      <msgpack-c>/src/*.c -o .build/triangulate-msgpackc
//   .build/triangulate-msgpackc <corpus>
//
// Corpus format: repeated `u32 little-endian length` + that many bytes.
// Output: `record <i>` then one canonical line per value in pre-order, then
// `end`; or `reject <reason>` when msgpack-c refuses the record.
//
// Canonical form, one line per value:
//
//   nil
//   bool <0|1>
//   uint <decimal>            POSITIVE_INTEGER
//   int <decimal>             NEGATIVE_INTEGER
//   f32 <hex of the 4 bytes in memory order>
//   f64 <hex of the 8 bytes in memory order>
//   str <len> <hex>
//   bin <len> <hex>
//   ext <type> <len> <hex>
//   array <n>                 followed by n values
//   map <n>                   followed by 2n values, key then value
//
// Floats are printed as raw bytes rather than as a number so that NaN payloads,
// -0.0 and both widths survive the comparison exactly. The bytes are in host
// memory order; both binaries run on the same host in the same run, and the
// report records the host.
//
// Contract differences, measured rather than assumed:
//
//   - msgpack-c does not validate UTF-8. This library does, on purpose.
//   - msgpack-c has no input, node, str, bin or container budget.
//   - msgpack-c DOES have a depth budget, but it is a fixed 32-frame stack
//     (MSGPACK_EMBED_STACK_SIZE, unpack_template.h:141, marked FIXME), not a
//     configurable limit. A deeper document is reported as NOMEM, which is
//     indistinguishable from a real allocation failure at this API. This
//     oracle therefore reports `reject nomem` and nothing more; the driver
//     decides whether the depth explains it, using an independent walk of the
//     bytes. Renaming NOMEM to "depth" here would hide an allocation failure.
//   - msgpack-c has no full-input contract beyond the caller comparing `off`
//     to `len`.
//
// Those are contract differences, not defects, and the driver classifies them
// instead of hiding them.
#include <msgpack.h>

#include <stdbool.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void put_hex(const char *data, uint32_t len) {
    static const char digits[] = "0123456789abcdef";
    for (uint32_t i = 0; i < len; i++) {
        unsigned char b = (unsigned char)data[i];
        putchar(digits[b >> 4]);
        putchar(digits[b & 0xf]);
    }
}

static void emit(const msgpack_object *o) {
    switch (o->type) {
    case MSGPACK_OBJECT_NIL:
        printf("nil\n");
        break;
    case MSGPACK_OBJECT_BOOLEAN:
        printf("bool %d\n", o->via.boolean ? 1 : 0);
        break;
    case MSGPACK_OBJECT_POSITIVE_INTEGER:
        // Canonicalised by mathematical value, not by wire family. The wire
        // family (fixint vs int8 vs uint8 ...) is an API choice of each
        // library, not a fact both must agree on; the value is the fact.
        if (o->via.u64 <= (uint64_t)INT64_MAX) {
            printf("int %lld\n", (long long)o->via.u64);
        } else {
            printf("uint %llu\n", (unsigned long long)o->via.u64);
        }
        break;
    case MSGPACK_OBJECT_NEGATIVE_INTEGER:
        printf("int %lld\n", (long long)o->via.i64);
        break;
    case MSGPACK_OBJECT_FLOAT32: {
        // msgpack-c stores an f32 as a widened double and narrows it back on
        // the way out. That round trip is NOT exact for every payload: widening
        // a signalling NaN sets the quiet bit, so 0x7f800001 comes back as
        // 0x7fc00001. The bytes printed here are what msgpack-c reports, which
        // is why the driver has a separate `oracle-f32-nan-quieting` class
        // instead of treating the difference as a defect of this library.
        float f = (float)o->via.f64;
        printf("f32 ");
        put_hex((const char *)&f, 4);
        printf("\n");
        break;
    }
    case MSGPACK_OBJECT_FLOAT64: {
        double d = o->via.f64;
        printf("f64 ");
        put_hex((const char *)&d, 8);
        printf("\n");
        break;
    }
    case MSGPACK_OBJECT_STR:
        printf("str %u ", (unsigned)o->via.str.size);
        put_hex(o->via.str.ptr, o->via.str.size);
        printf("\n");
        break;
    case MSGPACK_OBJECT_BIN:
        printf("bin %u ", (unsigned)o->via.bin.size);
        put_hex(o->via.bin.ptr, o->via.bin.size);
        printf("\n");
        break;
    case MSGPACK_OBJECT_EXT:
        printf("ext %d %u ", (int)o->via.ext.type, (unsigned)o->via.ext.size);
        put_hex(o->via.ext.ptr, o->via.ext.size);
        printf("\n");
        break;
    case MSGPACK_OBJECT_ARRAY:
        printf("array %u\n", (unsigned)o->via.array.size);
        for (uint32_t i = 0; i < o->via.array.size; i++) {
            emit(&o->via.array.ptr[i]);
        }
        break;
    case MSGPACK_OBJECT_MAP:
        printf("map %u\n", (unsigned)o->via.map.size);
        for (uint32_t i = 0; i < o->via.map.size; i++) {
            emit(&o->via.map.ptr[i].key);
            emit(&o->via.map.ptr[i].val);
        }
        break;
    default:
        printf("unknown %d\n", (int)o->type);
        break;
    }
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <corpus>\n", argv[0]);
        return 2;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        perror("open");
        return 2;
    }
    uint32_t index = 0;
    for (;;) {
        uint32_t len = 0;
        if (fread(&len, 4, 1, f) != 1) {
            break;
        }
        char *buf = (char *)malloc(len ? len : 1);
        if (!buf) {
            fprintf(stderr, "out of memory\n");
            return 2;
        }
        if (len && fread(buf, 1, len, f) != len) {
            fprintf(stderr, "short record\n");
            return 2;
        }
        printf("record %u\n", index);

        msgpack_unpacked result;
        msgpack_unpacked_init(&result);
        size_t off = 0;
        // The return is an enum, not a bool: MSGPACK_UNPACK_PARSE_ERROR is -1
        // and MSGPACK_UNPACK_NOMEM_ERROR is -2, and both convert to `true`.
        // Comparing against SUCCESS explicitly is the only correct test.
        msgpack_unpack_return ret = msgpack_unpack_next(&result, buf, len, &off);
        if (ret == MSGPACK_UNPACK_NOMEM_ERROR) {
            // Reported as what it is. msgpack_unpack_next returns NOMEM both
            // when its fixed 32-frame stack overflows and when a real
            // allocation fails, and the API does not distinguish them. The
            // driver decides which, from an independent walk of the bytes; if
            // the depth does not explain it, the run fails as an
            // infrastructure error rather than being excused.
            printf("reject nomem\n");
        } else if (ret == MSGPACK_UNPACK_PARSE_ERROR) {
            printf("reject parse\n");
        } else if (ret == MSGPACK_UNPACK_CONTINUE) {
            printf("reject continue\n");
        } else if (ret == MSGPACK_UNPACK_EXTRA_BYTES || off != len) {
            // msgpack-c decodes one value and leaves the cursor; the caller
            // owns the "exactly one value" check. Report it as a refusal so it
            // lines up with `finish` returning TrailingBytes.
            printf("reject trailing\n");
        } else {
            emit(&result.data);
            printf("end\n");
        }
        msgpack_unpacked_destroy(&result);
        free(buf);
        index++;
    }
    fclose(f);
    return 0;
}
