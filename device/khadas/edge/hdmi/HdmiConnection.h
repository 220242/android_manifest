/*
 * Khadas Edge1 - android.hardware.tv.hdmi.connection IHdmiConnection: the one HDMI
 * output and whether a TV is on it.
 */
#pragma once

#include <aidl/android/hardware/tv/hdmi/connection/BnHdmiConnection.h>

#include <memory>
#include <mutex>

#include "CecAdapter.h"

namespace edge1 {

using ::aidl::android::hardware::tv::hdmi::connection::BnHdmiConnection;
using ::aidl::android::hardware::tv::hdmi::connection::HdmiPortInfo;
using ::aidl::android::hardware::tv::hdmi::connection::HpdSignal;
using ::aidl::android::hardware::tv::hdmi::connection::IHdmiConnectionCallback;

class HdmiConnection : public BnHdmiConnection {
  public:
    // HDMI port ids start at 1 (HdmiPortInfo.aidl); the Edge1 has one port, an output.
    static constexpr int32_t kPortId = 1;

    explicit HdmiConnection(CecAdapter& adapter);

    ::ndk::ScopedAStatus getPortInfo(std::vector<HdmiPortInfo>* _aidl_return) override;
    ::ndk::ScopedAStatus isConnected(int32_t portId, bool* _aidl_return) override;
    ::ndk::ScopedAStatus setCallback(
            const std::shared_ptr<IHdmiConnectionCallback>& callback) override;
    ::ndk::ScopedAStatus setHpdSignal(HpdSignal signal, int32_t portId) override;
    ::ndk::ScopedAStatus getHpdSignal(int32_t portId, HpdSignal* _aidl_return) override;

    // From the adapter's thread: the physical address changed.
    void onPhysicalAddress(uint16_t physicalAddress);

  private:
    CecAdapter& adapter_;
    std::mutex callbackMutex_;
    std::shared_ptr<IHdmiConnectionCallback> callback_;
};

}  // namespace edge1
