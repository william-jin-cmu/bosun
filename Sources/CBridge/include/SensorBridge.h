// Sensor module private declarations.
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

// MARK: - AppleSMC user client
//
// Layout of the struct exchanged with the AppleSMC user client through
// IOConnectCallStructMethod(conn, kBosunSMCHandleYPCEvent, ...). 80 bytes; the
// field order and padding match the long-standing SMCParamStruct used by
// smcFanControl / Stats (SMC/smc.swift, SMCKeyData_t).

typedef struct {
    uint8_t  major;
    uint8_t  minor;
    uint8_t  build;
    uint8_t  reserved;
    uint16_t release;
} BosunSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} BosunSMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;       // four-char code, e.g. 'flt ', 'ui8 ', 'sp78'
    uint8_t  dataAttributes;
} BosunSMCKeyInfo;

typedef struct {
    uint32_t           key;  // four-char code, e.g. 'F0Ac'
    BosunSMCVersion    vers;
    BosunSMCPLimitData pLimitData;
    BosunSMCKeyInfo    keyInfo;
    uint8_t            result;   // SMC-level status: 0 = ok, 0x84 = key not found
    uint8_t            status;
    uint8_t            data8;    // command, see BosunSMCCommand
    uint32_t           data32;
    uint8_t            bytes[32];
} BosunSMCParamStruct;

_Static_assert(sizeof(BosunSMCParamStruct) == 80, "SMCParamStruct must be 80 bytes");

enum {
    kBosunSMCHandleYPCEvent = 2,   // IOConnectCallStructMethod selector
};

enum {
    kBosunSMCReadBytes   = 5,
    kBosunSMCReadKeyInfo = 9,
};

enum {
    kBosunSMCResultSuccess     = 0x00,
    kBosunSMCResultKeyNotFound = 0x84,
};

// MARK: - IOHIDEventSystem thermal sensors (private IOKit symbols)

typedef struct __IOHIDEvent *IOHIDEventRef;

#define kBosunHIDPageAppleVendor              0xff00
#define kBosunHIDUsageAppleVendorTemperature  0x0005
#define kBosunHIDEventTypeTemperature         15
// Field selector for the temperature value: (event type << 16).
#define kBosunHIDEventFieldTemperatureLevel   (kBosunHIDEventTypeTemperature << 16)

CF_RETURNS_RETAINED IOHIDEventSystemClientRef _Nullable
IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator);

int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef _Nonnull client,
                                      CFDictionaryRef _Nonnull match);

CF_RETURNS_RETAINED IOHIDEventRef _Nullable
IOHIDServiceClientCopyEvent(IOHIDServiceClientRef _Nonnull service,
                            int64_t type, int32_t options, int64_t timestamp);

double IOHIDEventGetFloatValue(IOHIDEventRef _Nonnull event, int32_t field);
