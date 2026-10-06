/*
 * Khadas Edge1 - android.hardware.tv.hdmi.cec IHdmiCec over the Linux CEC adapter.
 */
#pragma once

#include <aidl/android/hardware/tv/hdmi/cec/BnHdmiCec.h>

#include <atomic>
#include <memory>
#include <mutex>

#include "CecAdapter.h"

namespace edge1 {

using ::aidl::android::hardware::tv::hdmi::cec::BnHdmiCec;
using ::aidl::android::hardware::tv::hdmi::cec::CecLogicalAddress;
using ::aidl::android::hardware::tv::hdmi::cec::CecMessage;
using ::aidl::android::hardware::tv::hdmi::cec::IHdmiCecCallback;
using ::aidl::android::hardware::tv::hdmi::cec::Result;
using ::aidl::android::hardware::tv::hdmi::cec::SendMessageResult;

class HdmiCec : public BnHdmiCec {
  public:
    explicit HdmiCec(CecAdapter& adapter);

    ::ndk::ScopedAStatus addLogicalAddress(CecLogicalAddress addr, Result* _aidl_return) override;
    ::ndk::ScopedAStatus clearLogicalAddress() override;
    ::ndk::ScopedAStatus enableAudioReturnChannel(int32_t portId, bool enable) override;
    ::ndk::ScopedAStatus getCecVersion(int32_t* _aidl_return) override;
    ::ndk::ScopedAStatus getPhysicalAddress(int32_t* _aidl_return) override;
    ::ndk::ScopedAStatus getVendorId(int32_t* _aidl_return) override;
    ::ndk::ScopedAStatus sendMessage(const CecMessage& message,
                                     SendMessageResult* _aidl_return) override;
    ::ndk::ScopedAStatus setCallback(const std::shared_ptr<IHdmiCecCallback>& callback) override;
    ::ndk::ScopedAStatus setLanguage(const std::string& language) override;
    ::ndk::ScopedAStatus enableWakeupByOtp(bool value) override;
    ::ndk::ScopedAStatus enableCec(bool value) override;
    ::ndk::ScopedAStatus enableSystemCecControl(bool value) override;

    // From the adapter's thread: a message for us, or a broadcast.
    void onMessage(uint8_t initiator, uint8_t destination, const std::vector<uint8_t>& body);

  private:
    CecAdapter& adapter_;
    std::mutex callbackMutex_;
    std::shared_ptr<IHdmiCecCallback> callback_;
    // AOSP's defaults once a CEC device is found (HdmiCecDefault::init).
    std::atomic<bool> cecEnabled_{true};
    std::atomic<bool> wakeupEnabled_{true};
    std::atomic<bool> systemControl_{true};
};

}  // namespace edge1
