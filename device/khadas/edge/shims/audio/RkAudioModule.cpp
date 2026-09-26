/*
 * Copyright (C) 2026 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#define LOG_TAG "AudioCoreRk3399"

#include "RkAudioModule.h"

#include <android-base/logging.h>

namespace aidl::android::hardware::audio::core::rk3399 {

std::shared_ptr<LegacyAudioDevice> LegacyAudioDevice::getInstance() {
    static std::shared_ptr<LegacyAudioDevice> instance = [] {
        auto dev = std::shared_ptr<LegacyAudioDevice>(new LegacyAudioDevice());
        if (!dev->open()) {
            LOG(ERROR) << "legacy Rockchip audio HAL unavailable";
        }
        return dev;
    }();
    return instance;
}

bool LegacyAudioDevice::open() {
    const hw_module_t* module = nullptr;
    // "primary" matches ro.hardware.audio.primary=rk3399 set in device.mk,
    // which makes libhardware load audio.primary.rk3399.so.
    int err = hw_get_module_by_class(AUDIO_HARDWARE_MODULE_ID, "primary", &module);
    if (err != 0 || module == nullptr) {
        LOG(ERROR) << "hw_get_module_by_class(audio, primary) failed: " << err;
        return false;
    }

    audio_hw_device_t* device = nullptr;
    err = audio_hw_device_open(module, &device);
    if (err != 0 || device == nullptr) {
        LOG(ERROR) << "audio_hw_device_open failed: " << err;
        return false;
    }

    // The Rockchip HAL reports AUDIO_DEVICE_API_VERSION_2_0. Anything older
    // lacks open_output_stream's `address` parameter and would crash on call.
    if (device->common.version < AUDIO_DEVICE_API_VERSION_2_0) {
        LOG(ERROR) << "legacy audio HAL version 0x" << std::hex << device->common.version
                   << " is older than 2.0; refusing to use it";
        audio_hw_device_close(device);
        return false;
    }

    mDevice = device;
    LOG(INFO) << "opened legacy Rockchip audio HAL, version 0x" << std::hex
              << device->common.version;
    return true;
}

LegacyAudioDevice::~LegacyAudioDevice() {
    if (mDevice != nullptr) {
        audio_hw_device_close(mDevice);
    }
}

ModuleRk3399::ModuleRk3399(std::unique_ptr<Configuration>&& config)
    : Module(Type::DEFAULT, std::move(config)), mLegacy(LegacyAudioDevice::getInstance()) {}

// -----------------------------------------------------------------------------
// The two overrides below are where the legacy audio_hw_device is bridged in.
//
// NOT YET IMPLEMENTED. This is a deliberate, declared gap rather than an
// oversight: StreamIn/StreamOut in Android 14 exchange audio over an FMQ with a
// dedicated worker thread, and the driver interface those wrappers must satisfy
// (StreamCommonImpl / DriverInterface: init/drain/flush/transfer/standby) is
// defined by headers in the synced AOSP tree. Writing these bodies against
// remembered signatures would produce code that looks finished and does not
// compile.
//
// The work each one needs, concretely:
//   1. Translate StreamContext's AudioPortConfig into a struct audio_config
//      (format, sample rate, channel mask) and call
//      mLegacy->get()->open_output_stream / open_input_stream.
//   2. Wrap the returned audio_stream_out_t / audio_stream_in_t in a
//      DriverInterface whose transfer() calls stream->write() / stream->read()
//      and whose standby()/drain()/flush() map onto the legacy equivalents.
//   3. Reject any config the legacy HAL cannot honour - notably formats other
//      than AUDIO_FORMAT_PCM_16_BIT and IEC61937, and output masks above 8
//      channels - so a mismatch surfaces as an error, not as silence.
//
// See docs/HAL_MIGRATION.md, "Audio", for the step-by-step.
// -----------------------------------------------------------------------------

ndk::ScopedAStatus ModuleRk3399::createInputStream(
        StreamContext&& /*context*/,
        const ::aidl::android::hardware::audio::common::SinkMetadata& /*sinkMetadata*/,
        const std::vector<microphone_info>& /*microphones*/,
        std::shared_ptr<StreamIn>* /*result*/) {
    // The Edge1 TV SKU has no local capture device at all (no mic, no line-in);
    // USB and Bluetooth capture are served by their own modules. Returning
    // unsupported here is correct for this board, not a placeholder.
    LOG(WARNING) << "createInputStream: no capture device on this board";
    return ndk::ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
}

ndk::ScopedAStatus ModuleRk3399::createOutputStream(
        StreamContext&& /*context*/,
        const ::aidl::android::hardware::audio::common::SourceMetadata& /*sourceMetadata*/,
        const std::optional<::aidl::android::hardware::audio::core::AudioOffloadInfo>& /*offloadInfo*/,
        std::shared_ptr<StreamOut>* /*result*/) {
    LOG(FATAL) << "createOutputStream is not implemented yet; see "
                  "docs/HAL_MIGRATION.md (Audio). Do not ship this build.";
    return ndk::ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
}

}  // namespace aidl::android::hardware::audio::core::rk3399
