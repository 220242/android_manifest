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

// AIDL android.hardware.audio.core-V2 shim for the Khadas Edge1.
//
// Design: subclass AOSP's reference implementation rather than implement
// IModule from scratch.
//
// hardware/interfaces/audio/aidl/default provides Module, ModulePrimary,
// StreamAlsa and friends precisely so that a device can override the
// hardware-specific pieces. IModule has on the order of forty methods -
// patch/port management, telephony, screen rotation, microphone info, sound
// dose - almost none of which are board-specific. Reimplementing them would be
// a large amount of code that AOSP already maintains, and it would need
// updating every time the interface revs.
//
// What IS board-specific on the Edge1 is stream I/O, and that is what this
// class redirects: into the legacy Rockchip audio_hw_device from
// hardware/rockchip/audio/tinyalsa_hal.
//
// Verified properties of that legacy HAL (read from the pinned Android 10
// revision, not assumed):
//   * struct audio_module HAL_MODULE_INFO_SYM, id = AUDIO_HARDWARE_MODULE_ID
//   * adev_open() sets common.version = AUDIO_DEVICE_API_VERSION_2_0
//   * adev_open_output_stream / adev_open_input_stream are the stream factories
//   * the only PCM format handled is AUDIO_FORMAT_PCM_16_BIT
//   * output supports up to 8 channels, with 8ch@192kHz special-cased
//   * passthrough is SPDIF_PASSTHROUGH_MODE: IEC61937-framed PCM, not a
//     distinct compressed format
//
// Those constraints are mirrored in ../../audio/audio_policy_configuration.xml.
// Keep the two in sync: the policy is what the framework believes, this shim is
// what actually opens.

#pragma once

#include <core-impl/Module.h>
#include <hardware/audio.h>

#include <memory>
#include <mutex>

namespace aidl::android::hardware::audio::core::rk3399 {

// Owns the legacy audio_hw_device_t for the lifetime of the service. One
// instance is shared by every stream, matching the legacy HAL's assumption
// that exactly one adev exists per process.
class LegacyAudioDevice {
  public:
    static std::shared_ptr<LegacyAudioDevice> getInstance();

    ~LegacyAudioDevice();

    audio_hw_device_t* get() const { return mDevice; }
    bool isValid() const { return mDevice != nullptr; }

    // The legacy HAL guards very little of its own state; adev-level calls are
    // serialised here.
    std::mutex& lock() { return mMutex; }

  private:
    LegacyAudioDevice() = default;
    bool open();

    audio_hw_device_t* mDevice = nullptr;
    std::mutex mMutex;
};

// Primary module: HDMI and S/PDIF. Mirrors the "primary" module in
// audio_policy_configuration.xml.
class ModuleRk3399 : public Module {
  public:
    explicit ModuleRk3399(std::unique_ptr<Configuration>&& config);

  protected:
    // Stream creation is the only part that must reach the legacy HAL. The
    // exact signatures of createStreamContext / createInputStream /
    // createOutputStream follow AOSP's Module and MUST be checked against the
    // synced hardware/interfaces/audio/aidl/default headers before building -
    // they changed between 13 and 14 and again in QPR releases.
    ndk::ScopedAStatus createInputStream(StreamContext&& context,
                                         const ::aidl::android::hardware::audio::common::SinkMetadata& sinkMetadata,
                                         const std::vector<microphone_info>& microphones,
                                         std::shared_ptr<StreamIn>* result) override;

    ndk::ScopedAStatus createOutputStream(StreamContext&& context,
                                          const ::aidl::android::hardware::audio::common::SourceMetadata& sourceMetadata,
                                          const std::optional<::aidl::android::hardware::audio::core::AudioOffloadInfo>& offloadInfo,
                                          std::shared_ptr<StreamOut>* result) override;

  private:
    std::shared_ptr<LegacyAudioDevice> mLegacy;
};

}  // namespace aidl::android::hardware::audio::core::rk3399
