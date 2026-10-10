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
NS_ASSUME_NONNULL_END
