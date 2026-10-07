// The legacy keychain and Authorization Services calls a macOS game makes for saved logins and admin rights. iOS has
// neither API (a free developer account has no keychain access group to hand a guest anyway): the keychain is always
// empty and authorization never succeeds, as for a sandboxed app on a Mac.
#import <Foundation/Foundation.h>
enum { kShackErrSecItemNotFound = -25300, kShackErrSecUnimplemented = -4, kShackAuthInternal = -60008 };
int32_t SecKeychainFindGenericPassword(void *keychain, UInt32 svcLen, const char *svc, UInt32 accLen, const char *acc,
                                       UInt32 *pwLen, void **pw, void **item) {
    if (pwLen) *pwLen = 0; if (pw) *pw = NULL; if (item) *item = NULL; return kShackErrSecItemNotFound;
}
int32_t SecKeychainAddGenericPassword(void *keychain, UInt32 svcLen, const char *svc, UInt32 accLen, const char *acc,
                                      UInt32 pwLen, const void *pw, void **item) { if (item) *item = NULL; return kShackErrSecUnimplemented; }
int32_t SecKeychainItemCopyAttributesAndData(void *item, void *info, void *itemClass, void **attrList, UInt32 *length, void **outData) {
    return kShackErrSecItemNotFound;
}
int32_t SecKeychainItemFreeAttributesAndData(void *attrList, void *data) { return 0; }
int32_t SecKeychainItemModifyContent(void *item, const void *attrList, UInt32 length, const void *data) { return kShackErrSecItemNotFound; }
int32_t SecKeychainItemDelete(void *item) { return kShackErrSecItemNotFound; }
int32_t SecCertificateAddToKeychain(void *cert, void *keychain) { return kShackErrSecUnimplemented; }
int32_t AuthorizationCreate(const void *rights, const void *env, UInt32 flags, void **auth) { if (auth) *auth = NULL; return kShackAuthInternal; }
int32_t AuthorizationCopyRights(void *auth, const void *rights, const void *env, UInt32 flags, void **authorized) { return kShackAuthInternal; }
int32_t AuthorizationFree(void *auth, UInt32 flags) { return 0; }
