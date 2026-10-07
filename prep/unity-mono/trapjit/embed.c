// Minimal Unity-style embedder: runs an .exe on a game's own shipped libmonobdwgc.
// embed <libmonobdwgc> <Managed dir> <MonoBleedingEdge dir> <exe> [args]
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#define F(ret, name, ...) ret (*name)(__VA_ARGS__) = (ret (*)(__VA_ARGS__))dlsym(h, #name)
int main(int argc, char **argv) {
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
    if (!h) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    F(void, mono_set_dirs, const char *, const char *);
    F(void, mono_set_assemblies_path, const char *);
    F(void, mono_config_parse, const char *);
    F(void *, mono_jit_init_version, const char *, const char *);
    F(void *, mono_domain_assembly_open, void *, const char *);
    F(int, mono_jit_exec, void *, void *, int, char **);
    char lib[4096], etc[4096];
    snprintf(lib, sizeof lib, "%s/lib", argv[3]); snprintf(etc, sizeof etc, "%s/etc", argv[3]);
    mono_set_dirs(lib, etc);
    mono_set_assemblies_path(argv[2]);
    mono_config_parse(NULL);
    void *d = mono_jit_init_version("embed", "v4.0.30319");
    void *a = mono_domain_assembly_open(d, argv[4]);
    if (!a) { fprintf(stderr, "cannot open %s\n", argv[4]); return 1; }
    return mono_jit_exec(d, a, argc - 4, argv + 4);
}
