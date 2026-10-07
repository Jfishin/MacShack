// Mac: clang -fobjc-arc -Wall -Wextra -Werror shims/Security/ShackMacCodeTrust.m \
//   host/probe/test_mac_code_trust.m -framework CoreFoundation -framework Security -o /tmp/mac-code-trust
// /tmp/mac-code-trust <valid Developer ID Mach-O> [<corrupted signed Mach-O> ...]
#include "../../shims/Security/ShackMacCodeTrust.h"
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s valid-library [corrupted-library ...]\n", argv[0]); return 2; }
    if (ShackMacCodeTrustValidate(NULL, true) != -66996) return 1;
    for (int i = 1; i < argc; i++) {
        CFURLRef path = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[i], strlen(argv[i]), false);
        SecStaticCodeRef code = NULL;
        OSStatus create = path ? SecStaticCodeCreateWithPath(path, 0, &code) : -1;
        OSStatus result = create == 0 && code ? ShackMacCodeTrustValidate(code, true) : -66996;
        if (code) CFRelease(code);
        if (path) CFRelease(path);
        printf("fixture=%d create=%d result=%d expected=%d\n", i, (int)create, (int)result, i == 1 ? 0 : -66996);
        if (create != 0 || result != (i == 1 ? 0 : -66996)) return 1;
    }
    return 0;
}
