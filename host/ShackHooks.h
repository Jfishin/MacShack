#import <Foundation/Foundation.h>
// Make the process look like the guest: NSBundle.mainBundle, CFBundleGetMainBundle,
// _NSGetExecutablePath and proc_pidpath all answer with the guest's paths.
// guestCodePath is the signed copy of the guest's Mach-Os (Frameworks/Guests/<Name>, same layout as the bundle):
// a dlopen of a Mach-O inside the guest bundle loads that copy instead (the Documents one is the unsigned Mac file).
void ShackHooksInstall(NSString *guestBundlePath, NSString *guestExecPath, NSString *guestCodePath);
// Guest images prepared under another name: code-relative path -> the bundle-relative original whose name
// _dyld_get_image_name and dladdr report for it (Steam Helper's private tier0, vstdlib and SDL3).
void ShackHooksSetImageAliases(NSDictionary<NSString *, NSString *> *aliases);
// A second guest in this process (a game the Steam client starts, beside Steam): its code and the thread that adopts
// it see its bundle, executable, prepared code and defaults; its exit calls ended instead of ending MacShack's run.
// translated: an Intel game (AArchX), whose calls come from libOcerz and its JIT pool, not from images under codePath.
void ShackHooksAddGuest(NSString *bundlePath, NSString *execPath, NSString *codePath, BOOL translated, void (^ended)(int code));
void ShackHooksAdoptGuestThread(void);   // the calling thread is the second guest's main thread
BOOL ShackHooksIsSecondCaller(const void *pc);   // pc is in the second guest's code, or this is its main thread
void ShackHooksEnableGL(void);   // desktop OpenGL on ES for a guest that needs it (as SHACK_OPENGL=1 at install)
// Case-insensitive lookup of a guest path (the guest expects a case-insensitive volume). YES and the on-disk
// spelling in out if some component needed a case fix; NO if nothing matched or the path is not the guest's.
BOOL ShackResolveCase(const char *path, char *out, size_t n);
// The replacement ShackHooksInstall made for this symbol, when an Intel game (AArchX) should get it too; else NULL.
void *ShackHookForGuestSymbol(const char *name);
// Asked after ShackHookForGuestSymbol's own replacements (the Steam client's answers for an Intel game it started).
void ShackHooksSetGuestSymbolAnswer(void *(*answer)(const char *name));
// The game ended (exit or main returned): posts ShackGuestExited on the main queue; the host returns to Home.
void ShackGuestEnded(int code);
// Really end MacShack (relaunch into another game, Force Quit); a plain exit() is a guest ending once hooks are in.
void ShackExitProcess(int code);
