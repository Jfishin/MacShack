#pragma once
// On-device signing feasibility probe: dlopen every dylib under Library/SignProbe and Documents/SignProbe, call its
// shack_probe(), and log what AMFI/dyld said to Documents/Logs/sign-probe.log. `--sign-probe` runs it.
void ShackSignProbe(void);
