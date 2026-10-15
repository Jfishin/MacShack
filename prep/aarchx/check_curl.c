// check_curl.c: AArchX's offline libcurl (MacShack: iOS has none). A request on a multi handle finishes at once with
// CURLE_COULDNT_RESOLVE_HOST; setopt, getinfo and slists work. Build and run in prep/aarchx/README.md (expect `curl offline ok`).
#include <curl/curl.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    curl_global_init(CURL_GLOBAL_ALL);
    CURLM *m = curl_multi_init();
    CURL *e = curl_easy_init();
    int set = curl_easy_setopt(e, CURLOPT_URL, "http://macshack.invalid/");
    struct curl_slist *h = curl_slist_append(NULL, "X-A: 1");
    h = curl_slist_append(h, "X-B: 2");
    curl_easy_setopt(e, CURLOPT_HTTPHEADER, h);
    curl_multi_add_handle(m, e);
    int running = -1, numfds = -1, left = -1;
    curl_multi_perform(m, &running);
    curl_multi_wait(m, NULL, 0, 10, &numfds);
    CURLMsg *msg = curl_multi_info_read(m, &left);
    long code = -1;
    curl_easy_getinfo(e, CURLINFO_RESPONSE_CODE, &code);
    int ok = set == 0 && running == 0 && numfds == 0 && msg && msg->msg == CURLMSG_DONE && msg->easy_handle == e &&
             msg->data.result == CURLE_COULDNT_RESOLVE_HOST && left == 0 && code == 0 && h->next && !strcmp(h->next->data, "X-B: 2");
    if (ok) printf("curl offline ok\n");
    else printf("curl offline BAD set=%d running=%d numfds=%d msg=%p left=%d code=%ld\n", set, running, numfds, (void *)msg, left, code);
    curl_multi_remove_handle(m, e);
    curl_slist_free_all(h);
    curl_easy_cleanup(e);
    curl_multi_cleanup(m);
    curl_global_cleanup();
    return !ok;
}
