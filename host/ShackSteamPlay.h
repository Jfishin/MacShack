#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Steam Play in MacShack's Steam (README, "Windows games"): Windows games in the
// macOS Steam client, run in MacShack Play.

// Steam Play's three changes to Steam's steamclient (client 1788652215, the build MacShack pins;
// prep/steam-onehost/steamplay_sites.py finds them in another build), made in the prepared copy before it is signed:
// the arm64 slice of the file at `path` (fat or thin) is changed only when every site holds its original instruction
// (or already the new one). Returns "patched N site(s)", "already patched", or "not patched: <why>".
NSString *ShackSteamPlayPatch(NSString *path);
// The same without writing: "would patch N site(s)" (Valve's original), "already patched", or "not patched: <why>".
NSString *ShackSteamPlayCheck(NSString *path);

// The compat tool's name (it contains "proton": Steam maps Windows cloud-save paths into the prefix only for such
// tools) and whether a program Steam starts is its `run`, i.e. a Windows program for MacShack Play.
extern NSString *const ShackSteamPlayTool;
BOOL ShackSteamPlayIsTool(const char *_Nullable path);

// Before steam_osx starts: the tool in <steamRoot>/compatibilitytools.d (STEAM_EXTRA_COMPAT_TOOLS_PATHS), Steam's
// global mapping to it (Windows-only games use it), and the App Group's SteamLibrary as a Steam library (Windows games
// and their prefixes, which MacShack Play reads). Only adds what is missing; logs what it did.
void ShackSteamPlaySetup(NSString *steamRoot, NSURL *_Nullable group);

// Text edits of Steam's VDF files (nil: nothing to add, or a shape this does not know). config.vdf gets
// CompatToolMapping { "0" { name `tool`, priority 75 } } under InstallConfigStore/Software/Valve/Steam;
// libraryfolders.vdf a library at `path` under the next index.
NSString *_Nullable ShackVDFAddCompatMapping(NSString *config, NSString *tool);
NSString *_Nullable ShackVDFAddLibrary(NSString *folders, NSString *path, NSString *label, NSString *contentID);

// The switch off, once Windows games are removed (Settings > Windows games), before steam_osx starts: the tool's
// folder, every CompatToolMapping entry naming the tool (Steam's global one, per-game ones), and the App Group's
// SteamLibrary entry. The library's files stay (WindowsSetup's Remove deletes them only when asked). Only removes what
// is there; a file Steam never wrote is left alone.
void ShackSteamPlayRemove(NSString *steamRoot, NSURL *_Nullable group);

// Text edits undoing ShackVDFAddCompatMapping and ShackVDFAddLibrary (nil: nothing of ours there). config.vdf loses
// every CompatToolMapping entry naming `tool`, and the block itself once empty; libraryfolders.vdf the entry for `path`.
NSString *_Nullable ShackVDFRemoveCompatMapping(NSString *config, NSString *tool);
NSString *_Nullable ShackVDFRemoveLibrary(NSString *folders, NSString *path);

NS_ASSUME_NONNULL_END
