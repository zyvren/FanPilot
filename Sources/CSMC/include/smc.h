// smc.h - C layer of FanPilot.
//
// Two jobs:
//   1. Layout guarantees and raw access for the AppleSMC user client (selector 2, 80-byte struct).
//   2. Safe access to the private IOHID temperature API, resolved with dlsym so a missing symbol
//      degrades to "no HID sensors" instead of a launch failure.
//
// Swift code (FanPilotKit) wraps everything here; nothing else should talk to the SMC directly.

#ifndef FANPILOT_SMC_H
#define FANPILOT_SMC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <mach/kern_return.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// SMC struct (docs/SPEC.md 2.1)
// ---------------------------------------------------------------------------

typedef struct {
    char     major;
    char     minor;
    char     build;
    char     reserved;
    uint16_t release;
} SMCVersion_t;                         // 6 bytes

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData_t;                      // 16 bytes

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;                  // big-endian packed four character code
    uint8_t  dataAttributes;            // 0x80 readable, 0x40 writable (observed on an M5 Pro MacBook Pro)
} SMCKeyInfoData_t;                     // 12 bytes with padding

typedef struct {
    uint32_t         key;               // big-endian packed four character code
    SMCVersion_t     vers;
    SMCPLimitData_t  pLimitData;
    SMCKeyInfoData_t keyInfo;
    uint8_t          result;            // 0 = ok, else an SMC error code (0x84 = key not found)
    uint8_t          status;
    uint8_t          data8;             // command
    uint32_t         data32;            // key index for FP_SMC_CMD_READ_INDEX
    uint8_t          bytes[32];         // payload
} SMCKeyData_t;                         // 80 bytes

// The kernel interface is positional. If any of these ever fails the build must stop: a shifted
// field would silently turn a read into a different command or a write into a wrong key.
_Static_assert(sizeof(SMCKeyData_t) == 80, "SMCKeyData_t must be 80 bytes");
_Static_assert(offsetof(SMCKeyData_t, key) == 0, "key offset");
_Static_assert(offsetof(SMCKeyData_t, vers) == 4, "vers offset");
_Static_assert(offsetof(SMCKeyData_t, pLimitData) == 12, "pLimitData offset");
_Static_assert(offsetof(SMCKeyData_t, keyInfo) == 28, "keyInfo offset");
_Static_assert(offsetof(SMCKeyData_t, keyInfo.dataSize) == 28, "keyInfo.dataSize offset");
_Static_assert(offsetof(SMCKeyData_t, keyInfo.dataType) == 32, "keyInfo.dataType offset");
_Static_assert(offsetof(SMCKeyData_t, keyInfo.dataAttributes) == 36, "keyInfo.dataAttributes offset");
_Static_assert(offsetof(SMCKeyData_t, result) == 40, "result offset");
_Static_assert(offsetof(SMCKeyData_t, status) == 41, "status offset");
_Static_assert(offsetof(SMCKeyData_t, data8) == 42, "data8 offset");
_Static_assert(offsetof(SMCKeyData_t, data32) == 44, "data32 offset");
_Static_assert(offsetof(SMCKeyData_t, bytes) == 48, "bytes offset");

#define FP_SMC_SELECTOR        2    // IOConnectCallStructMethod selector of the AppleSMC user client
#define FP_SMC_PAYLOAD_MAX     32   // sizeof(SMCKeyData_t.bytes)

#define FP_SMC_CMD_READ        5
#define FP_SMC_CMD_WRITE       6
#define FP_SMC_CMD_READ_INDEX  8
#define FP_SMC_CMD_KEY_INFO    9

#define FP_SMC_RESULT_OK         0x00
#define FP_SMC_RESULT_NOT_FOUND  0x84

// A connection is an io_connect_t (a mach port name, 32 bits). 0 means "not open".
typedef uint32_t fp_smc_conn_t;

// Opens the AppleSMC user client. Returns KERN_SUCCESS or an IOReturn error.
kern_return_t fp_smc_open(fp_smc_conn_t *out_conn);
void          fp_smc_close(fp_smc_conn_t conn);

// Issue one SMC command. These are the ONLY functions in the code base that reach
// IOConnectCallStructMethod.
//
// fp_smc_call_read   accepts commands 5 (read), 8 (key by index) and 9 (key info). Any other
//                    command, in particular 6 (write), is refused with kIOReturnNotPermitted
//                    before it reaches the kernel.
// fp_smc_call_write  accepts command 6 only.
//
// Callers must check the IOReturn AND out->result.
kern_return_t fp_smc_call_read(fp_smc_conn_t conn, const SMCKeyData_t *in, SMCKeyData_t *out);
kern_return_t fp_smc_call_write(fp_smc_conn_t conn, const SMCKeyData_t *in, SMCKeyData_t *out);

// Process-wide counters of calls that reached the kernel (tests assert writes == 0 on live runs).
uint64_t fp_smc_stat_reads(void);
uint64_t fp_smc_stat_writes(void);

// Payload accessors so Swift does not have to juggle the 32-tuple. n is clamped to 32.
void fp_smc_set_bytes(SMCKeyData_t *data, const uint8_t *src, size_t n);
void fp_smc_get_bytes(const SMCKeyData_t *data, uint8_t *dst, size_t n);

// ---------------------------------------------------------------------------
// IOHID temperature sensors (private API, docs/SPEC.md 3.1)
// ---------------------------------------------------------------------------

#define FP_HID_NAME_MAX 128

typedef struct {
    char    product[FP_HID_NAME_MAX];   // "Product" property, UTF-8, "" if missing
    int64_t location_id;                // "LocationID" property, -1 if missing
    double  value;                      // degrees Celsius, only meaningful if has_value
    int32_t has_value;                  // 1 if the service delivered a temperature event
} fp_hid_temp_t;

#define FP_HID_OK                 0
#define FP_HID_ERR_UNAVAILABLE  (-1)    // private symbols could not be resolved
#define FP_HID_ERR_CLIENT       (-2)    // IOHIDEventSystemClientCreate failed
#define FP_HID_ERR_MATCHING     (-3)    // could not build the matching dictionary

// 1 if every private symbol resolved on this system.
int fp_hid_available(void);

// Reads every temperature service matching {PrimaryUsagePage 0xff00, PrimaryUsage 5}.
// Fills up to `capacity` entries of `out` and stores the number of services found in *total
// (may exceed capacity). Returns the number of entries written (>= 0) or a negative FP_HID_ERR_*.
// Duplicate services are NOT merged here; callers dedupe (SPEC 3.1).
int fp_hid_read_temperatures(fp_hid_temp_t *out, size_t capacity, size_t *total);

// Drops the cached HID client (call after wake if readings go stale). Safe to call at any time.
void fp_hid_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif // FANPILOT_SMC_H
