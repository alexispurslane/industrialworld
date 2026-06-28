/*
 * industrialworld -- minimal spatial audio engine via miniaudio.
 *
 * A thin C wrapper around miniaudio's high-level ma_engine API. miniaudio
 * is cross-platform (CoreAudio/WASAPI/ALSA/Pulse/JACK) and ships as a
 * single header, so this file is the only platform-adjacent code.
 *
 * Exposed to LuaJIT FFI:
 *   iw_audio_init()                                               -> 0/-1
 *   iw_audio_shutdown()
 *   iw_audio_play_file(path, volume, pan)                         -> slot/-1
 *   iw_audio_play_buffer(data, bytes, channels, sample_rate,
 *                         volume, pan)                            -> slot/-1
 *   iw_audio_voice_is_playing(slot)                               -> 0/1
 *   iw_audio_voice_stop(slot)
 *
 * Each successful play call creates a fresh voice (no need to copy
 * sounds). Voices are short-lived and cleaned up by the caller once
 * iw_audio_voice_is_playing() returns false.
 */

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#define IW_AUDIO_MAX_VOICES 64

typedef struct {
    ma_sound sound;
    ma_audio_buffer_ref buffer_ref; /* only valid when is_buffer == 1 */
    int is_buffer;
    int used;
} iw_voice_t;

static ma_engine g_engine;
static int g_engine_inited = 0;
static iw_voice_t g_voices[IW_AUDIO_MAX_VOICES];

static int find_voice_slot(void)
{
    for (int i = 0; i < IW_AUDIO_MAX_VOICES; i++) {
        if (!g_voices[i].used) {
            return i;
        }
    }
    return -1;
}

int iw_audio_init(void)
{
    if (g_engine_inited) {
        return 0;
    }

    ma_result result = ma_engine_init(NULL, &g_engine);
    if (result != MA_SUCCESS) {
        fprintf(stderr, "iw_audio_init: ma_engine_init failed (%d)\n", (int)result);
        return -1;
    }

    memset(g_voices, 0, sizeof(g_voices));
    g_engine_inited = 1;
    return 0;
}

void iw_audio_shutdown(void)
{
    if (!g_engine_inited) {
        return;
    }

    for (int i = 0; i < IW_AUDIO_MAX_VOICES; i++) {
        if (g_voices[i].used) {
            ma_sound_stop(&g_voices[i].sound);
            ma_sound_uninit(&g_voices[i].sound);
            if (g_voices[i].is_buffer) {
                ma_audio_buffer_ref_uninit(&g_voices[i].buffer_ref);
            }
        }
    }

    ma_engine_uninit(&g_engine);
    g_engine_inited = 0;
}

static int finish_voice_setup(iw_voice_t *voice, float volume, float pan)
{
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    if (pan < -1.0f) pan = -1.0f;
    if (pan > 1.0f) pan = 1.0f;

    ma_sound_set_volume(&voice->sound, volume);
    ma_sound_set_pan(&voice->sound, pan);

    ma_result result = ma_sound_start(&voice->sound);
    if (result != MA_SUCCESS) {
        fprintf(stderr, "iw_audio_play: ma_sound_start failed (%d)\n", (int)result);
        ma_sound_uninit(&voice->sound);
        if (voice->is_buffer) {
            ma_audio_buffer_ref_uninit(&voice->buffer_ref);
        }
        voice->used = 0;
        return -1;
    }

    return 0;
}

int iw_audio_play_file(const char *path, float volume, float pan)
{
    if (!g_engine_inited || path == NULL) {
        return -1;
    }

    int slot = find_voice_slot();
    if (slot < 0) {
        return -1;
    }

    iw_voice_t *voice = &g_voices[slot];
    ma_result result = ma_sound_init_from_file(&g_engine, path,
        MA_SOUND_FLAG_DECODE, NULL, NULL, &voice->sound);
    if (result != MA_SUCCESS) {
        fprintf(stderr, "iw_audio_play_file: failed to load '%s' (%d)\n", path, (int)result);
        return -1;
    }

    voice->is_buffer = 0;
    voice->used = 1;

    if (finish_voice_setup(voice, volume, pan) != 0) {
        return -1;
    }
    return slot;
}

int iw_audio_play_buffer(const void *data, int bytes, int channels,
                         int sample_rate, float volume, float pan)
{
    if (!g_engine_inited || data == NULL || bytes <= 0 ||
        channels <= 0 || sample_rate <= 0) {
        return -1;
    }

    int slot = find_voice_slot();
    if (slot < 0) {
        return -1;
    }

    iw_voice_t *voice = &g_voices[slot];
    ma_format format = ma_format_s16;
    ma_uint32 frames = (ma_uint32)(bytes / (channels * sizeof(ma_int16)));

    ma_result result = ma_audio_buffer_ref_init(format, (ma_uint32)channels,
        (void *)data, frames, &voice->buffer_ref);
    if (result != MA_SUCCESS) {
        fprintf(stderr, "iw_audio_play_buffer: buffer_ref_init failed (%d)\n", (int)result);
        return -1;
    }

    result = ma_sound_init_from_data_source(&g_engine,
        &voice->buffer_ref, MA_SOUND_FLAG_DECODE, NULL, &voice->sound);
    if (result != MA_SUCCESS) {
        fprintf(stderr, "iw_audio_play_buffer: sound_init_from_data_source failed (%d)\n", (int)result);
        ma_audio_buffer_ref_uninit(&voice->buffer_ref);
        return -1;
    }

    voice->is_buffer = 1;
    voice->used = 1;

    if (finish_voice_setup(voice, volume, pan) != 0) {
        return -1;
    }
    return slot;
}

int iw_audio_voice_is_playing(int slot)
{
    if (slot < 0 || slot >= IW_AUDIO_MAX_VOICES) {
        return 0;
    }
    if (!g_voices[slot].used) {
        return 0;
    }
    return ma_sound_is_playing(&g_voices[slot].sound) ? 1 : 0;
}

void iw_audio_voice_stop(int slot)
{
    if (slot < 0 || slot >= IW_AUDIO_MAX_VOICES) {
        return;
    }
    if (!g_voices[slot].used) {
        return;
    }
    ma_sound_stop(&g_voices[slot].sound);
    ma_sound_uninit(&g_voices[slot].sound);
    if (g_voices[slot].is_buffer) {
        ma_audio_buffer_ref_uninit(&g_voices[slot].buffer_ref);
    }
    g_voices[slot].used = 0;
    g_voices[slot].is_buffer = 0;
}
