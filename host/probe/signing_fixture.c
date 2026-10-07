__attribute__((section("__TEXT,__const"), used))
const volatile int shack_probe_value = 0x13572468;

int shack_probe(void) {
    return shack_probe_value;
}
