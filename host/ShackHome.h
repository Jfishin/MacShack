#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// The shared home: MacShack and MacShack Play keep games' files in their App Group's Home, so a game finds the same
// saves, settings and logs in either app. Each app's own Library folders below become links into it (iOS ignores HOME:
// NSSearchPath and NSHomeDirectory answer the container, and the links lead from there).
// For each folder (relative, e.g. "Library/Application Support"): the container's entries move into home/<folder>
// (rename; the container's copy wins and a clashing one already there is set aside as "<name> (set aside <date>)"; a
// link in it that leads into home is dropped), the emptied folder becomes a link; a link leading elsewhere is pointed
// at home again; a missing folder is linked. A rename iOS refuses stops that folder (it stays a real folder, nothing is
// lost). Returns one report line per folder.
NSString *ShackHomeLink(NSString *container, NSString *home, NSArray<NSString *> *folders);
// A Wine user profile (a prefix's drive_c/users/<user>): macOS Steam's Steam Cloud keeps a Windows game's files under
// Windows XP's folder names (WinAppDataLocal in Local Settings/Application Data, WinMyDocuments in My Documents), and
// Wine's games use Vista's. As on Windows, each old name becomes a link to its new folder (AppData/Local, Documents,
// AppData/Roaming), as ShackHomeLink does: Steam's entries move there first, its copy winning (the cloud's) and a
// clashing one set aside. One report part per folder.
NSString *ShackWineProfileLinks(NSString *profile);
// A Wine prefix's registry (system.reg) gains the entries the Visual C++ 2015-2022 runtime package leaves
// (VC\Runtimes\x64 and arm64, both registry views), once. Unreal's launcher (5.3+) checks them, for arm64 on Madeira (x64
// on ARM), and otherwise waits on a "required components" dialog nobody sees (Pizzapocalypse 2); the runtime's DLLs are
// Wine's own. ponytail: only once the prefix exists (a game's first start makes system.reg), so a new Unreal game gets
// them from its second start; call before the engine starts.
NSString *ShackWineVCRuntime(NSString *prefix);
// The app's own: its container, <App Group>/Home, Application Support and Logs; the report goes to
// Documents/Logs/shared-home.txt. Call first, before anything reads those folders. Without an App Group: nothing.
NSString *ShackHomeEnsure(void);
// <App Group> (group.<MacShack's bundle id>), or nil.
NSString *_Nullable ShackHomeGroup(void);
// Game settings between the apps: cfprefsd keeps each app's own; <home>/Library/Preferences/<domain>.plist carries
// them across, and syncedPrefs (this app's own folder) holds what this app last synced. For each domain (a file in any
// of the folders, none of skipPrefixes), against that last sync: changed only there, it comes in (keys deleted there
// go here too); changed only here, it goes out; both, the newer file wins. Decided by content, not cfprefsd's file
// dates, which trail the values by seconds. Returns "settings: N in, M out".
NSString *ShackPrefsSync(NSString *localPrefs, NSString *sharedPrefs, NSString *syncedPrefs, NSArray<NSString *> *skipPrefixes);
// The app's own (container Library/Preferences, <App Group>/Home/Library/Preferences; MacShack's own domains, Apple's,
// Valve's and Chromium's skipped). At app start, and at each game's start and end.
NSString *ShackHomePrefsSync(void);
// What devicectl cannot reach behind the links, copied into Documents/Logs/Shared: Library/Logs (Unity's Player.log),
// Steam's logs/*.txt and MacShack Play's Mac games' own logs (<App Group>/Logs/*.log, "Play logs"). At app start and
// after each game.
void ShackHomeMirrorLogs(void);
// Data beside the games in Local Games (a staged folder's own: Batman's BMAAData, steam_appid.txt) for MacShack Play,
// which reads only the App Group: each entry of games that is not a .app, an .args or a link moves (a rename) into
// shared under the same name, and a link to it is left in games, so MacShack and Play both find it beside the game.
// A name already in shared is left alone. Returns one line per entry, empty when there is nothing to do.
NSString *ShackShareGameData(NSString *games, NSString *shared);
// Files put in Documents/HomeImport (devicectl reaches Documents; the shared home is behind links it does not follow):
// each moves into home at the same relative path, replacing a file already there (Batman's Feral settings); other files
// in home stay. The import folder goes once everything moved. Returns "imported N file(s)" (and any that failed), or
// nothing when there is nothing to import. ShackHomeEnsure calls it at app start.
NSString *ShackHomeImport(NSString *from, NSString *home);
// Debugging what devicectl cannot reach behind the links: each path (relative to home, one per line) in the file list
// is copied to the same relative path under to, a folder whole. Paths that leave home are refused. One line per path.
// ShackHomeMirrorLogs runs it with Documents/HomeExport.txt into Documents/Logs/Shared/HomeExport.
NSString *ShackHomeExport(NSString *list, NSString *home, NSString *to);
NS_ASSUME_NONNULL_END
