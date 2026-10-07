#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Documents/StikJIT/pairingFile.plist: the device's remote-pairing record (the one StikDebug uses).
NSURL *ShackJITPairingFileURL(void);

// Starts the MacShackJIT extension (jithelper/) for this process: it attaches the debugger and serves
// ShackJITPoolSetup's prepare/detach breakpoints. `done` runs on the main queue with the helper's log and
// ok = NO when it failed (VPN off, bad pairing, DDI, script error) or was interrupted.
void ShackJITHelperStart(void (^done)(BOOL ok, NSString *log));
// The same for another process MacShack started (MacShack Play); `done` runs on `queue`.
void ShackJITHelperStartForPID(pid_t pid, dispatch_queue_t queue, void (^done)(BOOL ok, NSString *log));

NS_ASSUME_NONNULL_END
