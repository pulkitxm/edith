#include "MeetingVoiceRuntime.h"
#include <onnxruntime/onnxruntime_cxx_api.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <vector>

struct MeetingVoiceSession {
    Ort::Env environment{ORT_LOGGING_LEVEL_ERROR, "meeting-voice"};
    Ort::SessionOptions options;
    std::unique_ptr<Ort::Session> encoder;
    std::unique_ptr<Ort::Session> voice;
    size_t dimensions = 0;
    bool half = false;
    const char *encoderOutput = nullptr;

    MeetingVoiceSession(const char *encoderPath, const char *voicePath) {
        environment.DisableTelemetryEvents();
        options.SetIntraOpNumThreads(2);
        options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        encoder = std::make_unique<Ort::Session>(environment, encoderPath, options);
        voice = std::make_unique<Ort::Session>(environment, voicePath, options);
        Ort::AllocatorWithDefaultOptions allocator;
        const char *names[] = {"feats", "p_len", "pitch", "pitchf", "sid"};
        if (encoder->GetInputCount() != 1 || voice->GetInputCount() != 5)
            throw std::runtime_error("Choose a ContentVec encoder and an ONNX RVC voice export.");
        for (size_t i = 0; i < 5; ++i) {
            if (std::string(voice->GetInputNameAllocated(i, allocator).get()) != names[i])
                throw std::runtime_error("The voice must use the RVC feats/p_len/pitch/pitchf/sid format.");
        }
        auto info = voice->GetInputTypeInfo(0);
        auto tensor = info.GetTensorTypeAndShapeInfo();
        auto shape = tensor.GetShape();
        if (shape.size() != 3 || (shape[2] != 256 && shape[2] != 768))
            throw std::runtime_error("The voice must be an RVC v1 or v2 model.");
        dimensions = static_cast<size_t>(shape[2]);
        half = tensor.GetElementType() == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16;
        if (!half && tensor.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
            throw std::runtime_error("The voice model must use float32 or float16 features.");
        encoderOutput = dimensions == 768 ? "unit12" : "units9";
    }
};

static void voiceError(char *buffer, size_t capacity, const char *message) {
    if (buffer && capacity) std::snprintf(buffer, capacity, "%s", message);
}

void *MeetingVoiceCreate(const char *encoder, const char *voice, char *error, size_t capacity) {
    try {
        if (!encoder || !voice) throw std::runtime_error("Choose both voice model files.");
        return new MeetingVoiceSession(encoder, voice);
    }
    catch (const std::exception &failure) { voiceError(error, capacity, failure.what()); return nullptr; }
}

void MeetingVoiceDestroy(void *handle) { delete static_cast<MeetingVoiceSession *>(handle); }

static float voicePitch(const float *audio, size_t count, size_t center) {
    constexpr size_t window = 480;
    constexpr size_t maximumLag = 320;
    if (count < window + maximumLag) return 0;
    size_t start = std::min(center > window / 2 ? center - window / 2 : 0, count - window - maximumLag);
    float energy = 0;
    for (size_t i = 0; i < window; ++i) energy += audio[start + i] * audio[start + i];
    if (energy / window < 0.000001f) return 0;
    float differences[maximumLag + 1] = {};
    float sum = 0;
    for (size_t lag = 1; lag <= maximumLag; ++lag) {
        float difference = 0;
        for (size_t i = 0; i < window; ++i) {
            float delta = audio[start + i] - audio[start + i + lag];
            difference += delta * delta;
        }
        sum += difference;
        differences[lag] = sum > 0 ? difference * lag / sum : 1;
    }
    for (size_t lag = 15; lag < maximumLag; ++lag) {
        if (differences[lag] >= 0.2f) continue;
        while (lag + 1 < maximumLag && differences[lag + 1] < differences[lag]) ++lag;
        float offset = 0;
        if (lag > 0 && lag < maximumLag) {
            float denominator = differences[lag - 1] - 2 * differences[lag] + differences[lag + 1];
            if (std::abs(denominator) > 0.000001f)
                offset = (differences[lag - 1] - differences[lag + 1]) / (2 * denominator);
        }
        return 16000.0f / (lag + offset);
    }
    return 0;
}

int MeetingVoiceConvert(void *handle, const float *audio, size_t count, float transpose,
                        float *output, size_t capacity, int *sampleRate, char *error, size_t errorCapacity) {
    try {
        if (!handle || !audio || count < 800 || count > 32000 || !output || !sampleRate || !std::isfinite(transpose))
            throw std::runtime_error("Invalid voice conversion audio block.");
        for (size_t i = 0; i < count; ++i)
            if (!std::isfinite(audio[i])) throw std::runtime_error("Voice input must be finite.");
        auto &session = *static_cast<MeetingVoiceSession *>(handle);
        auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        int64_t audioShape[] = {1, static_cast<int64_t>(count)};
        auto audioTensor = Ort::Value::CreateTensor<float>(memory, const_cast<float *>(audio), count, audioShape, 2);
        const char *encoderNames[] = {"audio"};
        const char *encoderOutputs[] = {session.encoderOutput};
        auto units = session.encoder->Run(Ort::RunOptions{nullptr}, encoderNames, &audioTensor, 1, encoderOutputs, 1);
        auto unitInfo = units[0].GetTensorTypeAndShapeInfo();
        if (unitInfo.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
            throw std::runtime_error("The content encoder must return float32 features.");
        auto shape = unitInfo.GetShape();
        if (shape.size() != 3 || shape[1] <= 0 || shape[2] != static_cast<int64_t>(session.dimensions))
            throw std::runtime_error("The content encoder returned incompatible features.");
        int64_t frames = shape[1] * 2;
        std::vector<float> features(frames * session.dimensions);
        std::vector<Ort::Float16_t> halfFeatures(session.half ? features.size() : 0);
        auto values = units[0].GetTensorData<float>();
        for (int64_t i = 0; i < frames; ++i) {
            for (size_t j = 0; j < session.dimensions; ++j) {
                float value = values[(i / 2) * session.dimensions + j];
                features[i * session.dimensions + j] = value;
                if (session.half) halfFeatures[i * session.dimensions + j] = Ort::Float16_t(value);
            }
        }
        std::vector<int64_t> pitch(frames, 1);
        std::vector<float> pitchf(frames);
        float factor = std::pow(2.0f, std::clamp(transpose, -24.0f, 24.0f) / 12);
        for (int64_t i = 0; i < frames; ++i) {
            float f0 = voicePitch(audio, count, i * 160) * factor;
            pitchf[i] = f0;
            if (f0 > 0) {
                float mel = 1127 * std::log(1 + f0 / 700);
                float minimum = 1127 * std::log(1 + 50.0f / 700);
                float maximum = 1127 * std::log(1 + 1100.0f / 700);
                pitch[i] = std::clamp(static_cast<int64_t>(std::lround((mel - minimum) * 254 / (maximum - minimum) + 1)), int64_t(1), int64_t(255));
            }
        }
        int64_t speaker = 0;
        int64_t featureShape[] = {1, frames, static_cast<int64_t>(session.dimensions)};
        int64_t pitchShape[] = {1, frames};
        int64_t scalarShape[] = {1};
        std::vector<Ort::Value> inputs;
        if (session.half) inputs.push_back(Ort::Value::CreateTensor<Ort::Float16_t>(memory, halfFeatures.data(), halfFeatures.size(), featureShape, 3));
        else inputs.push_back(Ort::Value::CreateTensor<float>(memory, features.data(), features.size(), featureShape, 3));
        inputs.push_back(Ort::Value::CreateTensor<int64_t>(memory, &frames, 1, scalarShape, 1));
        inputs.push_back(Ort::Value::CreateTensor<int64_t>(memory, pitch.data(), pitch.size(), pitchShape, 2));
        inputs.push_back(Ort::Value::CreateTensor<float>(memory, pitchf.data(), pitchf.size(), pitchShape, 2));
        inputs.push_back(Ort::Value::CreateTensor<int64_t>(memory, &speaker, 1, scalarShape, 1));
        const char *inputNames[] = {"feats", "p_len", "pitch", "pitchf", "sid"};
        const char *outputNames[] = {"audio"};
        auto result = session.voice->Run(Ort::RunOptions{nullptr}, inputNames, inputs.data(), inputs.size(), outputNames, 1);
        auto info = result[0].GetTensorTypeAndShapeInfo();
        if (info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16
            && info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
            throw std::runtime_error("The voice output must contain floating-point audio.");
        size_t outputCount = info.GetElementCount();
        if (outputCount > capacity || outputCount % frames != 0)
            throw std::runtime_error("The voice returned an invalid audio length.");
        *sampleRate = static_cast<int>(outputCount / frames * 100);
        if (*sampleRate != 32000 && *sampleRate != 40000 && *sampleRate != 48000)
            throw std::runtime_error("The voice sample rate must be 32, 40 or 48 kHz.");
        for (size_t i = 0; i < outputCount; ++i) {
            float value = info.GetElementType() == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16
                ? result[0].GetTensorData<Ort::Float16_t>()[i].ToFloat() : result[0].GetTensorData<float>()[i];
            if (!std::isfinite(value)) throw std::runtime_error("The voice returned non-finite audio.");
            output[i] = std::clamp(value, -1.0f, 1.0f);
        }
        return static_cast<int>(outputCount);
    } catch (const std::exception &failure) { voiceError(error, errorCapacity, failure.what()); return -1; }
}
