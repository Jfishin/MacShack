/* MacShack: what the guest GNU libstdc++ (MacPorts' GCC build) needs beyond libSystem.
 * GNU iconv.h renames iconv_open, iconv and iconv_close to libiconv*; the system
 * library has only the plain names.  Linking the guest libunwind here loads it with
 * libstdc++, so ocerz sends libSystem's _Unwind_* imports to guest frames' unwinder. */
#include <iconv.h>
iconv_t libiconv_open(const char *to, const char *from) { return iconv_open(to, from); }
size_t libiconv(iconv_t cd, char **in, size_t *inleft, char **out, size_t *outleft) { return iconv(cd, in, inleft, out, outleft); }
int libiconv_close(iconv_t cd) { return iconv_close(cd); }
