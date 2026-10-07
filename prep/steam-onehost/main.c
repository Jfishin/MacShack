// shacksteam: the host process. Everything lives in libonehost.dylib (see onehost.m).
int onehost_main(int, char **, char **, char **);
int main(int argc, char **argv, char **envp, char **apple) { return onehost_main(argc, argv, envp, apple); }
