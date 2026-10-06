/*
 * Khadas Edge1 - android.hardware.tv.hdmi.connection IHdmiConnection.
 *
 * "Connected" is "has a physical address": the HDMI bridge sets it from the TV's
 * EDID when the cable goes in and invalidates it when it comes out (dw-hdmi's CEC
 * notifier), and the CEC adapter reports both as a state change. That is how
 * AOSP's HdmiCecDefault decides it too. A TV whose EDID has no CEC block has no
 * physical address and reads as not connected - CEC has nothing to do with it
 * anyway; the picture and the sound do not depend on this HAL.
 */
#define LOG_TAG "edge1-hdmi"

#include "HdmiConnection.h"

#include <log/log.h>

namespace edge1 {

using ::aidl::android::hardware::tv::hdmi::connection::HdmiPortType;
using ::aidl::android::hardware::tv::hdmi::connection::Result;
using ::ndk::ScopedAStatus;

HdmiConnection::HdmiConnection(CecAdapter& adapter) : adapter_(adapter) {}

ScopedAStatus HdmiConnection::getPortInfo(std::vector<HdmiPortInfo>* _aidl_return) {
    HdmiPortInfo port;
    port.type = HdmiPortType::OUTPUT;
    port.portId = kPortId;
    port.cecSupported = adapter_.isOpen();
    port.arcSupported = false;
    port.eArcSupported = false;
    port.physicalAddress = adapter_.physicalAddress();
    *_aidl_return = {port};
    return ScopedAStatus::ok();
}

ScopedAStatus HdmiConnection::isConnected(int32_t portId, bool* _aidl_return) {
    *_aidl_return = portId == kPortId && adapter_.physicalAddress() != kInvalidPhysicalAddress;
    return ScopedAStatus::ok();
}

ScopedAStatus HdmiConnection::setCallback(
        const std::shared_ptr<IHdmiConnectionCallback>& callback) {
    std::lock_guard<std::mutex> lock(callbackMutex_);
    callback_ = callback;
    return ScopedAStatus::ok();
}

// Only a TV panel with eARC TX switches HPD signals (IHdmiConnection.aidl).
ScopedAStatus HdmiConnection::setHpdSignal(HpdSignal signal, int32_t portId) {
    if (portId != kPortId) return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    if (signal != HpdSignal::HDMI_HPD_PHYSICAL)
        return ScopedAStatus::fromServiceSpecificError(
                static_cast<int32_t>(Result::FAILURE_NOT_SUPPORTED));
    return ScopedAStatus::ok();
}

ScopedAStatus HdmiConnection::getHpdSignal(int32_t portId, HpdSignal* _aidl_return) {
    if (portId != kPortId) return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    *_aidl_return = HpdSignal::HDMI_HPD_PHYSICAL;
    return ScopedAStatus::ok();
}

void HdmiConnection::onPhysicalAddress(uint16_t physicalAddress) {
    bool connected = physicalAddress != kInvalidPhysicalAddress;
    std::shared_ptr<IHdmiConnectionCallback> cb;
    {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        cb = callback_;
    }
    ALOGI("HDMI %s", connected ? "connected" : "disconnected");
    if (!cb) return;
    ScopedAStatus st = cb->onHotplugEvent(connected, kPortId);
    if (st.getStatus() == STATUS_DEAD_OBJECT) {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        if (callback_ == cb) callback_.reset();
    }
}

}  // namespace edge1
