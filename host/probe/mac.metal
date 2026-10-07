#include <metal_stdlib>
using namespace metal;
kernel void probe_fill(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) { out[id] = 42.0; }
