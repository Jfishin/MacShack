// macOS-only SwiftUI symbols (AppKit hosting). Re-exports SwiftUI; guests' SwiftUI links point here.
// Hades II binds NSHostingController and Image(nsImage:) for a macOS-only window. These let the game load; if a game
// ever reaches them, the log names the call before the abort. ponytail: bridge to UIHostingController when one does.
#include <stdio.h>
#include <stdlib.h>

#define TRAP(name, sym) \
    void name(void) __asm__(sym); \
    void name(void) { fprintf(stderr, "[ShackSwiftUI] unsupported macOS SwiftUI call %s\n", &sym[1]); abort(); }   /* drop the leading underscore */
TRAP(shack_NSHostingController_init, "_$s7SwiftUI19NSHostingControllerC8rootViewACyxGx_tcfc")
TRAP(shack_Image_init_nsImage, "_$s7SwiftUI5ImageV02nsC0ACSo7NSImageC_tcfC")

// Nominal type descriptor of NSHostingController: data, only read when the game builds that type's metadata.
const char shack_NSHostingController_descriptor[64] __asm__("_$s7SwiftUI19NSHostingControllerCMn") = {0};
