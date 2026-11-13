// Keyboard module declarations: the HID event system client (reads the
// current UserKeyMapping, per keyboard) and the HID system parameters
// (Caps Lock state).
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDParameter.h>
