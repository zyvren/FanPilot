#include "smc.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

// ---------------------------------------------------------------------------
// AppleSMC user client
// ---------------------------------------------------------------------------

static _Atomic uint64_t g_read_calls;
static _Atomic uint64_t g_write_calls;

kern_return_t fp_smc_open(fp_smc_conn_t *out_conn) {
    if (!out_conn) return kIOReturnBadArgument;
    *out_conn = 0;

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) return kIOReturnNotFound;

    io_connect_t conn = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) return kr;

    *out_conn = (fp_smc_conn_t)conn;
    return KERN_SUCCESS;
}

void fp_smc_close(fp_smc_conn_t conn) {
    if (conn != 0) IOServiceClose((io_connect_t)conn);
}

// Single choke point to the kernel. Always sends exactly sizeof(SMCKeyData_t) and insists on the
// same size coming back, otherwise the struct cannot be trusted.
static kern_return_t fp_smc_raw_call(fp_smc_conn_t conn, const SMCKeyData_t *in, SMCKeyData_t *out) {
    if (conn == 0 || !in || !out) return kIOReturnBadArgument;
    size_t out_size = sizeof(SMCKeyData_t);
    kern_return_t kr = IOConnectCallStructMethod((io_connect_t)conn, FP_SMC_SELECTOR,
                                                 in, sizeof(SMCKeyData_t), out, &out_size);
    if (kr == KERN_SUCCESS && out_size != sizeof(SMCKeyData_t)) return kIOReturnUnderrun;
    return kr;
}

kern_return_t fp_smc_call_read(fp_smc_conn_t conn, const SMCKeyData_t *in, SMCKeyData_t *out) {
    if (!in || !out) return kIOReturnBadArgument;
    switch (in->data8) {
    case FP_SMC_CMD_READ:
    case FP_SMC_CMD_READ_INDEX:
    case FP_SMC_CMD_KEY_INFO:
        break;
    default:
        return kIOReturnNotPermitted;   // includes FP_SMC_CMD_WRITE: never leaves the process here
    }
    atomic_fetch_add(&g_read_calls, 1);
    return fp_smc_raw_call(conn, in, out);
}

kern_return_t fp_smc_call_write(fp_smc_conn_t conn, const SMCKeyData_t *in, SMCKeyData_t *out) {
    if (!in || !out) return kIOReturnBadArgument;
    if (in->data8 != FP_SMC_CMD_WRITE) return kIOReturnNotPermitted;
    atomic_fetch_add(&g_write_calls, 1);
    return fp_smc_raw_call(conn, in, out);
}

uint64_t fp_smc_stat_reads(void)  { return atomic_load(&g_read_calls); }
uint64_t fp_smc_stat_writes(void) { return atomic_load(&g_write_calls); }

void fp_smc_set_bytes(SMCKeyData_t *data, const uint8_t *src, size_t n) {
    if (!data) return;
    if (n > FP_SMC_PAYLOAD_MAX) n = FP_SMC_PAYLOAD_MAX;
    memset(data->bytes, 0, sizeof data->bytes);
    if (src && n) memcpy(data->bytes, src, n);
}

void fp_smc_get_bytes(const SMCKeyData_t *data, uint8_t *dst, size_t n) {
    if (!data || !dst) return;
    if (n > FP_SMC_PAYLOAD_MAX) n = FP_SMC_PAYLOAD_MAX;
    memcpy(dst, data->bytes, n);
}

// ---------------------------------------------------------------------------
// IOHID private temperature API
// ---------------------------------------------------------------------------

typedef CFTypeRef HIDClientRef;         // IOHIDEventSystemClientRef
typedef CFTypeRef HIDServiceRef;        // IOHIDServiceClientRef
typedef CFTypeRef HIDEventRef;          // IOHIDEventRef

typedef HIDClientRef (*fn_client_create)(CFAllocatorRef);
typedef int          (*fn_set_matching)(HIDClientRef, CFDictionaryRef);
typedef CFArrayRef   (*fn_copy_services)(HIDClientRef);
typedef CFTypeRef    (*fn_copy_property)(HIDServiceRef, CFStringRef);
typedef HIDEventRef  (*fn_copy_event)(HIDServiceRef, int64_t, int32_t, int64_t);
typedef double       (*fn_get_float)(HIDEventRef, int32_t);

static struct {
    fn_client_create client_create;
    fn_set_matching  set_matching;
    fn_copy_services copy_services;
    fn_copy_property copy_property;
    fn_copy_event    copy_event;
    fn_get_float     get_float;
    int              resolved;          // 1 = all symbols present
} g_hid;

static pthread_once_t g_hid_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_hid_lock = PTHREAD_MUTEX_INITIALIZER;
static HIDClientRef g_hid_client;       // guarded by g_hid_lock

#define FP_HID_EVENT_TEMPERATURE 15     // kIOHIDEventTypeTemperature
#define FP_HID_FIELD_TEMPERATURE_LEVEL (FP_HID_EVENT_TEMPERATURE << 16)

static void fp_hid_resolve(void) {
    // IOKit is linked into every FanPilot binary, but dlopen keeps this independent of link order.
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_NOLOAD);
    if (!h) h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!h) h = RTLD_DEFAULT;

    g_hid.client_create = (fn_client_create)dlsym(h, "IOHIDEventSystemClientCreate");
    g_hid.set_matching  = (fn_set_matching)dlsym(h, "IOHIDEventSystemClientSetMatching");
    g_hid.copy_services = (fn_copy_services)dlsym(h, "IOHIDEventSystemClientCopyServices");
    g_hid.copy_property = (fn_copy_property)dlsym(h, "IOHIDServiceClientCopyProperty");
    g_hid.copy_event    = (fn_copy_event)dlsym(h, "IOHIDServiceClientCopyEvent");
    g_hid.get_float     = (fn_get_float)dlsym(h, "IOHIDEventGetFloatValue");

    g_hid.resolved = g_hid.client_create && g_hid.set_matching && g_hid.copy_services &&
                     g_hid.copy_property && g_hid.copy_event && g_hid.get_float;
}

int fp_hid_available(void) {
    pthread_once(&g_hid_once, fp_hid_resolve);
    return g_hid.resolved;
}

static void fp_cfstring_to_utf8(CFTypeRef v, char *buf, size_t size) {
    buf[0] = 0;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
        if (!CFStringGetCString((CFStringRef)v, buf, (CFIndex)size, kCFStringEncodingUTF8)) buf[0] = 0;
    }
}

static HIDClientRef fp_hid_make_client(void) {
    HIDClientRef client = g_hid.client_create(kCFAllocatorDefault);
    if (!client) return NULL;

    int page = 0xff00, usage = 5;       // vendor page / temperature sensors
    CFNumberRef page_n = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef usage_n = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[2] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[2] = { page_n, usage_n };
    CFDictionaryRef match = (page_n && usage_n)
        ? CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
        : NULL;
    if (page_n) CFRelease(page_n);
    if (usage_n) CFRelease(usage_n);
    if (!match) {
        CFRelease(client);
        return NULL;
    }
    g_hid.set_matching(client, match);
    CFRelease(match);
    return client;
}

int fp_hid_read_temperatures(fp_hid_temp_t *out, size_t capacity, size_t *total) {
    if (total) *total = 0;
    if (!fp_hid_available()) return FP_HID_ERR_UNAVAILABLE;

    pthread_mutex_lock(&g_hid_lock);
    if (!g_hid_client) g_hid_client = fp_hid_make_client();
    HIDClientRef client = g_hid_client;
    if (!client) {
        pthread_mutex_unlock(&g_hid_lock);
        return FP_HID_ERR_CLIENT;
    }

    CFArrayRef services = g_hid.copy_services(client);
    CFIndex count = services ? CFArrayGetCount(services) : 0;
    if (total) *total = (size_t)count;

    size_t written = 0;
    for (CFIndex i = 0; i < count && written < capacity; i++) {
        HIDServiceRef svc = (HIDServiceRef)CFArrayGetValueAtIndex(services, i);
        fp_hid_temp_t *e = &out[written];
        memset(e, 0, sizeof *e);
        e->location_id = -1;

        CFTypeRef product = g_hid.copy_property(svc, CFSTR("Product"));
        fp_cfstring_to_utf8(product, e->product, sizeof e->product);
        if (product) CFRelease(product);

        CFTypeRef loc = g_hid.copy_property(svc, CFSTR("LocationID"));
        if (loc && CFGetTypeID(loc) == CFNumberGetTypeID()) {
            int64_t v = 0;
            if (CFNumberGetValue((CFNumberRef)loc, kCFNumberSInt64Type, &v)) e->location_id = v;
        }
        if (loc) CFRelease(loc);

        HIDEventRef ev = g_hid.copy_event(svc, FP_HID_EVENT_TEMPERATURE, 0, 0);
        if (ev) {
            e->value = g_hid.get_float(ev, FP_HID_FIELD_TEMPERATURE_LEVEL);
            e->has_value = 1;
            CFRelease(ev);
        }
        written++;
    }
    if (services) CFRelease(services);
    pthread_mutex_unlock(&g_hid_lock);
    return (int)written;
}

void fp_hid_shutdown(void) {
    pthread_mutex_lock(&g_hid_lock);
    if (g_hid_client) {
        CFRelease(g_hid_client);
        g_hid_client = NULL;
    }
    pthread_mutex_unlock(&g_hid_lock);
}
