#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Madeira's engine finds its files two ways, as in its own app: through [NSBundle mainBundle] (WineProcessBridge.m and
// WineServerBridge.m), and, in its ntdll's init_paths(), through the folder of _NSGetExecutablePath (the DLLs, nls files
// and tools sit beside the executable). In MacShack Play the engine lives in the App Group (Windows/engine, set up by
// MacShack), so calls that come from the engine's image get a bundle at `dir` and an executable path inside `dir`
// (`dir`/MacShackPlay, which need not exist); every other caller still gets Play's own. `image` is any address inside
// the engine (a symbol from dlsym); call before the engine runs.
void ShackEngineBundleRedirect(const void *image, NSString *dir);

NS_ASSUME_NONNULL_END
