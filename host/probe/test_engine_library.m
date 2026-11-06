// An iOS app's executable as a library (ShackPrep libraryFromExecutableAtPath:, Madeira's engine since 0.2.0): the
// header checks, then dyld loading it and running its code, in the iOS Simulator:
//   xcrun --sdk iphonesimulator clang -target arm64-apple-ios18.0-simulator -Wl,-headerpad,0x100 host/probe/engine_sample.c -o /tmp/sample
//   xcrun --sdk iphonesimulator clang -fobjc-arc -target arm64-apple-ios18.0-simulator host/ShackPrep.m \
//     host/probe/test_engine_library.m -framework Foundation -o /tmp/t
//   xcrun simctl spawn booted /tmp/t convert /tmp/sample /tmp/engine.dylib && codesign -f -s - /tmp/engine.dylib && \
//     xcrun simctl spawn booted /tmp/t load /tmp/engine.dylib
// expect `engine library ok`. `convert <Madeira.app/Madeira> <out>` alone checks a real engine's header (`converted ok`).
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/loader.h>
#import "../ShackPrep.h"

static void Check(BOOL ok, const char *what) { if (!ok) { fprintf(stderr, "FAIL: %s\n", what); exit(1); } }

// The load commands of a thin 64-bit Mach-O, by command.
static NSDictionary<NSNumber *, NSArray<NSData *> *> *Commands(NSData *file) {
    const struct mach_header_64 *h = file.bytes;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    const uint8_t *p = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++, p += ((const struct load_command *)p)->cmdsize) {
        NSNumber *cmd = @(((const struct load_command *)p)->cmd);
        out[cmd] = [out[cmd] ?: @[] arrayByAddingObject:[NSData dataWithBytes:p length:((const struct load_command *)p)->cmdsize]];
    }
    return out;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        Check(argc == 4 || (argc == 3 && !strcmp(argv[1], "load")), "usage: convert <executable> <out> | load <library>");
        if (!strcmp(argv[1], "load")) {
            void *engine = dlopen(argv[2], RTLD_NOW | RTLD_GLOBAL);
            if (!engine) { fprintf(stderr, "FAIL: dlopen: %s\n", dlerror()); return 1; }
            int (*value)(void) = (int (*)(void))dlsym(engine, "engine_sample_value");
            Check(value != NULL, "exported entry point");
            Check(value() == 101 && value() == 102, "rebased pointers, bound import and thread-local");
            puts("engine library ok");
            return 0;
        }
        NSString *in = @(argv[2]), *out = @(argv[3]);
        NSError *error = nil;
        BOOL converted = [ShackPrep libraryFromExecutableAtPath:in outputPath:out installName:@"@rpath/MadeiraEngine.dylib" error:&error];
        if (!converted) { fprintf(stderr, "FAIL: %s\n", error.localizedDescription.UTF8String); return 1; }
        NSData *before = [NSData dataWithContentsOfFile:in], *after = [NSData dataWithContentsOfFile:out];
        const struct mach_header_64 *h = after.bytes, *h0 = before.bytes;
        Check(h0->magic == MH_MAGIC_64, "a thin input (the test reads its header directly)");
        Check(h->filetype == MH_DYLIB && !(h->flags & MH_PIE) && (h->flags | MH_PIE) == h0->flags, "MH_DYLIB, the flags but PIE kept");
        NSDictionary *a = Commands(after), *b = Commands(before);
        Check(!a[@(LC_LOAD_DYLINKER)] && [a[@(LC_ID_DYLIB)] count] == 1, "LC_ID_DYLIB in place of LC_LOAD_DYLINKER");
        const struct dylib_command *idc = [a[@(LC_ID_DYLIB)][0] bytes];
        Check(!strcmp((const char *)idc + idc->dylib.name.offset, "@rpath/MadeiraEngine.dylib"), "install name");
        for (NSNumber *cmd in @[@(LC_MAIN), @(LC_BUILD_VERSION), @(LC_LOAD_DYLIB), @(LC_LOAD_WEAK_DYLIB), @(LC_RPATH), @(LC_DYLD_CHAINED_FIXUPS), @(LC_DYLD_EXPORTS_TRIE)])
            Check([a[cmd] ?: @[] isEqualToArray:b[cmd] ?: @[]], "entry, build version, links, rpaths and fixups unchanged");
        NSArray *segments = a[@(LC_SEGMENT_64)];
        Check(segments.count == [b[@(LC_SEGMENT_64)] count], "same segments, same indices");
        const struct segment_command_64 *zero = [segments[0] bytes], *text = [segments[1] bytes];
        Check(!strcmp(zero->segname, "__PAGEZERO") && zero->vmaddr + zero->vmsize == text->vmaddr && zero->vmsize == 0x4000, "__PAGEZERO is the page below __TEXT");
        Check(after.length == before.length, "same size");
        uint32_t end = (uint32_t)sizeof *h + MAX(h->sizeofcmds, h0->sizeofcmds);
        Check(!memcmp((const uint8_t *)after.bytes + end, (const uint8_t *)before.bytes + end, after.length - end), "nothing past the load commands changed");
        Check(![ShackPrep libraryFromExecutableAtPath:out outputPath:[out stringByAppendingString:@".again"] installName:@"x" error:&error], "a library is refused");
        puts("converted ok");
    }
}
