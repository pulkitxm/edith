#include "EdithMicrophone.cpp"
#include <cassert>
#include <cstdio>
#include <thread>
#include <vector>

int main() {
    assert(EdithMicrophoneFactory(nullptr, kAudioServerPlugInTypeUUID) == driver);
    AudioServerPlugInHostInterface testHost{};
    assert(interface.Initialize(driver, &testHost) == noErr);
    AudioObjectPropertyAddress address{kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, 0};
    AudioObjectID id = 0; UInt32 size = 0;
    assert(interface.GetPropertyData(driver, 1, 0, &address, 0, nullptr, sizeof(id), &size, &id) == noErr);
    assert(id == device && size == sizeof(id));
    address.mSelector = kAudioDevicePropertyStreams;
    AudioObjectID streams[2]{};
    assert(interface.GetPropertyData(driver, device, 0, &address, 0, nullptr, sizeof(streams), &size, streams) == noErr);
    assert(streams[0] == inputStream && streams[1] == outputStream);
    address.mSelector = kAudioStreamPropertyAvailablePhysicalFormats;
    AudioStreamRangedDescription description{};
    assert(interface.GetPropertyData(driver, inputStream, 0, &address, 0, nullptr, sizeof(description), &size, &description) == noErr);
    assert(description.mFormat.mSampleRate == 48000 && description.mFormat.mChannelsPerFrame == 2);
    assert(interface.GetPropertyData(driver, inputStream, 0, &address, 0, nullptr, 1, &size, &description) == kAudioHardwareBadPropertySizeError);
    address.mSelector = kAudioDevicePropertyNominalSampleRate;
    Float64 unsupported = 44100;
    assert(interface.SetPropertyData(driver, device, 0, &address, 0, nullptr, sizeof(unsupported), &unsupported) != noErr);
    assert(interface.StartIO(driver, device, 1) == noErr);
    Float64 sample = 0; UInt64 hostTime = 0, value = 0;
    assert(interface.GetZeroTimeStamp(driver, device, 1, &sample, &hostTime, &value) == noErr);
    assert(hostTime > 0 && value > 0 && static_cast<UInt64>(sample) % period == 0);
    std::vector<Float32> output(1024), input(1024);
    for (size_t i = 0; i < output.size(); i += 2) { output[i] = 0.25f; output[i + 1] = -0.5f; }
    AudioServerPlugInIOCycleInfo cycle{};
    cycle.mOutputTime.mSampleTime = 8192;
    cycle.mInputTime.mSampleTime = 8192 + delayFrames;
    auto write = [&] { return interface.DoIOOperation(driver, device, outputStream, 1, kAudioServerPlugInIOOperationWriteMix, 512, &cycle, output.data(), nullptr); };
    auto read = [&] { return interface.DoIOOperation(driver, device, inputStream, 2, kAudioServerPlugInIOOperationReadInput, 512, &cycle, input.data(), nullptr); };
    assert(write() == noErr && read() == noErr && input == output);
    cycle.mInputTime.mSampleTime += capacity;
    assert(read() == noErr);
    for (auto v : input) assert(v == 0);
    cycle.mInputTime.mSampleTime = 0;
    assert(read() == noErr);
    for (auto v : input) assert(v == 0);
    cycle.mInputTime.mSampleTime = 8192 + delayFrames;
    output[0] = INFINITY; output[1] = 2;
    assert(write() == noErr && read() == noErr && input[0] == 0 && input[1] == 1);
    assert(interface.StopIO(driver, device, 1) == noErr);
    assert(interface.StartIO(driver, device, 1) == noErr && read() == noErr);
    for (auto v : input) assert(v == 0);
    assert(interface.StopIO(driver, device, 1) == noErr);
    std::atomic<bool> finished{false};
    std::thread writer([&] {
        AudioServerPlugInIOCycleInfo local{};
        std::vector<Float32> data(1024);
        for (UInt32 block = 0; block < 2000; ++block) {
            local.mOutputTime.mSampleTime = block * 512;
            for (size_t i = 0; i < data.size(); i += 2) {
                data[i] = (block % 100) / 100.0f; data[i + 1] = -data[i];
            }
            assert(interface.DoIOOperation(driver, device, outputStream, 1,
                kAudioServerPlugInIOOperationWriteMix, 512, &local, data.data(), nullptr) == noErr);
        }
        finished.store(true);
    });
    AudioServerPlugInIOCycleInfo local{};
    for (UInt32 block = 0; !finished.load() || block < 2000; ++block) {
        local.mInputTime.mSampleTime = (block % 2000) * 512 + delayFrames;
        assert(interface.DoIOOperation(driver, device, inputStream, 2,
            kAudioServerPlugInIOOperationReadInput, 512, &local, input.data(), nullptr) == noErr);
        for (size_t i = 0; i < input.size(); i += 2) assert(input[i] == -input[i + 1]);
    }
    writer.join();
    std::puts("Edith Microphone: device discovery, formats, clock, stereo loopback, silence and restart passed");
}
