// Mac check for host/ShackPlayMach.m, the MacShack Play bridge's Mach rendezvous:
// clang -fobjc-arc -Ihost host/ShackPlayMach.m host/probe/test_play_mach.m -framework Foundation -o /tmp/t && /tmp/t
// Expect `play mach ok`. On the phone the same calls go between the two apps, under their App Group's name.
#import "ShackPlay.h"
#include <stdio.h>
#include <unistd.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x); return 1; } } while (0)

int main(void) {
    char name[128];
    snprintf(name, sizeof name, "com.macshack.test-play.%d", getpid());
    dispatch_queue_t queue = dispatch_queue_create("serve", DISPATCH_QUEUE_SERIAL);
    __block int pings = 0;
    dispatch_semaphore_t gone = dispatch_semaphore_create(0);
    mach_port_t ipc = MACH_PORT_NULL;   // a service of the server's own, as Steam's ipcserver in MacShack
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &ipc);
    mach_port_insert_right(mach_task_self(), ipc, ipc, MACH_MSG_TYPE_MAKE_SEND);
    CHECK(ShackPlayServe(name, queue, ^(const ShackPlayMessage *request, ShackPlayMessage *reply) {
        if (request->kind == ShackPlayPing) { pings++; reply->value = request->value + 1; }
        if (request->kind == ShackPlaySteamIPC) {   // a send right of its own, moved into the reply
            mach_port_mod_refs(mach_task_self(), ipc, MACH_PORT_RIGHT_SEND, 1);
            reply->port.name = ipc;
            reply->port.disposition = MACH_MSG_TYPE_MOVE_SEND;
        }
    }, ^{ dispatch_semaphore_signal(gone); }) == KERN_SUCCESS);

    mach_port_t session = MACH_PORT_NULL;   // a right that came in a reply
    CHECK(ShackPlayConnect(name, &session) == KERN_SUCCESS);
    CHECK(MACH_PORT_VALID(session));
    ShackPlayMessage reply;
    CHECK(ShackPlayCall(session, ShackPlayPing, 41, 1000, &reply) == KERN_SUCCESS);
    CHECK(reply.kind == ShackPlayPing && reply.value == 42 && reply.pid == getpid());
    __block int seen = 0;
    dispatch_sync(queue, ^{ seen = pings; });
    CHECK(seen == 1);
    CHECK(ShackPlayCall(session, ShackPlaySteamIPC, 0, 1000, &reply) == KERN_SUCCESS && MACH_PORT_VALID(reply.port.name));
    mach_msg_header_t hi = { .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0), .msgh_size = sizeof hi,
                             .msgh_remote_port = reply.port.name, .msgh_id = 77 };
    CHECK(mach_msg(&hi, MACH_SEND_MSG, sizeof hi, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL) == MACH_MSG_SUCCESS);
    struct { mach_msg_header_t h; mach_msg_max_trailer_t t; } got = {0};   // it reached the service
    CHECK(mach_msg(&got.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof got, ipc, 1000, MACH_PORT_NULL) == MACH_MSG_SUCCESS && got.h.msgh_id == 77);
    mach_port_deallocate(mach_task_self(), reply.port.name);

    // The client goes away (its send right with it): the server hears it, as MacShack hears MacShack Play die.
    CHECK(dispatch_semaphore_wait(gone, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) != 0);   // not while held
    mach_port_deallocate(mach_task_self(), session);
    CHECK(dispatch_semaphore_wait(gone, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
    CHECK(ShackPlayConnect(name, &session) == KERN_SUCCESS);   // a second client, heard again
    mach_port_deallocate(mach_task_self(), session);
    CHECK(dispatch_semaphore_wait(gone, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);

    mach_port_t dead = MACH_PORT_NULL;   // a server that went away: our send right is a dead name
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &dead);
    mach_port_insert_right(mach_task_self(), dead, dead, MACH_MSG_TYPE_MAKE_SEND);
    mach_port_mod_refs(mach_task_self(), dead, MACH_PORT_RIGHT_RECEIVE, -1);
    CHECK(ShackPlayCall(dead, ShackPlayPing, 1, 200, &reply) == MACH_SEND_INVALID_DEST);

    mach_port_t mute = MACH_PORT_NULL;   // a server that never answers (suspended)
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &mute);
    mach_port_insert_right(mach_task_self(), mute, mute, MACH_MSG_TYPE_MAKE_SEND);
    CHECK(ShackPlayCall(mute, ShackPlayPing, 1, 200, &reply) == MACH_RCV_TIMED_OUT);

    CHECK(ShackPlayConnect("com.macshack.test-play.nobody", &session) != KERN_SUCCESS);
    printf("play mach ok\n");
    return 0;
}
