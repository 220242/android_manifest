/*
 * Khadas Edge1 - android.hardware.tv.hdmi.cec IHdmiCec over the Linux CEC adapter.
 *
 * The framework (HdmiControlService, a playback device here: ro.hdmi.device_type=4)
 * picks a logical address by polling, hands it over with addLogicalAddress, and
 * from then on sends and answers every message itself; this side moves them
 * between it and /dev/cec0. What the HAL decides on its own is only what reaches
 * the framework while it sleeps (enableSystemCecControl(false)) - the same filter
 * as AOSP's HdmiCecDefault.
 */
#define LOG_TAG "edge1-hdmi"

#include "HdmiCec.h"

#include <linux/cec.h>
#include <log/log.h>

namespace edge1 {

using ::ndk::ScopedAStatus;

namespace {

bool isWakeupMessage(const std::vector<uint8_t>& body) {
    return !body.empty() && (body[0] == CEC_MSG_TEXT_VIEW_ON || body[0] == CEC_MSG_IMAGE_VIEW_ON);
}

// What the framework still wants to hear while the system is asleep.
bool isTransferableInSleep(const std::vector<uint8_t>& body) {
    if (body.empty()) return false;
    switch (body[0]) {
        case CEC_MSG_ABORT:
        case CEC_MSG_DEVICE_VENDOR_ID:
        case CEC_MSG_GET_CEC_VERSION:
        case CEC_MSG_GET_MENU_LANGUAGE:
        case CEC_MSG_GIVE_DEVICE_POWER_STATUS:
        case CEC_MSG_GIVE_DEVICE_VENDOR_ID:
        case CEC_MSG_GIVE_OSD_NAME:
        case CEC_MSG_GIVE_PHYSICAL_ADDR:
        case CEC_MSG_REPORT_PHYSICAL_ADDR:
        case CEC_MSG_REPORT_POWER_STATUS:
        case CEC_MSG_SET_OSD_NAME:
        case CEC_MSG_DECK_CONTROL:
        case CEC_MSG_PLAY:
        case CEC_MSG_IMAGE_VIEW_ON:
        case CEC_MSG_TEXT_VIEW_ON:
        case CEC_MSG_SYSTEM_AUDIO_MODE_REQUEST:
            return true;
        case CEC_MSG_USER_CONTROL_PRESSED:
            return body.size() > 1 && (body[1] == CEC_OP_UI_CMD_POWER ||
                                       body[1] == CEC_OP_UI_CMD_DEVICE_ROOT_MENU ||
                                       body[1] == CEC_OP_UI_CMD_POWER_ON_FUNCTION);
        default:
            return false;
    }
}

}  // namespace

HdmiCec::HdmiCec(CecAdapter& adapter) : adapter_(adapter) {}

ScopedAStatus HdmiCec::addLogicalAddress(CecLogicalAddress addr, Result* _aidl_return) {
    uint8_t want = static_cast<uint8_t>(addr);
    if (want >= static_cast<uint8_t>(CecLogicalAddress::BROADCAST)) {
        *_aidl_return = Result::FAILURE_INVALID_ARGS;
        return ScopedAStatus::ok();
    }
    if (!adapter_.isOpen()) {
        *_aidl_return = Result::FAILURE_NOT_SUPPORTED;
        return ScopedAStatus::ok();
    }
    uint8_t claimed = want;
    int err = adapter_.addLogicalAddress(want, &claimed);
    *_aidl_return = err == 0         ? Result::SUCCESS
                    : err == -EINVAL ? Result::FAILURE_INVALID_ARGS
                    : err == -EBUSY  ? Result::FAILURE_BUSY
                                     : Result::FAILURE_UNKNOWN;
    return ScopedAStatus::ok();
}

ScopedAStatus HdmiCec::clearLogicalAddress() {
    adapter_.clearLogicalAddresses();
    return ScopedAStatus::ok();
}

ScopedAStatus HdmiCec::enableAudioReturnChannel(int32_t /*portId*/, bool /*enable*/) {
    // An HDMI output has no ARC to switch: ARC flows from the TV to an audio system.
    return ScopedAStatus::ok();
}

ScopedAStatus HdmiCec::getCecVersion(int32_t* _aidl_return) {
    *_aidl_return = CecAdapter::kCecVersion;
    return ScopedAStatus::ok();
}

ScopedAStatus HdmiCec::getPhysicalAddress(int32_t* _aidl_return) {
    *_aidl_return = adapter_.physicalAddress();
    return ScopedAStatus::ok();
}

ScopedAStatus HdmiCec::getVendorId(int32_t* _aidl_return) {
    // HDMI Licensing's OUI, HdmiCecDefault's default: this board has none of its own.
    *_aidl_return = 0x000c03;
    return ScopedAStatus::ok();
}

ScopedAStatus HdmiCec::sendMessage(const CecMessage& message, SendMessageResult* _aidl_return) {
    if (!cecEnabled_) {
        *_aidl_return = SendMessageResult::FAIL;
        return ScopedAStatus::ok();
    }
    std::vector<uint8_t> body(message.body.begin(), message.body.end());
    switch (adapter_.transmit(static_cast<uint8_t>(message.initiator),
                              static_cast<uint8_t>(message.destination), body)) {
        case CecAdapter::Tx::kOk:
            *_aidl_return = SendMessageResult::SUCCESS;
            break;
        case CecAdapter::Tx::kNack:
            *_aidl_return = SendMessageResult::NACK;
            break;
        case CecAdapter::Tx::kBusy:
            *_aidl_return = SendMessageResult::BUSY;
            break;
        case CecAdapter::Tx::kFail:
            *_aidl_return = SendMessageResult::FAIL;
            break;
    }
    return ScopedAStatus::ok();
}

ScopedAStatus HdmiCec::setCallback(const std::shared_ptr<IHdmiCecCallback>& callback) {
    std::lock_guard<std::mutex> lock(callbackMutex_);
    callback_ = callback;
    return ScopedAStatus::ok();
}

ScopedAStatus HdmiCec::setLanguage(const std::string& /*language*/) {
    // Only a TV answers <Get Menu Language>.
    return ScopedAStatus::ok();
}

ScopedAStatus HdmiCec::enableWakeupByOtp(bool value) {
    wakeupEnabled_ = value;
    return ScopedAStatus::ok();
}

ScopedAStatus HdmiCec::enableCec(bool value) {
    ALOGI("CEC %s", value ? "enabled" : "disabled");
    cecEnabled_ = value;
    return ScopedAStatus::ok();
}

ScopedAStatus HdmiCec::enableSystemCecControl(bool value) {
    systemControl_ = value;
    return ScopedAStatus::ok();
}

void HdmiCec::onMessage(uint8_t initiator, uint8_t destination, const std::vector<uint8_t>& body) {
    if (!cecEnabled_) return;
    if (!wakeupEnabled_ && isWakeupMessage(body)) return;
    if (!systemControl_ && !isTransferableInSleep(body)) return;
    std::shared_ptr<IHdmiCecCallback> cb;
    {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        cb = callback_;
    }
    if (!cb) return;
    CecMessage m;
    m.initiator = static_cast<CecLogicalAddress>(initiator);
    m.destination = static_cast<CecLogicalAddress>(destination);
    m.body.assign(body.begin(), body.end());
    ScopedAStatus st = cb->onCecMessage(m);
    if (st.getStatus() == STATUS_DEAD_OBJECT) {
        // system_server went away; it sets a new callback when it is back.
        std::lock_guard<std::mutex> lock(callbackMutex_);
        if (callback_ == cb) callback_.reset();
    }
}

}  // namespace edge1
