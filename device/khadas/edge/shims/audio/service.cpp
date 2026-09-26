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
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <core-impl/Config.h>

using aidl::android::hardware::audio::core::rk3399::ModuleRk3399;

int main() {
    // The audio HAL is latency-sensitive and serves several concurrent streams;
    // AOSP's own audio services use a pool of 16.
    ABinderProcess_setThreadPoolMaxThreadCount(16);
    ABinderProcess_startThreadPool();

    // IConfig carries the static surround-sound and engine configuration. It is
    // AOSP's implementation unchanged - nothing about it is board-specific.
    auto config = ndk::SharedRefBase::make<aidl::android::hardware::audio::core::Config>();
    const std::string configName =
            std::string(aidl::android::hardware::audio::core::Config::descriptor) + "/default";
    binder_status_t status =
            AServiceManager_addService(config->asBinder().get(), configName.c_str());
    CHECK_EQ(status, STATUS_OK) << "failed to register " << configName;

    // The primary module: HDMI + S/PDIF, backed by the legacy Rockchip
    // audio_hw_device. Its Configuration comes from
    // /vendor/etc/audio_policy_configuration.xml.
    auto module = ndk::SharedRefBase::make<ModuleRk3399>(
            aidl::android::hardware::audio::core::Module::initializeConfiguration());
    const std::string moduleName = std::string(ModuleRk3399::descriptor) + "/default";
    status = AServiceManager_addService(module->asBinder().get(), moduleName.c_str());
    CHECK_EQ(status, STATUS_OK) << "failed to register " << moduleName;

    LOG(INFO) << "registered " << moduleName;
    ABinderProcess_joinThreadPool();
    return EXIT_FAILURE;  // joinThreadPool does not return
}
