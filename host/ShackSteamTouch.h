#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
// Steam's Big Picture gets fingers as real touches, as on a Steam Deck: Chromium's own touch scrolling, momentum and taps.
// Mac Chromium has no touchscreen path, so each finger goes in as a DevTools Input.dispatchTouchEvent, sent in-process
// (cef_browser_host_t::send_dev_tools_message: no port, no socket) to the browser whose view is under the finger.

/// The Steam Helper's dlsym of cef_browser_host_create_browser: a wrapper that learns each browser Steam creates.
void *ShackSteamTouchCreateBrowser(void *real);
/// A finger on a view (the deepest under it; it and its ancestors are searched for a Steam browser's view). phase 0
/// starts, 1 moves, 2 ends, 3 cancels; w in window points, AppKit's bottom-left origin. NO for a start outside Steam's
/// browsers: the finger stays a mouse. Main thread (Chromium's UI thread).
BOOL ShackSteamTouch(id view, int phase, CGPoint w);
/// A pointer's scroll (trackpad or wheel) over a view: d in points as the content follows the fingers (UIKit's axes),
/// w as for ShackSteamTouch. NO outside Steam's browsers: a scroll wheel event. Main thread.
BOOL ShackSteamScroll(id view, CGPoint w, CGPoint d);
