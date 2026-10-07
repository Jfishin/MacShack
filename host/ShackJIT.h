#import <Foundation/Foundation.h>
// Feasibility spike: probe StikDebug JIT26 write-then-execute models on a TXM/SPTM
// device. Runs standalone (no guest) via the `--jit-spike` launch argument; logs
// every step to Documents/Logs/jit-spike.log and NSLog. See ShackJIT.m for the plan.
void ShackJITSpike(void);
// Mono guests: wait for StikDebug, have it prepare one RX pool of `bytes`, alias it RW, publish both
// through SHACK_JIT_POOL for the patched Mono code manager, detach. NO when no debugger attached in 90 s.
BOOL ShackJITPoolSetup(size_t bytes);
// The same, holding [avoid, avoid + avoidLength) while the debugger picks the RX address (Madeira's engine: never in
// its guest window), released before the RW alias is mapped.
BOOL ShackJITPoolSetupAvoiding(size_t bytes, uintptr_t avoid, size_t avoidLength);
// ShackJITPoolSetup(mb MB), then a function written through the RW alias, run, rewritten and run again (the Mono model
// end to end, the rewrite after the debugger detached). One report line: "(ok)" when it ran 42, then 99.
NSString *ShackJITCheck(size_t mb);
