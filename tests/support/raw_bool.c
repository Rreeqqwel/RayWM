// TEST-ONLY (tests/core_test.zig, src/cabi.zig): the byte a C function
// receives for a bool argument. Built with -O2, it reads the argument the
// way optimized system libraries do, without normalising it.
#include <stdbool.h>
#include <string.h>

unsigned raywm_test_raw_bool(bool b) {
    unsigned char raw;
    memcpy(&raw, &b, 1);
    return raw;
}
