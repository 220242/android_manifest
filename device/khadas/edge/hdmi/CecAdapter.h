/*
 * Khadas Edge1 - the Linux CEC adapter (/dev/cec0) under the HDMI-CEC HAL.
 *
 * The RK3399's HDMI transmitter has a CEC controller, and mainline drives it with
 * dw-hdmi-cec, a standard Linux CEC adapter: messages go out with CEC_TRANSMIT,
 * come in with CEC_RECEIVE, and the logical addresses are claimed by the kernel
 * itself (CEC_ADAP_S_LOG_ADDRS). The physical address is not ours to set: the
 * HDMI bridge reads it from the TV's EDID and hands it to the adapter (the CEC
 * notifier), and takes it back (0xffff) when the cable comes out - so a change of
 * physical address is also how the HAL hears about hotplug.
 *
 * Nothing Android in here, so it builds and runs on a Linux host as well.
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

#include <atomic>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace edge1 {

constexpr uint16_t kInvalidPhysicalAddress = 0xffff;

class CecAdapter {
  public:
    enum class Tx { kOk, kNack, kBusy, kFail };

    // A message from another device: its initiator, its destination (one of
    // ours, or 15 for broadcast) and the opcode and operands.
    using MessageListener =
            std::function<void(uint8_t initiator, uint8_t destination, const std::vector<uint8_t>& body)>;
    // The physical address changed: a TV's EDID was read, or the cable came out
    // (kInvalidPhysicalAddress).
    using AddressListener = std::function<void(uint16_t physicalAddress)>;

    CecAdapter() = default;
    ~CecAdapter();
    CecAdapter(const CecAdapter&) = delete;
    CecAdapter& operator=(const CecAdapter&) = delete;

    // Opens the adapter as its initiator and exclusive follower in passthrough
    // mode - the kernel then leaves <Give Physical Address>, <Give OSD Name> and
    // the rest to the framework - and starts the thread that reads messages and
    // events. false: no adapter, or one that cannot claim addresses or transmit.
    bool open(const char* path);
    void close();
    bool isOpen() const { return fd_ >= 0; }

    void setMessageListener(MessageListener l);
    void setAddressListener(AddressListener l);

    // Claims the CEC logical address `address` (0-14) next to the ones already
    // claimed. The kernel does the claiming - it polls the address and moves to
    // the next free one of the same type if a device answers - so the address it
    // ends up with is returned in *claimed. 0 on success, else a negative errno:
    // -EBUSY when every slot the adapter has is used, -EINVAL for 15.
    int addLogicalAddress(uint8_t address, uint8_t* claimed);
    void clearLogicalAddresses();

    // Sends initiator->destination with `body` (empty: a poll). Blocks until the
    // message is acknowledged, refused, or the adapter gives up.
    Tx transmit(uint8_t initiator, uint8_t destination, const std::vector<uint8_t>& body);

    uint16_t physicalAddress();

    // The kernel's own replies use these; the framework reports its own.
    static constexpr int kCecVersion = 0x05;  // CEC 1.4 (CEC_OP_CEC_VERSION_1_4)

    // Type of a logical address, as CEC 1.4 table 5 assigns them (CEC_LOG_ADDR_TYPE_*),
    // or -1 for 15.
    static int addressType(uint8_t address);

  private:
    void loop();
    void readMessage();
    void readEvents();

    int fd_ = -1;
    int wake_[2] = {-1, -1};
    std::thread thread_;
    std::mutex listenerMutex_;
    std::mutex logAddrMutex_;  // S_LOG_ADDRS is a read-modify-write
    MessageListener onMessage_;
    AddressListener onAddress_;
    std::atomic<uint16_t> physicalAddress_{kInvalidPhysicalAddress};
};

}  // namespace edge1
