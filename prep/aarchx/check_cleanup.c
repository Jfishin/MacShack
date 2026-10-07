#include <pthread.h>
#include <stdio.h>
static int ran;
static void handler(void *a) { ran += (int)(long)a; }
static void *body(void *x) {
    pthread_cleanup_push(handler, (void *)1);
    pthread_cleanup_push(handler, (void *)10);
    pthread_exit(0);
    pthread_cleanup_pop(0);
    pthread_cleanup_pop(0);
    return 0;
}
int main(void) {
    pthread_t t; pthread_create(&t, 0, body, 0); pthread_join(t, 0);
    printf("cleanup ran=%d (expect 11)\n", ran);
    return ran == 11 ? 0 : 1;
}
