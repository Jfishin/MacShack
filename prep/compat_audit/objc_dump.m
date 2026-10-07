// Dump every loaded class's own methods: "C\tclass\tsuper\timage", then "+/-\tclass\tselector".
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) if (!dlopen(argv[i], RTLD_NOW)) fprintf(stderr, "dlopen %s: %s\n", argv[i], dlerror());
        unsigned n; Class *cs = objc_copyClassList(&n);
        for (unsigned i = 0; i < n; i++) {
            Class c = cs[i]; const char *name = class_getName(c), *img = class_getImageName(c);
            Class sup = class_getSuperclass(c);
            printf("C\t%s\t%s\t%s\n", name, sup ? class_getName(sup) : "", img ? img : "");
            for (int meta = 0; meta < 2; meta++) {
                unsigned m; Method *ms = class_copyMethodList(meta ? object_getClass((id)c) : c, &m);
                for (unsigned j = 0; j < m; j++) printf("%c\t%s\t%s\n", meta ? '+' : '-', name, sel_getName(method_getName(ms[j])));
                free(ms);
            }
        }
        free(cs);
        unsigned pn; Protocol * __unsafe_unretained *ps = objc_copyProtocolList(&pn);
        for (unsigned i = 0; i < pn; i++) {
            const char *pname = protocol_getName(ps[i]);
            printf("P\t%s\n", pname);
            for (int req = 0; req < 2; req++) for (int inst = 0; inst < 2; inst++) {
                unsigned k; struct objc_method_description *d = protocol_copyMethodDescriptionList(ps[i], req, inst, &k);
                for (unsigned j = 0; j < k; j++) printf("p%c\t%s\t%s\n", inst ? '-' : '+', pname, sel_getName(d[j].name));
                free(d);
            }
        }
        free(ps);
    }
    return 0;
}
