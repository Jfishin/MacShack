#!/usr/bin/env python3
"""Generates shims/SteamClient (libShackSteamClient): a stub for every symbol in ios-link-gaps.txt, classified on this
Mac's own frameworks. Functions return 0 (x0 and d0), log their first call and are otherwise inert; constant strings keep
their macOS value; Objective-C classes become empty subclasses of their macOS superclass when iOS or the shims have it,
else NSObject; any other data symbol is 64 zero bytes.
  prep/steam-onehost/gen_stubs.py        (Mac; rerun after regenerating ios-link-gaps.txt)
"""
import os, re, subprocess, sys, tempfile

here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.abspath(os.path.join(here, "..", ".."))
out_dir = os.path.join(repo, "shims", "SteamClient")

LIBS = {"libSystem": "/usr/lib/libSystem.B.dylib", "libcups": "/usr/lib/libcups.2.dylib",
        "libpmenergy": "/usr/lib/libpmenergy.dylib", "libpmsample": "/usr/lib/libpmsample.dylib"}
# Superclasses an empty stub class may keep: classes MacShack's AppKit shim defines, with their own superclass, declared
# here because the stubs include no AppKit headers (the shim's classes resolve at link time).
SHIM_CLASSES = {"NSResponder": "NSObject", "NSView": "NSResponder", "NSControl": "NSView", "NSTextField": "NSControl",
                "NSButton": "NSControl", "NSWindow": "NSResponder", "NSPanel": "NSWindow"}
KEEP_SUPER = {"NSObject"} | set(SHIM_CLASSES)

HELPER = r'''
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <objc/runtime.h>
static BOOL inCFStrings(const void *v) {   // constant CFStrings live in a __cfstring section, in whatever segment
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header_64 *h = (const void *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command *lc = (const void *)(h + 1);
        for (uint32_t c = 0; c < h->ncmds; c++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
            if (lc->cmd != LC_SEGMENT_64) continue;
            const struct segment_command_64 *seg = (const void *)lc;
            const struct section_64 *sect = (const void *)(seg + 1);
            for (uint32_t k = 0; k < seg->nsects; k++, sect++) {
                if (strncmp(sect->sectname, "__cfstring", 16)) continue;
                uintptr_t start = sect->addr + slide;
                if ((uintptr_t)v >= start && (uintptr_t)v < start + sect->size) return YES;
            }
        }
    }
    return NO;
}
static NSString *segmentOf(const void *p) {
    Dl_info info; if (!dladdr(p, &info)) return @"?";
    const struct mach_header_64 *h = info.dli_fbase; const struct load_command *lc = (const void *)(h + 1);
    intptr_t slide = 0;
    for (uint32_t c = 0; c < h->ncmds; c++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        const struct segment_command_64 *seg = (const void *)lc;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(seg->segname, "__TEXT")) slide = (intptr_t)h - (intptr_t)seg->vmaddr;
    }
    lc = (const void *)(h + 1);
    for (uint32_t c = 0; c < h->ncmds; c++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        const struct segment_command_64 *seg = (const void *)lc;
        if (lc->cmd != LC_SEGMENT_64) continue;
        uintptr_t start = seg->vmaddr + slide;
        if ((uintptr_t)p >= start && (uintptr_t)p < start + seg->vmsize) return @(seg->segname);
    }
    return @"?";
}
int main(void) {
    char line[1024];
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\n")] = 0;
        char *tab = strchr(line, '\t'); if (!tab) continue; *tab = 0;
        const char *lib = line, *sym = tab + 1;
        dlopen(lib, RTLD_LAZY | RTLD_GLOBAL);
        if (!strncmp(sym, "_OBJC_CLASS_$_", 14) || !strncmp(sym, "_OBJC_METACLASS_$_", 18)) {   // a metaclass comes with its class
            const char *name = strchr(sym, '$') + 2;
            Class c = objc_getClass(name), s = c ? class_getSuperclass(c) : Nil;
            printf("_OBJC_CLASS_$_%s\tclass\t%s\n", name, s ? class_getName(s) : "NSObject"); continue;
        }
        void *p = dlsym(RTLD_DEFAULT, sym + 1);
        if (!p) { printf("%s\tmissing\t\n", sym); continue; }
        NSString *seg = segmentOf(p);
        if ([seg isEqual:@"__TEXT"]) { printf("%s\tfunction\t\n", sym); continue; }
        const void *v = *(const void *const *)p;
        if (v && inCFStrings(v)) {
            NSString *s = (__bridge NSString *)v;
            NSData *json = [NSJSONSerialization dataWithJSONObject:@[s] options:0 error:nil];
            printf("%s\tstring\t%s\n", sym, [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
        } else printf("%s\tdata\t%s\n", sym, seg.UTF8String);
    }
}
'''

def main():
    gaps = os.path.join(here, "ios-link-gaps.txt")
    entries, fw = [], None
    for line in open(gaps):
        m = re.match(r"## (\S+) \(", line)
        if m: fw = m.group(1); continue
        if fw and line.startswith("_"): entries.append((fw, line.split()[0]))
    with tempfile.TemporaryDirectory() as t:
        exe = os.path.join(t, "classify")
        src = os.path.join(t, "classify.m")
        open(src, "w").write(HELPER)
        subprocess.check_call(["clang", "-fobjc-arc", "-framework", "Foundation", src, "-o", exe])
        stdin = "".join(f"{LIBS.get(f, f'/System/Library/Frameworks/{f}.framework/{f}')}\t{s}\n" for f, s in entries)
        out = subprocess.run([exe], input=stdin, capture_output=True, text=True, check=True).stdout
    kinds = {}
    for row in out.splitlines():
        sym, kind, extra = (row.split("\t") + ["", ""])[:3]
        kinds[sym] = (kind, extra)
    os.makedirs(out_dir, exist_ok=True)
    head = ("// GENERATED by prep/steam-onehost/gen_stubs.py from prep/steam-onehost/ios-link-gaps.txt; do not edit.\n"
            "// libShackSteamClient: what the macOS Steam client imports that iOS and MacShack's shims lack.\n")
    funcs = sorted(s for s, (k, _) in kinds.items() if k in ("function", "missing"))
    with open(os.path.join(out_dir, "StubFunctions.c"), "w") as f:
        f.write(head + "// Each returns 0 in x0 and d0 and logs its first call. No SDK headers: they would declare other signatures.\n"
                "void ShackSteamStubCalled(const char *name);\n"
                "#define STUB(name) long name(void) { static int seen; if (!seen++) ShackSteamStubCalled(#name); \\\n"
                "    __asm__ volatile(\"movi d0, #0\" ::: \"d0\"); return 0; }\n\n")
        for s in funcs: f.write(f"STUB({s[1:]})\n")
    with open(os.path.join(out_dir, "StubData.m"), "w") as f:
        f.write(head + "#import <Foundation/Foundation.h>\n#import <os/log.h>\n\n"
                "void ShackSteamStubCalled(const char *name) { os_log(OS_LOG_DEFAULT, \"[SteamClient] stub called: %{public}s\", name); }\n\n"
                "// Stub classes answer any message through libShackAppKit's safety net (logged once, returns 0/nil).\n"
                "NSMethodSignature *ShackStubSignature(SEL sel);\nvoid ShackStubInvoke(id self, NSInvocation *inv);\n"
                "#define STUB_SAFETY_NET \\\n"
                "- (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [super methodSignatureForSelector:s] ?: ShackStubSignature(s); } \\\n"
                "- (void)forwardInvocation:(NSInvocation *)i { ShackStubInvoke(self, i); } \\\n"
                "+ (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [super methodSignatureForSelector:s] ?: ShackStubSignature(s); } \\\n"
                "+ (void)forwardInvocation:(NSInvocation *)i { ShackStubInvoke(self, i); }\n\n")
        for s in sorted(s for s, (k, _) in kinds.items() if k == "string"):
            value = eval(kinds[s][1])[0]   # the JSON array the helper printed
            f.write(f"NSString *const {s[1:]} = @{json_c(value)};\n")
        for s in sorted(s for s, (k, _) in kinds.items() if k == "data"):
            f.write(f"const unsigned char {s[1:]}[64] = {{0}};   // {kinds[s][1]}\n")
        f.write("\n")
        needed, todo = set(), [kinds[s][1] for s, (k, _) in kinds.items() if k == "class" and kinds[s][1] in SHIM_CLASSES]
        while todo:   # each shim superclass and its own ancestors, declared root first
            c = todo.pop()
            if c in SHIM_CLASSES and c not in needed: needed.add(c); todo.append(SHIM_CLASSES[c])
        def depth(c): return 0 if c not in SHIM_CLASSES else 1 + depth(SHIM_CLASSES[c])
        for c in sorted(needed, key=depth): f.write(f"@interface {c} : {SHIM_CLASSES[c]}\n@end\n")
        for s in sorted(s for s, (k, _) in kinds.items() if k == "class"):
            sup = kinds[s][1] if kinds[s][1] in KEEP_SUPER else "NSObject"
            net = "" if sup in SHIM_CLASSES else "STUB_SAFETY_NET\n"   # shim superclasses already have the net
            f.write(f"@interface {s[14:]} : {sup}\n@end\n@implementation {s[14:]}\n{net}@end\n")
    counts = {}
    for k, _ in kinds.values(): counts[k] = counts.get(k, 0) + 1
    print(f"{len(entries)} symbols -> {out_dir}: {counts}")

def json_c(value):
    """A C string literal for an Objective-C @"..." constant."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'

if __name__ == "__main__":
    main()
