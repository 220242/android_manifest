/*
 * Khadas Edge1 - the Linux CEC adapter (/dev/cec0) under the HDMI-CEC HAL.
 *
 * Written after AOSP's Linux-backed tv.cec@1.0 implementation
 * (hardware/interfaces/tv/cec/1.0/default/HdmiCecDefault.cpp, HdmiCecPort.cpp),
 * which Android 14 no longer builds for the AIDL HALs - their default services
 * are mocks that talk to FIFOs. Two things differ from it: CEC events are read on
 * POLLPRI, which is what the CEC core raises for them (cec-api.c, cec_poll), and
 * the playback address does not set CEC_LOG_ADDRS_FL_ALLOW_RC_PASSTHRU, so the
 * kernel never turns a remote button into an input event of its own - the
 * framework already injects one for every <User Control Pressed> it gets.
 */
#define LOG_TAG "edge1-hdmi"

#include "CecAdapter.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/cec.h>
#include <poll.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <algorithm>

#ifdef __ANDROID__
#include <log/log.h>
#else
#include <stdio.h>
#define ALOGI(...) (fprintf(stderr, "I " LOG_TAG ": " __VA_ARGS__), fputc('\n', stderr))
#define ALOGW(...) (fprintf(stderr, "W " LOG_TAG ": " __VA_ARGS__), fputc('\n', stderr))
#define ALOGE(...) (fprintf(stderr, "E " LOG_TAG ": " __VA_ARGS__), fputc('\n', stderr))
#endif

namespace edge1 {

namespace {

struct AddressKind {
    uint8_t logAddrType;
    uint8_t primaryDeviceType;
    uint8_t allDeviceTypes;
};

// CEC 1.4 table 5: which device type each logical address belongs to.
bool kindOf(uint8_t address, AddressKind* k) {
    switch (address) {
        case 0:
            *k = {CEC_LOG_ADDR_TYPE_TV, CEC_OP_PRIM_DEVTYPE_TV, CEC_OP_ALL_DEVTYPE_TV};
            return true;
        case 1: case 2: case 9:
            *k = {CEC_LOG_ADDR_TYPE_RECORD, CEC_OP_PRIM_DEVTYPE_RECORD, CEC_OP_ALL_DEVTYPE_RECORD};
            return true;
        case 3: case 6: case 7: case 10:
            *k = {CEC_LOG_ADDR_TYPE_TUNER, CEC_OP_PRIM_DEVTYPE_TUNER, CEC_OP_ALL_DEVTYPE_TUNER};
            return true;
        case 4: case 8: case 11:
            *k = {CEC_LOG_ADDR_TYPE_PLAYBACK, CEC_OP_PRIM_DEVTYPE_PLAYBACK,
                  CEC_OP_ALL_DEVTYPE_PLAYBACK};
            return true;
        case 5:
            *k = {CEC_LOG_ADDR_TYPE_AUDIOSYSTEM, CEC_OP_PRIM_DEVTYPE_AUDIOSYSTEM,
                  CEC_OP_ALL_DEVTYPE_AUDIOSYSTEM};
            return true;
        case 12: case 13: case 14:
            *k = {CEC_LOG_ADDR_TYPE_SPECIFIC, CEC_OP_PRIM_DEVTYPE_PROCESSOR,
                  CEC_OP_ALL_DEVTYPE_SWITCH};
            return true;
        default:
            return false;
    }
}

CecAdapter::Tx txResult(uint8_t status) {
    if (status & CEC_TX_STATUS_OK) return CecAdapter::Tx::kOk;
    if (status & CEC_TX_STATUS_NACK) return CecAdapter::Tx::kNack;
    if (status & CEC_TX_STATUS_ARB_LOST) return CecAdapter::Tx::kBusy;
    return CecAdapter::Tx::kFail;
}

}  // namespace

int CecAdapter::addressType(uint8_t address) {
    AddressKind k;
    return kindOf(address, &k) ? k.logAddrType : -1;
}

CecAdapter::~CecAdapter() {
    close();
}

bool CecAdapter::open(const char* path) {
    // Blocking: CEC_TRANSMIT on a non-blocking descriptor returns before the
    // message is on the bus and reports the result through CEC_RECEIVE instead.
    int fd = ::open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        ALOGE("%s: %s", path, strerror(errno));
        return false;
    }
    struct cec_caps caps = {};
    if (ioctl(fd, CEC_ADAP_G_CAPS, &caps)) {
        ALOGE("%s: CEC_ADAP_G_CAPS: %s", path, strerror(errno));
        ::close(fd);
        return false;
    }
    const uint32_t need = CEC_CAP_LOG_ADDRS | CEC_CAP_TRANSMIT | CEC_CAP_PASSTHROUGH;
    if ((caps.capabilities & need) != need) {
        ALOGE("%s: %s can claim no addresses or cannot transmit (capabilities 0x%x)", path,
              caps.driver, caps.capabilities);
        ::close(fd);
        return false;
    }
    uint32_t mode = CEC_MODE_INITIATOR | CEC_MODE_EXCL_FOLLOWER_PASSTHRU;
    if (ioctl(fd, CEC_S_MODE, &mode)) {
        ALOGE("%s: CEC_S_MODE: %s", path, strerror(errno));
        ::close(fd);
        return false;
    }
    if (pipe2(wake_, O_CLOEXEC | O_NONBLOCK)) {
        ALOGE("pipe2: %s", strerror(errno));
        ::close(fd);
        return false;
    }
    uint16_t pa = kInvalidPhysicalAddress;
    if (ioctl(fd, CEC_ADAP_G_PHYS_ADDR, &pa) == 0) physicalAddress_ = pa;
    fd_ = fd;
    ALOGI("%s: %s (%s), %u logical addresses, physical address %x.%x.%x.%x", path, caps.driver,
          caps.name, caps.available_log_addrs, pa >> 12, (pa >> 8) & 0xf, (pa >> 4) & 0xf,
          pa & 0xf);
    thread_ = std::thread(&CecAdapter::loop, this);
    return true;
}

void CecAdapter::close() {
    if (thread_.joinable()) {
        char c = 1;
        (void)!write(wake_[1], &c, 1);
        thread_.join();
    }
    for (int& fd : wake_) {
        if (fd >= 0) ::close(fd);
        fd = -1;
    }
    if (fd_ >= 0) ::close(fd_);
    fd_ = -1;
}

void CecAdapter::setMessageListener(MessageListener l) {
    std::lock_guard<std::mutex> lock(listenerMutex_);
    onMessage_ = std::move(l);
}

void CecAdapter::setAddressListener(AddressListener l) {
    std::lock_guard<std::mutex> lock(listenerMutex_);
    onAddress_ = std::move(l);
}

int CecAdapter::addLogicalAddress(uint8_t address, uint8_t* claimed) {
    AddressKind kind;
    if (!kindOf(address, &kind)) return -EINVAL;
    if (fd_ < 0) return -ENODEV;
    std::lock_guard<std::mutex> lock(logAddrMutex_);
    struct cec_log_addrs la = {};
    if (ioctl(fd_, CEC_ADAP_G_LOG_ADDRS, &la)) return -errno;
    struct cec_caps caps = {};
    if (ioctl(fd_, CEC_ADAP_G_CAPS, &caps)) return -errno;
    for (unsigned i = 0; i < la.num_log_addrs; i++) {
        if (la.log_addr[i] == address) {
            *claimed = address;
            return 0;
        }
    }
    if (la.num_log_addrs >= caps.available_log_addrs || la.num_log_addrs >= CEC_MAX_LOG_ADDRS)
        return -EBUSY;
    // The kernel takes a new set only while it holds none: clear, then claim
    // everything again (cec-adap.c, __cec_s_log_addrs).
    if (la.num_log_addrs > 0) {
        struct cec_log_addrs none = {};
        if (ioctl(fd_, CEC_ADAP_S_LOG_ADDRS, &none)) return -errno;
    }
    unsigned i = la.num_log_addrs++;
    la.cec_version = kCecVersion;
    // No vendor ID: the kernel would broadcast <Device Vendor ID> itself after
    // claiming, and the framework sends its own.
    la.vendor_id = CEC_VENDOR_ID_NONE;
    la.flags = 0;
    la.log_addr[i] = address;
    la.log_addr_type[i] = kind.logAddrType;
    la.primary_device_type[i] = kind.primaryDeviceType;
    la.all_device_types[i] = kind.allDeviceTypes;
    memset(la.features[i], 0, sizeof(la.features[i]));
    // Blocks while the kernel polls the addresses, unless there is no physical
    // address yet (no TV): then it claims them once the TV's EDID has been read.
    if (ioctl(fd_, CEC_ADAP_S_LOG_ADDRS, &la)) {
        int err = errno;
        ALOGE("CEC_ADAP_S_LOG_ADDRS (%u addresses, adding %u): %s", la.num_log_addrs, address,
              strerror(err));
        return -err;
    }
    // The kernel moves on to the next free address of the type when one is taken.
    *claimed = la.log_addr[i] == CEC_LOG_ADDR_INVALID ? address : la.log_addr[i];
    if (*claimed != address)
        ALOGW("logical address %u was taken; the kernel claimed %u", address, *claimed);
    else
        ALOGI("logical address %u%s", address,
              la.log_addr[i] == CEC_LOG_ADDR_INVALID ? " (claimed once a TV is connected)" : "");
    return 0;
}

void CecAdapter::clearLogicalAddresses() {
    if (fd_ < 0) return;
    std::lock_guard<std::mutex> lock(logAddrMutex_);
    struct cec_log_addrs none = {};
    if (ioctl(fd_, CEC_ADAP_S_LOG_ADDRS, &none)) ALOGE("clearing: %s", strerror(errno));
}

CecAdapter::Tx CecAdapter::transmit(uint8_t initiator, uint8_t destination,
                                    const std::vector<uint8_t>& body) {
    if (fd_ < 0) return Tx::kFail;
    if (body.size() > CEC_MAX_MSG_SIZE - 1 || initiator > 15 || destination > 15) return Tx::kFail;
    struct cec_msg msg = {};
    msg.msg[0] = static_cast<uint8_t>(initiator << 4 | destination);
    memcpy(msg.msg + 1, body.data(), body.size());
    msg.len = static_cast<uint32_t>(body.size() + 1);
    // The core retries a NACKed or lost frame itself (CEC 1.4b 7.1) and gives up
    // within about a second when the line is held low, so this returns.
    if (ioctl(fd_, CEC_TRANSMIT, &msg)) {
        // A poll before any address is claimed (the framework polls to find a
        // free one) is refused with ENONET; nobody answered it either.
        if (errno != ENONET)
            ALOGW("transmit %02x %02x (%zu bytes): %s", msg.msg[0], body.empty() ? 0 : body[0],
                  body.size(), strerror(errno));
        return Tx::kFail;
    }
    return txResult(msg.tx_status);
}

uint16_t CecAdapter::physicalAddress() {
    uint16_t pa = kInvalidPhysicalAddress;
    if (fd_ >= 0 && ioctl(fd_, CEC_ADAP_G_PHYS_ADDR, &pa) == 0) physicalAddress_ = pa;
    return physicalAddress_;
}

void CecAdapter::loop() {
    struct pollfd fds[2] = {
            {fd_, POLLIN | POLLPRI, 0},
            {wake_[0], POLLIN, 0},
    };
    for (;;) {
        int n = poll(fds, 2, -1);
        if (n < 0) {
            if (errno == EINTR) continue;
            ALOGE("poll: %s", strerror(errno));
            return;
        }
        if (fds[1].revents) return;
        if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
            // The adapter went away (cec_poll returns these once unregistered).
            ALOGE("the CEC adapter is gone (revents 0x%x)", fds[0].revents);
            return;
        }
        if (fds[0].revents & POLLPRI) readEvents();
        if (fds[0].revents & POLLIN) readMessage();
    }
}

void CecAdapter::readEvents() {
    struct cec_event ev = {};
    // Blocking descriptor: POLLPRI says at least one is queued; take one per wakeup.
    if (ioctl(fd_, CEC_DQEVENT, &ev)) {
        if (errno != EAGAIN) ALOGE("CEC_DQEVENT: %s", strerror(errno));
        return;
    }
    if (ev.event == CEC_EVENT_LOST_MSGS) {
        ALOGW("%u received messages lost (the reader fell behind)", ev.lost_msgs.lost_msgs);
        return;
    }
    if (ev.event != CEC_EVENT_STATE_CHANGE) return;
    uint16_t pa = ev.state_change.phys_addr;
    uint16_t old = physicalAddress_.exchange(pa);
    ALOGI("physical address %x.%x.%x.%x, logical addresses 0x%04x", pa >> 12, (pa >> 8) & 0xf,
          (pa >> 4) & 0xf, pa & 0xf, ev.state_change.log_addr_mask);
    // The first event after open() repeats the current state; a change of
    // logical addresses alone is not a hotplug.
    if (pa == old && !(ev.flags & CEC_EVENT_FL_INITIAL_STATE)) return;
    std::lock_guard<std::mutex> lock(listenerMutex_);
    if (onAddress_) onAddress_(pa);
}

void CecAdapter::readMessage() {
    struct cec_msg msg = {};
    if (ioctl(fd_, CEC_RECEIVE, &msg)) {
        if (errno != EAGAIN) ALOGE("CEC_RECEIVE: %s", strerror(errno));
        return;
    }
    // A transmit result would carry tx_status; blocking transmits never queue one.
    if (msg.len < 1 || !(msg.rx_status & CEC_RX_STATUS_OK) || msg.sequence) return;
    std::vector<uint8_t> body(msg.msg + 1, msg.msg + std::min<uint32_t>(msg.len, CEC_MAX_MSG_SIZE));
    std::lock_guard<std::mutex> lock(listenerMutex_);
    if (onMessage_) onMessage_(msg.msg[0] >> 4, msg.msg[0] & 0xf, body);
}

}  // namespace edge1
