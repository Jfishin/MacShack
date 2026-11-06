// A main executable for test_engine_library.m: what MacShack Play needs of Madeira's converted app executable (rebased
// pointers, a bound import and a thread-local behind an exported entry point).
#include <string.h>

static const char *names[] = {"wine", "server"};   // rebased pointers
static size_t (*measure)(const char *) = strlen;    // a bound import
static __thread int calls;                          // a thread-local: TLV descriptors

int engine_sample_value(void) { return (int)(measure(names[0]) + measure(names[1])) * 10 + ++calls; }   // 101, 102, ...
int main(void) { return engine_sample_value() == 101 ? 0 : 1; }
