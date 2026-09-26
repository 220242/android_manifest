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

#include <aidl/android/hardware/graphics/allocator/AllocationError.h>
#include <aidlcommonsupport/NativeHandle.h>
#include <android-base/logging.h>

namespace aidl::android::hardware::graphics::allocator::impl {

using ::aidl::android::hardware::graphics::common::BufferUsage;
using ::aidl::android::hardware::graphics::common::PixelFormat;

namespace {

ndk::ScopedAStatus error(AllocationError err) {
    return ndk::ScopedAStatus::fromServiceSpecificError(static_cast<int32_t>(err));
}

}  // namespace

RkAllocator::RkAllocator() {
    const hw_module_t* module = nullptr;
    int err = hw_get_module(GRALLOC_HARDWARE_MODULE_ID, &module);
    if (err != 0 || module == nullptr) {
        LOG(ERROR) << "hw_get_module(" << GRALLOC_HARDWARE_MODULE_ID << ") failed: " << err;
        return;
    }

    // The Rockchip module reports GRALLOC_MODULE_API_VERSION_0_x. If a future
    // BSP switches it to gralloc1, gralloc_open() below fails rather than
    // silently misbehaving, so the version is not asserted here.
    err = gralloc_open(module, &mAllocDev);
    if (err != 0 || mAllocDev == nullptr) {
        LOG(ERROR) << "gralloc_open failed: " << err;
        return;
    }

    mModule = reinterpret_cast<const gralloc_module_t*>(module);
    LOG(INFO) << "opened Rockchip gralloc0: " << module->name << " v" << module->module_api_version;
}

RkAllocator::~RkAllocator() {
    if (mAllocDev != nullptr) {
        gralloc_close(mAllocDev);
    }
}

// Deprecated path. The opaque descriptor blob is produced by IMapper's
// createDescriptor() and its encoding is private to the mapper implementation.
// Rockchip's gralloc0 has no createDescriptor at all - Android 10 clients built
// the descriptor in libui against mapper@{2,3}.0 and this service never saw it.
// Rejecting it is correct rather than lossy: every Android 13+ client calls
// allocate2, and libui falls back only when allocate2 returns UNSUPPORTED.
ndk::ScopedAStatus RkAllocator::allocate(const std::vector<uint8_t>& /*descriptor*/,
                                        int32_t /*count*/, AllocationResult* /*result*/) {
    return ndk::ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
}

ndk::ScopedAStatus RkAllocator::allocateOne(const BufferDescriptorInfo& descriptor,
                                           buffer_handle_t* outHandle, int32_t* outStride) {
    // gralloc0 takes int dimensions and the legacy int usage bitmask. The AIDL
    // usage is 64-bit; the RK3399 gralloc only consumes the low 32 bits
    // (GRALLOC_USAGE_*), and the bits above bit 31 are all
    // BufferUsage::VENDOR_MASK_HI or GPU_CUBE_MAP/MIPMAP, none of which this
    // hardware implements. Truncating is therefore lossless *for this board*,
    // but it must be an explicit, checked truncation rather than an implicit
    // narrowing conversion.
    const uint64_t usage64 = static_cast<uint64_t>(descriptor.usage);
    constexpr uint64_t kUnsupportedHiBits = 0xffffffff00000000ULL;
    if ((usage64 & kUnsupportedHiBits) != 0) {
        LOG(WARNING) << "dropping unsupported high usage bits 0x" << std::hex
                     << (usage64 & kUnsupportedHiBits) << " for '" << descriptor.name << "'";
    }
    const int usage = static_cast<int>(usage64 & 0xffffffffULL);

    if (descriptor.width <= 0 || descriptor.height <= 0) {
        return error(AllocationError::BAD_DESCRIPTOR);
    }
    // gralloc0 has no layerCount concept. Anything above a single layer would
    // silently allocate a non-array buffer and corrupt array-texture clients,
    // so reject instead.
    if (descriptor.layerCount != 1) {
        LOG(ERROR) << "layerCount " << descriptor.layerCount << " unsupported by gralloc0";
        return error(AllocationError::UNSUPPORTED);
    }

    buffer_handle_t handle = nullptr;
    int stride = 0;
    const int err = mAllocDev->alloc(mAllocDev, descriptor.width, descriptor.height,
                                     static_cast<int>(descriptor.format), usage, &handle, &stride);
    if (err != 0 || handle == nullptr) {
        LOG(ERROR) << "gralloc alloc(" << descriptor.width << "x" << descriptor.height << ", fmt 0x"
                   << std::hex << static_cast<int>(descriptor.format) << ", usage 0x" << usage
                   << ") failed: " << std::dec << err;
        // ENOMEM is the only failure the Rockchip allocator distinguishes; any
        // other errno means the format/usage pair is not implementable.
        return error(err == -ENOMEM ? AllocationError::NO_RESOURCES : AllocationError::UNSUPPORTED);
    }

    *outHandle = handle;
    *outStride = stride;
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus RkAllocator::allocate2(const BufferDescriptorInfo& descriptor, int32_t count,
                                         AllocationResult* result) {
    if (!isValid()) {
        return error(AllocationError::NO_RESOURCES);
    }
    if (count < 0) {
        return error(AllocationError::BAD_DESCRIPTOR);
    }
    // additionalOptions is a V2 addition used by vendor-specific allocation
    // hints. Rockchip's gralloc0 predates it and has no way to honour one, so
    // accepting a request carrying options would silently ignore them.
    if (!descriptor.additionalOptions.empty()) {
        return error(AllocationError::UNSUPPORTED);
    }

    std::lock_guard<std::mutex> lock(mMutex);

    std::vector<buffer_handle_t> handles;
    handles.reserve(count);
    int32_t stride = 0;

    for (int32_t i = 0; i < count; i++) {
        buffer_handle_t handle = nullptr;
        int32_t thisStride = 0;
        auto status = allocateOne(descriptor, &handle, &thisStride);
        if (!status.isOk()) {
            // Partial success is not representable in AllocationResult, so
            // unwind everything allocated so far.
            for (auto h : handles) {
                mAllocDev->free(mAllocDev, h);
            }
            return status;
        }
        if (i == 0) {
            stride = thisStride;
        } else if (thisStride != stride) {
            // AllocationResult carries a single stride for the whole batch.
            LOG(ERROR) << "inconsistent stride in batch: " << thisStride << " != " << stride;
            mAllocDev->free(mAllocDev, handle);
            for (auto h : handles) {
                mAllocDev->free(mAllocDev, h);
            }
            return error(AllocationError::UNSUPPORTED);
        }
        handles.push_back(handle);
    }

    result->stride = stride;
    result->buffers.reserve(handles.size());
    for (auto handle : handles) {
        // dupToAidl duplicates the fds; the originals are owned by gralloc and
        // released by free() below. Without the free the service would leak one
        // buffer's worth of DRM GEM handles per allocation.
        result->buffers.emplace_back(::android::dupToAidl(handle));
        mAllocDev->free(mAllocDev, handle);
    }
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus RkAllocator::isSupported(const BufferDescriptorInfo& descriptor,
                                           bool* supported) {
    // gralloc0 has no dry-run query. Probing by allocating and freeing would
    // be correct but is expensive enough that SurfaceFlinger's per-frame
    // queries would regress; instead the statically-known constraints are
    // checked, which is what the Rockchip allocator itself enforces.
    *supported = isValid() && descriptor.width > 0 && descriptor.height > 0 &&
                 descriptor.layerCount == 1 && descriptor.additionalOptions.empty();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus RkAllocator::getIMapperLibrarySuffix(std::string* /*suffix*/) {
    // Deliberately unsupported.
    //
    // Returning a suffix tells libui to load /vendor/lib64/mapper.<suffix>.so
    // and use IMapper 5.0 (the stable-c mapper). This device declares
    // android.hardware.graphics.mapper@4.0 (Gralloc4) in its VINTF manifest, so
    // clients must go through the HIDL mapper. Answering this call would make
    // libui look for an IMapper 5 library that does not exist and fail buffer
    // import at runtime. See docs/HAL_MIGRATION.md for the IMapper 5 plan.
    return ndk::ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
}

}  // namespace aidl::android::hardware::graphics::allocator::impl
