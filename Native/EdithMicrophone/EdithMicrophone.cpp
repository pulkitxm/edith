#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>
#include <limits>

#ifndef EDITH_MICROPHONE_UID
#define EDITH_MICROPHONE_UID "com.pulkit.edith.microphone"
#endif
#ifndef EDITH_MICROPHONE_NAME
#define EDITH_MICROPHONE_NAME "Edith Microphone"
#endif

namespace {
constexpr AudioObjectID device = 2, inputStream = 3, outputStream = 4;
constexpr UInt32 channels = 2, period = 512, delayFrames = 4096, capacity = 32768;
constexpr Float64 sampleRate = 48000;
static_assert(std::atomic<UInt64>::is_always_lock_free);
constexpr UInt64 empty = std::numeric_limits<UInt64>::max();
struct Frame {
    std::atomic<UInt64> time{empty};
    std::atomic<UInt64> samples{0};
};
std::array<Frame, capacity> ring;
std::atomic<UInt32> references{1}, clients{0}, bufferFrames{512};
std::atomic<UInt64> anchor{0}, seed{1};
std::mutex lifecycle;
Float64 ticksPerFrame = 0;
AudioServerPlugInHostRef host = nullptr;
extern AudioServerPlugInDriverInterface interface;
AudioServerPlugInDriverInterface *interfacePointer = &interface;
AudioServerPlugInDriverRef driver = &interfacePointer;

AudioStreamBasicDescription format() {
    return {sampleRate, kAudioFormatLinearPCM,
            kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            channels * sizeof(Float32), 1, channels * sizeof(Float32), channels, 32, 0};
}
bool validObject(AudioObjectID object) {
    return object == kAudioObjectPlugInObject || object == device || object == inputStream || object == outputStream;
}
bool streamObject(AudioObjectID object) { return object == inputStream || object == outputStream; }
UInt32 streamCount(AudioObjectPropertyScope scope) {
    return scope == kAudioObjectPropertyScopeGlobal ? 2 : 1;
}
UInt32 propertySize(AudioObjectID object, const AudioObjectPropertyAddress &address) {
    if (!validObject(object) || address.mElement != kAudioObjectPropertyElementMain) return 0;
    switch (address.mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner: return sizeof(UInt32);
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer: return sizeof(CFStringRef);
        case kAudioObjectPropertyOwnedObjects:
            return object == device ? streamCount(address.mScope) * sizeof(AudioObjectID) :
                   object == kAudioObjectPlugInObject ? sizeof(AudioObjectID) : 0;
    }
    if (object == kAudioObjectPlugInObject) {
        switch (address.mSelector) {
            case kAudioPlugInPropertyBundleID:
            case kAudioPlugInPropertyResourceBundle: return sizeof(CFStringRef);
            case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice: return sizeof(AudioObjectID);
            default: return 0;
        }
    }
    if (streamObject(object)) {
        switch (address.mSelector) {
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency: return sizeof(UInt32);
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: return sizeof(AudioStreamBasicDescription);
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: return sizeof(AudioStreamRangedDescription);
            default: return 0;
        }
    }
    switch (address.mSelector) {
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID: return sizeof(CFStringRef);
        case kAudioDevicePropertyRelatedDevices: return sizeof(AudioObjectID);
        case kAudioDevicePropertyStreams: return streamCount(address.mScope) * sizeof(AudioObjectID);
        case kAudioDevicePropertyStreamConfiguration: return sizeof(AudioBufferList);
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyBufferFrameSize:
        case kAudioDevicePropertyUsesVariableBufferFrameSizes:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyIsHidden: return sizeof(UInt32);
        case kAudioDevicePropertyNominalSampleRate: return sizeof(Float64);
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyBufferFrameSizeRange: return sizeof(AudioValueRange);
        case kAudioDevicePropertyPreferredChannelsForStereo: return 2 * sizeof(UInt32);
        default: return 0;
    }
}
Boolean hasProperty(AudioServerPlugInDriverRef, AudioObjectID object, pid_t, const AudioObjectPropertyAddress *address) {
    if (!address || !validObject(object)) return false;
    if (address->mSelector == kAudioObjectPropertyOwnedObjects) return true;
    if (object == kAudioObjectPlugInObject && (address->mSelector == kAudioPlugInPropertyBoxList ||
        address->mSelector == kAudioPlugInPropertyClockDeviceList)) return true;
    if (object == device && address->mSelector == kAudioObjectPropertyControlList) return true;
    return propertySize(object, *address) > 0;
}
OSStatus isSettable(AudioServerPlugInDriverRef ref, AudioObjectID object, pid_t pid,
                    const AudioObjectPropertyAddress *address, Boolean *settable) {
    if (!settable || !hasProperty(ref, object, pid, address)) return kAudioHardwareUnknownPropertyError;
    *settable = (object == device && (address->mSelector == kAudioDevicePropertyNominalSampleRate ||
         address->mSelector == kAudioDevicePropertyBufferFrameSize)) ||
         (streamObject(object) && (address->mSelector == kAudioStreamPropertyVirtualFormat ||
          address->mSelector == kAudioStreamPropertyPhysicalFormat || address->mSelector == kAudioStreamPropertyIsActive));
    return noErr;
}
OSStatus getSize(AudioServerPlugInDriverRef ref, AudioObjectID object, pid_t pid,
                 const AudioObjectPropertyAddress *address, UInt32, const void *, UInt32 *size) {
    if (!size || !hasProperty(ref, object, pid, address)) return kAudioHardwareUnknownPropertyError;
    *size = propertySize(object, *address);
    return noErr;
}
template <typename T> OSStatus copy(const T &value, UInt32 available, UInt32 *size, void *data) {
    if (!size || !data || available < sizeof(T)) return kAudioHardwareBadPropertySizeError;
    std::memcpy(data, &value, sizeof(T)); *size = sizeof(T); return noErr;
}
OSStatus getData(AudioServerPlugInDriverRef ref, AudioObjectID object, pid_t pid,
                 const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier,
                 UInt32 available, UInt32 *size, void *data) {
    if (!size || !hasProperty(ref, object, pid, address)) return kAudioHardwareUnknownPropertyError;
    UInt32 required = propertySize(object, *address);
    if (available < required || (required && !data)) return kAudioHardwareBadPropertySizeError;
    *size = required;
    auto integer = [&](UInt32 value) { return copy(value, available, size, data); };
    auto string = [&](CFStringRef value) { return copy(value, available, size, data); };
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: return integer(kAudioObjectClassID);
        case kAudioObjectPropertyClass: return integer(object == device ? kAudioDeviceClassID :
            streamObject(object) ? kAudioStreamClassID : kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: return integer(object == device ? kAudioObjectPlugInObject :
            streamObject(object) ? device : kAudioObjectUnknown);
        case kAudioObjectPropertyName: return string(CFSTR(EDITH_MICROPHONE_NAME));
        case kAudioObjectPropertyManufacturer: return string(CFSTR("Edith"));
        case kAudioPlugInPropertyBundleID:
        case kAudioDevicePropertyDeviceUID: return string(CFSTR(EDITH_MICROPHONE_UID));
        case kAudioDevicePropertyModelUID: return string(CFSTR("com.pulkit.edith.microphone.model"));
        case kAudioPlugInPropertyTranslateUIDToDevice:
            return integer(qualifierSize == sizeof(CFStringRef) && qualifier && *static_cast<const CFStringRef *>(qualifier) &&
                CFEqual(*static_cast<const CFStringRef *>(qualifier), CFSTR(EDITH_MICROPHONE_UID)) ? device : kAudioObjectUnknown);
        case kAudioPlugInPropertyDeviceList:
        case kAudioDevicePropertyRelatedDevices: return integer(device);
        case kAudioPlugInPropertyResourceBundle: return string(CFSTR(""));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            if (!required) return noErr;
            if (object == kAudioObjectPlugInObject) return integer(device);
            AudioObjectID ids[] = {inputStream, outputStream};
            const AudioObjectID *first = address->mScope == kAudioObjectPropertyScopeOutput ? ids + 1 : ids;
            std::memcpy(data, first, required); return noErr;
        }
        case kAudioDevicePropertyStreamConfiguration: {
            AudioBufferList value{1, {{channels, 0, nullptr}}}; return copy(value, available, size, data);
        }
        case kAudioDevicePropertyTransportType: return integer(kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyUsesVariableBufferFrameSizes:
        case kAudioDevicePropertyIsHidden:
            return integer(0);
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyStartingChannel: return integer(1);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            return integer(address->mScope == kAudioObjectPropertyScopeInput ? 1 : 0);
        case kAudioDevicePropertyDeviceIsRunning: return integer(clients.load() > 0);
        case kAudioDevicePropertyLatency: return integer(object == device && address->mScope == kAudioObjectPropertyScopeInput ? delayFrames : 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: return integer(period);
        case kAudioDevicePropertyBufferFrameSize: return integer(bufferFrames.load());
        case kAudioDevicePropertyBufferFrameSizeRange: return copy(AudioValueRange{128, 4096}, available, size, data);
        case kAudioDevicePropertyNominalSampleRate: return copy(sampleRate, available, size, data);
        case kAudioDevicePropertyAvailableNominalSampleRates: return copy(AudioValueRange{sampleRate, sampleRate}, available, size, data);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32 value[] = {1, 2}; std::memcpy(data, value, sizeof(value)); return noErr;
        }
        case kAudioStreamPropertyDirection: return integer(object == inputStream ? 1 : 0);
        case kAudioStreamPropertyTerminalType: return integer(object == inputStream ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: return copy(format(), available, size, data);
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription value{format(), {sampleRate, sampleRate}}; return copy(value, available, size, data);
        }
        default: return noErr;
    }
}
OSStatus setData(AudioServerPlugInDriverRef ref, AudioObjectID object, pid_t pid,
                 const AudioObjectPropertyAddress *address, UInt32, const void *, UInt32 size, const void *data) {
    Boolean settable = false;
    OSStatus status = isSettable(ref, object, pid, address, &settable);
    if (status) return status;
    if (!settable || !data) return kAudioHardwareIllegalOperationError;
    if (size != propertySize(object, *address)) return kAudioHardwareBadPropertySizeError;
    if (address->mSelector == kAudioDevicePropertyBufferFrameSize) {
        UInt32 value = *static_cast<const UInt32 *>(data);
        if (value < 128 || value > 4096) return kAudioHardwareIllegalOperationError;
        bufferFrames.store(value);
    } else if (address->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (*static_cast<const Float64 *>(data) != sampleRate) return kAudioHardwareIllegalOperationError;
    } else if (address->mSelector == kAudioStreamPropertyIsActive) {
        if (*static_cast<const UInt32 *>(data) != 1) return kAudioHardwareIllegalOperationError;
    } else {
        const auto &value = *static_cast<const AudioStreamBasicDescription *>(data);
        auto expected = format();
        if (value.mSampleRate != sampleRate || value.mFormatID != expected.mFormatID ||
            value.mFormatFlags != expected.mFormatFlags || value.mBytesPerPacket != expected.mBytesPerPacket ||
            value.mFramesPerPacket != 1 || value.mBytesPerFrame != expected.mBytesPerFrame ||
            value.mChannelsPerFrame != channels || value.mBitsPerChannel != 32) return kAudioDeviceUnsupportedFormatError;
    }
    if (host) host->PropertiesChanged(host, object, 1, address);
    return noErr;
}
HRESULT query(void *, REFIID uuid, LPVOID *result) {
    if (!result) return E_POINTER;
    CFUUIDRef id = CFUUIDCreateFromUUIDBytes(nullptr, uuid);
    bool supported = CFEqual(id, IUnknownUUID) || CFEqual(id, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(id); *result = supported ? driver : nullptr;
    if (supported) { references.fetch_add(1); return S_OK; }
    return E_NOINTERFACE;
}
ULONG addRef(void *) { return references.fetch_add(1) + 1; }
ULONG release(void *) {
    UInt32 count = references.load();
    while (count > 0 && !references.compare_exchange_weak(count, count - 1)) {}
    return count > 0 ? count - 1 : 0;
}
OSStatus initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef value) {
    host = value; mach_timebase_info_data_t timebase{}; mach_timebase_info(&timebase);
    ticksPerFrame = (1e9 / sampleRate) * timebase.denom / timebase.numer;
    anchor.store(mach_absolute_time()); return noErr;
}
OSStatus createDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *, AudioObjectID *) { return kAudioHardwareUnsupportedOperationError; }
OSStatus destroyDevice(AudioServerPlugInDriverRef, AudioObjectID) { return kAudioHardwareUnsupportedOperationError; }
OSStatus deviceClient(AudioServerPlugInDriverRef, AudioObjectID object, const AudioServerPlugInClientInfo *) { return object == device ? noErr : kAudioHardwareBadObjectError; }
OSStatus configuration(AudioServerPlugInDriverRef, AudioObjectID object, UInt64, void *) { return object == device ? noErr : kAudioHardwareBadObjectError; }
OSStatus start(AudioServerPlugInDriverRef, AudioObjectID object, UInt32) {
    if (object != device) return kAudioHardwareBadObjectError;
    std::lock_guard<std::mutex> lock(lifecycle);
    if (clients.fetch_add(1) == 0) {
        for (auto &frame : ring) frame.time.store(empty);
        anchor.store(mach_absolute_time()); seed.fetch_add(1);
    }
    return noErr;
}
OSStatus stop(AudioServerPlugInDriverRef, AudioObjectID object, UInt32) {
    if (object != device) return kAudioHardwareBadObjectError;
    std::lock_guard<std::mutex> lock(lifecycle);
    if (clients.load() > 0) clients.fetch_sub(1);
    return noErr;
}
OSStatus timestamp(AudioServerPlugInDriverRef, AudioObjectID object, UInt32, Float64 *sample, UInt64 *time, UInt64 *value) {
    if (object != device) return kAudioHardwareBadObjectError;
    if (!sample || !time || !value || ticksPerFrame == 0) return kAudioHardwareIllegalOperationError;
    UInt64 origin = anchor.load();
    UInt64 now = mach_absolute_time();
    UInt64 periods = static_cast<UInt64>(static_cast<Float64>(now - origin) / (ticksPerFrame * period));
    *sample = static_cast<Float64>(periods * period);
    *time = origin + static_cast<UInt64>(*sample * ticksPerFrame); *value = seed.load(); return noErr;
}
OSStatus willDo(AudioServerPlugInDriverRef, AudioObjectID object, UInt32, UInt32 operation, Boolean *will, Boolean *inPlace) {
    if (object != device) return kAudioHardwareBadObjectError;
    if (will) *will = operation == kAudioServerPlugInIOOperationReadInput || operation == kAudioServerPlugInIOOperationWriteMix;
    if (inPlace) *inPlace = true; return noErr;
}
OSStatus boundary(AudioServerPlugInDriverRef, AudioObjectID object, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *) { return object == device ? noErr : kAudioHardwareBadObjectError; }
OSStatus performIO(AudioServerPlugInDriverRef, AudioObjectID object, AudioObjectID stream, UInt32, UInt32 operation,
                   UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *buffer, void *) {
    if (object != device || !streamObject(stream)) return kAudioHardwareBadObjectError;
    if (!cycle || !buffer || frames > capacity) return kAudioHardwareIllegalOperationError;
    bool writing = operation == kAudioServerPlugInIOOperationWriteMix && stream == outputStream;
    bool reading = operation == kAudioServerPlugInIOOperationReadInput && stream == inputStream;
    if (!writing && !reading) return kAudioHardwareUnsupportedOperationError;
    Float64 sample = writing ? cycle->mOutputTime.mSampleTime : cycle->mInputTime.mSampleTime - delayFrames;
    if (!std::isfinite(sample) || sample < 0) {
        if (reading) std::memset(buffer, 0, frames * channels * sizeof(Float32));
        return noErr;
    }
    auto *values = static_cast<Float32 *>(buffer);
    UInt64 first = static_cast<UInt64>(sample);
    for (UInt32 i = 0; i < frames; ++i) {
        UInt64 time = first + i; auto &frame = ring[time % capacity];
        if (writing) {
            UInt64 bits = 0; Float32 pair[] = {values[2 * i], values[2 * i + 1]};
            for (auto &value : pair) value = std::isfinite(value) ? std::fmax(-1, std::fmin(1, value)) : 0;
            std::memcpy(&bits, pair, sizeof(bits));
            frame.time.store(empty, std::memory_order_release);
            frame.samples.store(bits, std::memory_order_relaxed);
            frame.time.store(time, std::memory_order_release);
        } else {
            UInt64 before = frame.time.load(std::memory_order_acquire);
            UInt64 bits = frame.samples.load(std::memory_order_relaxed);
            if (before != time || frame.time.load(std::memory_order_acquire) != time) bits = 0;
            std::memcpy(values + 2 * i, &bits, sizeof(bits));
        }
    }
    return noErr;
}
AudioServerPlugInDriverInterface interface = {nullptr, query, addRef, release, initialize,
    createDevice, destroyDevice, deviceClient, deviceClient, configuration, configuration,
    hasProperty, isSettable, getSize, getData, setData, start, stop, timestamp, willDo,
    boundary, performIO, boundary};
}
extern "C" __attribute__((visibility("default"))) void *EdithMicrophoneFactory(CFAllocatorRef, CFUUIDRef requestedType) {
    return requestedType && CFEqual(requestedType, kAudioServerPlugInTypeUUID) ? driver : nullptr;
}
