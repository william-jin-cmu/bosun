// Keyboard module declarations: the HID event system client, used to read the
// current UserKeyMapping (hidutil's own --get output is not machine-readable).
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
