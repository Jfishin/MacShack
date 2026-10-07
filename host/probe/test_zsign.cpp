#include "common.h"
#include "macho.h"

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    ZSignAsset asset;
    if (!asset.Init("", "", "", "", "", true, true, true)) return 1;
    ZMachO macho;
    return macho.Init(argv[1]) && macho.Sign(&asset, true, "com.example.macshack", "", "", "") ? 0 : 1;
}
