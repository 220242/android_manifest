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

// AIDL android.hardware.graphics.allocator-V2 shim over the Rockchip
// Mali-T860 (Midgard) gralloc0 module.
//
// Why a shim rather than a rewrite: hardware/rockchip/libgralloc/midgard is a
// classic gralloc0 module. gralloc.cpp registers
//   base.common.id = GRALLOC_HARDWARE_MODULE_ID
// and hands out an alloc_device_t whose ->alloc is drm_mod_alloc_gpu0(). That
// allocator already understands the RK3399's AFBC layouts, the DRM scanout
// constraints and the VPU's stride alignment. Reimplementing it against AIDL
// would mean re-deriving all of that; wrapping it keeps the allocation policy
// and only replaces the transport.
//
// Android 10 reached this module through
// android.hardware.graphics.allocator@2.0, a passthrough HAL that ran inside
// each client. Android 14 requires a real binder service.

#pragma once

#include <aidl/android/hardware/graphics/allocator/BnAllocator.h>
#include <hardware/gralloc.h>

#include <mutex>

namespace aidl::android::hardware::graphics::allocator::impl {

class RkAllocator : public BnAllocator {
  public:
    RkAllocator();
    ~RkAllocator() override;

    // Deprecated in V2: takes an opaque descriptor produced by IMapper 4.0's
    // createDescriptor. Unsupported here - see the .cpp for why.
    ndk::ScopedAStatus allocate(const std::vector<uint8_t>& descriptor, int32_t count,
                                AllocationResult* result) override;

    ndk::ScopedAStatus allocate2(const BufferDescriptorInfo& descriptor, int32_t count,
                                 AllocationResult* result) override;

    ndk::ScopedAStatus isSupported(const BufferDescriptorInfo& descriptor,
                                   bool* supported) override;

    ndk::ScopedAStatus getIMapperLibrarySuffix(std::string* suffix) override;

    // True if the underlying gralloc0 module was opened successfully.
    bool isValid() const { return mAllocDev != nullptr; }

  private:
    // Translates one BufferDescriptorInfo into a gralloc0 alloc() call.
    ndk::ScopedAStatus allocateOne(const BufferDescriptorInfo& descriptor,
                                   buffer_handle_t* outHandle, int32_t* outStride);

    const gralloc_module_t* mModule = nullptr;
    alloc_device_t* mAllocDev = nullptr;

    // gralloc0 makes no thread-safety guarantee and the Rockchip
    // implementation keeps global DRM state in gralloc_drm_rockchip.cpp, so
    // every alloc/free is serialised. An AIDL service is multi-threaded by
    // default, unlike the passthrough HAL this replaces, where the client's
    // own locking happened to serialise access.
    std::mutex mMutex;
};

}  // namespace aidl::android::hardware::graphics::allocator::impl
