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

#define LOG_TAG "AllocatorRk3399"

#include "RkAllocator.h"

#include <android-base/logging.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>

using aidl::android::hardware::graphics::allocator::impl::RkAllocator;

int main() {
    // One extra thread beyond the caller: allocation is short and serialised on
    // mMutex anyway, so a large pool would only add contention.
    ABinderProcess_setThreadPoolMaxThreadCount(2);

    auto allocator = ndk::SharedRefBase::make<RkAllocator>();
    if (!allocator->isValid()) {
        // Failing loudly is the right behaviour: with no allocator,
        // SurfaceFlinger cannot start and a silent exit would present as an
        // unexplained blank screen.
        LOG(FATAL) << "failed to open the Rockchip gralloc module; refusing to register";
    }

    const std::string instance =
            std::string(RkAllocator::descriptor) + "/default";
    binder_status_t status =
            AServiceManager_addService(allocator->asBinder().get(), instance.c_str());
    CHECK_EQ(status, STATUS_OK) << "failed to register " << instance;

    LOG(INFO) << "registered " << instance;
    ABinderProcess_joinThreadPool();
    return EXIT_FAILURE;  // joinThreadPool does not return
}
