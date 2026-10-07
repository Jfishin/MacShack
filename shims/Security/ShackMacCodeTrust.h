#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdbool.h>

// Independently validate every Mach-O slice as current, Apple Developer ID Application code.
// This does not interpose Security or change a caller's result. All failures return -66996.
OSStatus ShackMacCodeTrustValidate(CFTypeRef originalCode, bool probeWrongTeam);
