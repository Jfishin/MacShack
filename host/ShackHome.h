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
// The app's own: its container, <App Group>/Home, Application Support and Logs; the report goes to
// Documents/Logs/shared-home.txt. Call first, before anything reads those folders. Without an App Group: nothing.
NSString *ShackHomeEnsure(void);
// <App Group> (group.<MacShack's bundle id>), or nil.
NSString *_Nullable ShackHomeGroup(void);
// Game settings between the apps: cfprefsd keeps each app's own; <home>/Library/Preferences/<domain>.plist carries
// them across. For each domain (file in either folder, none of skipPrefixes): the newer side wins; an export also gives
// the shared file the local file's date, so the next sync changes nothing. Returns "settings: N in, M out".
NSString *ShackPrefsSync(NSString *localPrefs, NSString *sharedPrefs, NSArray<NSString *> *skipPrefixes);
// The app's own (container Library/Preferences, <App Group>/Home/Library/Preferences; MacShack's own domains, Apple's,
// Valve's and Chromium's skipped). At app start, and at each game's start and end.
NSString *ShackHomePrefsSync(void);
// What devicectl cannot reach behind the links, copied into Documents/Logs/Shared: Library/Logs (Unity's Player.log)
// and Steam's logs/*.txt. At app start and after each game.
void ShackHomeMirrorLogs(void);
NS_ASSUME_NONNULL_END
