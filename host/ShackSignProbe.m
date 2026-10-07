#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <sys/xattr.h>
#import "ShackSignProbe.h"

void ShackSignProbe(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *lib = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES)[0];
    NSMutableString *out = [NSMutableString stringWithFormat:@"sign probe %@\n", NSDate.date];
    for (NSString *dir in @[[lib stringByAppendingPathComponent:@"SignProbe"], [docs stringByAppendingPathComponent:@"SignProbe"],
                            [NSTemporaryDirectory() stringByAppendingPathComponent:@"SignProbe"]]) {
        for (NSString *name in [[fm contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
            if (![name hasSuffix:@".dylib"]) continue;
            NSString *path = [dir stringByAppendingPathComponent:name];
            void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
            int (*probe)(void) = h ? (int (*)(void))dlsym(h, "shack_probe") : NULL;
            const char *e = h ? NULL : dlerror();
            [out appendFormat:@"%@/%@: %@\n", dir.stringByDeletingLastPathComponent.lastPathComponent, name,
                h ? [NSString stringWithFormat:@"LOADED, shack_probe() = %d", probe ? probe() : -1] : [NSString stringWithFormat:@"REFUSED: %s", e]];
        }
    }
    // The same bytes written by the app itself (files pushed over USB may carry different provenance).
    NSString *copies = [lib stringByAppendingPathComponent:@"SignProbeCopy"];
    [fm removeItemAtPath:copies error:nil]; [fm createDirectoryAtPath:copies withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *src = [lib stringByAppendingPathComponent:@"SignProbe"];
    for (NSString *name in [[fm contentsOfDirectoryAtPath:src error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![name hasSuffix:@".dylib"]) continue;
        char names[1024]; ssize_t n = listxattr([src stringByAppendingPathComponent:name].fileSystemRepresentation, names, sizeof names, 0);
        NSMutableArray *xa = [NSMutableArray array]; for (ssize_t i = 0; i < n; i += strlen(names + i) + 1) [xa addObject:@(names + i)];
        NSString *path = [copies stringByAppendingPathComponent:name];
        [[NSData dataWithContentsOfFile:[src stringByAppendingPathComponent:name]] writeToFile:path atomically:NO];
        void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        int (*probe)(void) = h ? (int (*)(void))dlsym(h, "shack_probe") : NULL;
        const char *e = h ? NULL : dlerror();
        [out appendFormat:@"app-written copy %@ (pushed file xattrs: %@): %@\n", name, [xa componentsJoinedByString:@","],
            h ? [NSString stringWithFormat:@"LOADED, shack_probe() = %d", probe ? probe() : -1] : [NSString stringWithFormat:@"REFUSED: %.200s", e ? strstr(e, "(") : ""]];
    }
    NSString *logs = [docs stringByAppendingPathComponent:@"Logs"];
    [fm createDirectoryAtPath:logs withIntermediateDirectories:YES attributes:nil error:nil];
    [out writeToFile:[logs stringByAppendingPathComponent:@"sign-probe.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"%@", out);
}
