// check_stacksize.c: an x86 guest sizes stacks in 4 KB pages (FMOD Studio's 72 KB mixer thread); a 16 KB-page host
// refuses that size with EINVAL unless AArchX rounds it up. Expect `stacksize ok`.
#include <pthread.h>
#include <stdio.h>
static void *run(void *a) { (void)a; return (void *)42; }
int main(void) {
    pthread_attr_t at;
    pthread_attr_init(&at);
    int set = pthread_attr_setstacksize(&at, 72 * 1024);
    pthread_t t;
    void *r = NULL;
    int made = pthread_create(&t, &at, run, NULL);
    if (!made) pthread_join(t, &r);
    if (set == 0 && made == 0 && r == (void *)42) printf("stacksize ok\n");
    else printf("stacksize BAD set=%d create=%d\n", set, made);
    return 0;
}
