#import "ShackPlay.h"
#import <mach/task_special_ports.h>
#import <unistd.h>

// The MacShack Play bridge's Mach rendezvous (host/ShackPlay.h). Mac check: host/probe/test_play_mach.m.

// libSystem exports these (CFMessagePort's own path: register2 for a local port, look_up for a remote one).
kern_return_t bootstrap_register2(mach_port_t bp, const char *name, mach_port_t port, uint64_t flags);
kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *port);
const char *bootstrap_strerror(kern_return_t kr);

typedef struct { ShackPlayMessage m; mach_msg_max_trailer_t trailer; } Received;

const char *ShackPlayError(kern_return_t kr) { return bootstrap_strerror(kr); }

static void keep(id source) {   // a dispatch source lives only while referenced
    static NSMutableArray *all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ all = [NSMutableArray array]; });
    @synchronized (all) { [all addObject:source]; }
}

// A no-senders notification for `session`, counted from the send rights made so far: it comes when every client's
// right is gone (the process holding it ended). Re-asked after each hello.
static void watchSenders(mach_port_t session, mach_port_t notify) {
    mach_port_status_t status;
    mach_msg_type_number_t count = MACH_PORT_RECEIVE_STATUS_COUNT;
    if (mach_port_get_attributes(mach_task_self(), session, MACH_PORT_RECEIVE_STATUS, (mach_port_info_t)&status, &count)) return;
    mach_port_t previous = MACH_PORT_NULL;
    if (mach_port_request_notification(mach_task_self(), session, MACH_NOTIFY_NO_SENDERS, status.mps_mscount, notify,
                                       MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous) == KERN_SUCCESS && MACH_PORT_VALID(previous))
        mach_port_deallocate(mach_task_self(), previous);   // the earlier request's (its send-once notice is ignored)
}

static void serve(mach_port_t port, mach_port_t session, mach_port_t notify, dispatch_queue_t queue,
                  void (^handle)(const ShackPlayMessage *, ShackPlayMessage *)) {
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, port, 0, queue);
    dispatch_source_set_event_handler(source, ^{
        for (;;) {
            Received in = {0};
            if (mach_msg(&in.m.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof in, port, 0, MACH_PORT_NULL) != MACH_MSG_SUCCESS)
                return;   // drained
            if (!(in.m.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) || in.m.header.msgh_size < sizeof(ShackPlayMessage) ||
                !MACH_PORT_VALID(in.m.header.msgh_remote_port)) {
                mach_msg_destroy(&in.m.header);   // not ours, or no reply port
                continue;
            }
            ShackPlayMessage out = {0};
            out.kind = in.m.kind;
            out.pid = getpid();
            out.value = in.m.value;
            out.port.name = in.m.kind == ShackPlayHello ? session : MACH_PORT_NULL;
            out.port.disposition = MACH_MSG_TYPE_MAKE_SEND;
            handle(&in.m, &out);
            out.header.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSGH_BITS_REMOTE(in.m.header.msgh_bits), 0, 0, MACH_MSGH_BITS_COMPLEX);
            out.header.msgh_size = sizeof out;
            out.header.msgh_remote_port = in.m.header.msgh_remote_port;
            out.header.msgh_id = in.m.header.msgh_id;
            out.body.msgh_descriptor_count = 1;
            out.port.type = MACH_MSG_PORT_DESCRIPTOR;
            if (mach_msg(&out.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof out, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL) != MACH_MSG_SUCCESS)
                mach_msg_destroy(&out.header);
            else if (in.m.kind == ShackPlayHello && MACH_PORT_VALID(notify))
                watchSenders(session, notify);
            if (MACH_PORT_VALID(in.m.port.name)) mach_port_deallocate(mach_task_self(), in.m.port.name);
        }
    });
    keep(source);
    dispatch_resume(source);
}

kern_return_t ShackPlayServe(const char *name, dispatch_queue_t queue,
                             void (^handle)(const ShackPlayMessage *, ShackPlayMessage *), void (^gone)(void)) {
    mach_port_t bp = MACH_PORT_NULL, service = MACH_PORT_NULL, session = MACH_PORT_NULL;
    task_get_bootstrap_port(mach_task_self(), &bp);
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &service);
    if (kr != KERN_SUCCESS) return kr;
    mach_port_insert_right(mach_task_self(), service, service, MACH_MSG_TYPE_MAKE_SEND);
    kr = bootstrap_register2(bp, name, service, 0);
    if (kr != KERN_SUCCESS) {
        mach_port_destruct(mach_task_self(), service, -1, 0);
        return kr;
    }
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &session);
    mach_port_t notify = MACH_PORT_NULL;
    if (gone && mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &notify) == KERN_SUCCESS) {
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, notify, 0, queue);
        dispatch_source_set_event_handler(source, ^{
            for (;;) {
                struct { mach_msg_header_t header; uint8_t body[64]; mach_msg_max_trailer_t trailer; } in = {0};
                if (mach_msg(&in.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof in, notify, 0, MACH_PORT_NULL) != MACH_MSG_SUCCESS)
                    return;
                if (in.header.msgh_id == MACH_NOTIFY_NO_SENDERS) gone();
                mach_msg_destroy(&in.header);
            }
        });
        keep(source);
        dispatch_resume(source);
    }
    serve(service, session, notify, queue, handle);
    serve(session, session, notify, queue, handle);
    return KERN_SUCCESS;
}

kern_return_t ShackPlayCall(mach_port_t port, int32_t kind, uint64_t value, int timeoutMs, ShackPlayMessage *reply) {
    mach_port_t replyPort = MACH_PORT_NULL;   // one per call: a late answer to an earlier call cannot pass for this one's
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &replyPort);
    if (kr != KERN_SUCCESS) return kr;
    ShackPlayMessage m = {0};
    m.header.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE, 0, MACH_MSGH_BITS_COMPLEX);
    m.header.msgh_size = sizeof m;
    m.header.msgh_remote_port = port;
    m.header.msgh_local_port = replyPort;
    m.header.msgh_id = kind;
    m.body.msgh_descriptor_count = 1;
    m.port.name = MACH_PORT_NULL;
    m.port.disposition = MACH_MSG_TYPE_COPY_SEND;
    m.port.type = MACH_MSG_PORT_DESCRIPTOR;
    m.kind = kind;
    m.pid = getpid();
    m.value = value;
    Received in = {0};
    kr = mach_msg(&m.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, timeoutMs, MACH_PORT_NULL);
    if (kr == MACH_MSG_SUCCESS)
        kr = mach_msg(&in.m.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof in, replyPort, timeoutMs, MACH_PORT_NULL);
    mach_port_mod_refs(mach_task_self(), replyPort, MACH_PORT_RIGHT_RECEIVE, -1);
    if (kr != MACH_MSG_SUCCESS) return kr;
    if (!(in.m.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) || in.m.header.msgh_size < sizeof(ShackPlayMessage)) {
        mach_msg_destroy(&in.m.header);
        return KERN_FAILURE;
    }
    *reply = in.m;
    return KERN_SUCCESS;
}

kern_return_t ShackPlayConnect(const char *name, mach_port_t *session) {
    mach_port_t bp = MACH_PORT_NULL, service = MACH_PORT_NULL;
    task_get_bootstrap_port(mach_task_self(), &bp);
    kern_return_t kr = bootstrap_look_up(bp, name, &service);
    if (kr != KERN_SUCCESS) return kr;
    ShackPlayMessage reply;
    kr = ShackPlayCall(service, ShackPlayHello, 0, 5000, &reply);
    mach_port_deallocate(mach_task_self(), service);
    if (kr != KERN_SUCCESS) return kr;
    if (!MACH_PORT_VALID(reply.port.name)) return KERN_INVALID_RIGHT;
    *session = reply.port.name;
    return KERN_SUCCESS;
}
