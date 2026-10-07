#import <Foundation/Foundation.h>
// Periodic memory-available line into the guest log (always). When fullWatch is YES, also
// samples engine-thread backtraces (suspends threads) and captures a frame once a minute —
// opt-in via --shack-watch in the guest's .args file or SHACK_WATCH=1.
void ShackWatchStart(BOOL fullWatch);
