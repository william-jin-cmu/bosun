// Display module private declarations.
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

// IOAVService: Apple Silicon display transport (lives in IOKit, no header).
// Used for DDC/CI over the display's I2C channel.
typedef CFTypeRef IOAVServiceRef;

extern IOAVServiceRef _Nullable IOAVServiceCreateWithService(CFAllocatorRef _Nullable allocator,
                                                             io_service_t service) CF_RETURNS_RETAINED;
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef _Nonnull service, uint32_t chipAddress,
                                   uint32_t offset, void *_Nonnull outputBuffer,
                                   uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef _Nonnull service, uint32_t chipAddress,
                                    uint32_t dataAddress, void *_Nonnull inputBuffer,
                                    uint32_t inputBufferSize);
