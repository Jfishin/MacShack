// libcurl stubs in libShackSystem (Cyberpunk 2077's HTTP pool). iOS simulator (ShackSystem.c uses iOS-only API):
//   xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=26.0 shims/System/ShackSystem.c \
//     host/probe/test_curl_stub.c -framework CoreFoundation -o /tmp/t && xcrun simctl spawn booted /tmp/t
// expect `curl stub ok`.
#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct { int msg; void *easy; union { void *whatever; int result; } data; } Msg;
void *curl_easy_init(void); void curl_easy_cleanup(void *);
int curl_easy_setopt(void *, int, ...); int curl_easy_perform(void *); int curl_easy_getinfo(void *, int, ...);
void *curl_multi_init(void); int curl_multi_cleanup(void *);
int curl_multi_add_handle(void *, void *); int curl_multi_remove_handle(void *, void *);
int curl_multi_perform(void *, int *); Msg *curl_multi_info_read(void *, int *);
struct curl_slist { char *data; struct curl_slist *next; };
struct curl_slist *curl_slist_append(struct curl_slist *, const char *); void curl_slist_free_all(struct curl_slist *);

int main(void) {
    int tag; char errors[256] = "x"; long code = 99; void *priv = NULL;
    void *a = curl_easy_init(), *b = curl_easy_init();
    assert(a && b);
    curl_easy_setopt(a, 10103, &tag);    // CURLOPT_PRIVATE
    curl_easy_setopt(a, 10010, errors);  // CURLOPT_ERRORBUFFER
    assert(curl_easy_perform(a) == 7 && strstr(errors, "connect"));
    curl_easy_getinfo(a, 0x100015, &priv);   // CURLINFO_PRIVATE
    curl_easy_getinfo(a, 0x200002, &code);   // CURLINFO_RESPONSE_CODE
    assert(priv == &tag && code == 0);

    void *m = curl_multi_init(); int running = 1, left = -1;
    curl_multi_add_handle(m, a); curl_multi_add_handle(m, b);
    curl_multi_perform(m, &running);
    assert(running == 0);
    Msg *msg = curl_multi_info_read(m, &left);
    assert(msg && msg->msg == 1 && msg->easy == a && msg->data.result == 7 && left == 1);
    curl_multi_remove_handle(m, a);
    msg = curl_multi_info_read(m, &left);
    assert(msg && msg->easy == b && left == 0);
    assert(!curl_multi_info_read(m, &left));
    curl_multi_cleanup(m); curl_easy_cleanup(a); curl_easy_cleanup(b);

    struct curl_slist *l = curl_slist_append(curl_slist_append(NULL, "A: 1"), "B: 2");
    assert(!strcmp(l->data, "A: 1") && !strcmp(l->next->data, "B: 2") && !l->next->next);
    curl_slist_free_all(l);
    puts("curl stub ok");
}
