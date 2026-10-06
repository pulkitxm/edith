#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void *MeetingVoiceCreate(const char *encoder, const char *voice, char *error, size_t capacity);
void MeetingVoiceDestroy(void *handle);
int MeetingVoiceConvert(void *handle, const float *audio, size_t count, float transpose,
                        float *output, size_t capacity, int *sampleRate,
                        char *error, size_t errorCapacity);

#ifdef __cplusplus
}
#endif
