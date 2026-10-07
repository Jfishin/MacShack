#import "ShackJITHelper.h"
#import <unistd.h>

// Read at load: once a game runs, the identity hooks make mainBundle (and its home) answer for the game.
static NSString *g_helperID;
static NSURL *g_pairingURL;
__attribute__((constructor)) static void captureHostPaths(void) {
    g_helperID = [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".jit"];
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
    g_pairingURL = [docs URLByAppendingPathComponent:@"StikJIT/pairingFile.plist"];
}

NSURL *ShackJITPairingFileURL(void) { return g_pairingURL; }

// NSExtension is Foundation SPI: the same calls NeoStation uses to start its hidden JIT helper. Checked with
// respondsToSelector, so a missing one is an error, not a crash.
@protocol ShackNSExtension <NSObject>
+ (id)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *request))completion;
- (void)setRequestCompletionBlock:(void (^)(NSUUID *request, NSArray *items))block;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *request, NSError *error))block;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *request))block;
@end

// One request to the extension `identifier` (payload as an item of `type`); `done` runs once on `queue` with the
// request's userInfo "log", ok = NO when iOS refused it, it was cancelled or the extension died.
static void extensionRequest(NSString *identifier, NSString *type, NSData *payload, dispatch_queue_t queue,
                             void (^done)(BOOL ok, NSString *log)) {
    static NSMutableDictionary<NSString *, id> *live;   // the request's callbacks need the extension alive
    static dispatch_once_t once;
    dispatch_once(&once, ^{ live = [NSMutableDictionary dictionary]; });
    __block BOOL reported = NO;   // an interruption can follow the completion; report only the first
    void (^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *log) {
        dispatch_async(queue, ^{ if (!reported) { reported = YES; done(ok, log); } });
    };

    Class<ShackNSExtension> cls = (Class<ShackNSExtension>)NSClassFromString(@"NSExtension");
    NSError *error = nil;
    if (![cls respondsToSelector:@selector(extensionWithIdentifier:error:)])
        return finish(NO, @"This iOS has no NSExtension launcher.");
    id<ShackNSExtension> extension = [cls extensionWithIdentifier:identifier error:&error];
    for (NSString *sel in @[@"beginExtensionRequestWithInputItems:completion:", @"setRequestCompletionBlock:",
                            @"setRequestCancellationBlock:", @"setRequestInterruptionBlock:"])
        if (![extension respondsToSelector:NSSelectorFromString(sel)])
            return finish(NO, [NSString stringWithFormat:@"Extension %@ unavailable: %@", identifier,
                               error.localizedDescription ?: sel]);
    @synchronized (live) { live[identifier] = extension; }

    [extension setRequestCompletionBlock:^(__unused NSUUID *request, NSArray *items) {
        NSExtensionItem *item = items.firstObject;
        finish(YES, [item isKindOfClass:NSExtensionItem.class] ? (item.userInfo[@"log"] ?: @"") : @"");
    }];
    [extension setRequestCancellationBlock:^(__unused NSUUID *request, NSError *error) {
        finish(NO, error.localizedDescription ?: [identifier stringByAppendingString:@" failed."]);
    }];
    [extension setRequestInterruptionBlock:^(__unused NSUUID *request) {
        finish(NO, [identifier stringByAppendingString:@" stopped unexpectedly."]);
    }];

    NSExtensionItem *item = [NSExtensionItem new];
    item.attachments = @[[[NSItemProvider alloc] initWithItem:payload typeIdentifier:type]];
    [extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *request) {
        if (!request) finish(NO, [@"iOS did not start " stringByAppendingString:identifier]);
    }];
}

void ShackJITHelperStartForPID(pid_t pid, dispatch_queue_t queue, void (^done)(BOOL ok, NSString *log)) {
    NSData *pairing = [NSData dataWithContentsOfURL:ShackJITPairingFileURL()];
    if (pairing.length == 0) {
        dispatch_async(queue, ^{ done(NO, @"No pairing file: import one in Settings > JIT."); });
        return;
    }
    NSDictionary *request = @{@"pid": @(pid), @"pairing": [pairing base64EncodedStringWithOptions:0]};
    NSData *json = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    extensionRequest(g_helperID, @"macshack.jit-request", json, queue, done);
}

void ShackJITHelperStart(void (^done)(BOOL ok, NSString *log)) {
    ShackJITHelperStartForPID(getpid(), dispatch_get_main_queue(), done);
}
