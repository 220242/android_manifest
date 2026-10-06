/*
 * Khadas Edge1 - the HDMI-CEC and HDMI connection HALs in one process, around one
 * /dev/cec0: both need the adapter's events (connection: the physical address;
 * CEC: the messages), and the kernel hands each event to every open descriptor,
 * so one reader serves both.
 *
 * Both services are registered even without an adapter (no /dev/cec0: a kernel
 * without dw-hdmi-cec): the device manifest declares them, and the framework would
 * otherwise wait for them forever. They then report no CEC support and no TV. The
 * same happens on purpose with cec=0 in edge1-options.txt, which boot.scr passes
 * as androidboot.edge1.cec=0.
 */
#define LOG_TAG "edge1-hdmi"

#include <android-base/properties.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <log/log.h>

#include "CecAdapter.h"
#include "HdmiCec.h"
#include "HdmiConnection.h"

using edge1::CecAdapter;
using edge1::HdmiCec;
using edge1::HdmiConnection;

int main() {
    ABinderProcess_setThreadPoolMaxThreadCount(2);
    ABinderProcess_startThreadPool();

    static CecAdapter adapter;
    auto cec = ndk::SharedRefBase::make<HdmiCec>(adapter);
    auto connection = ndk::SharedRefBase::make<HdmiConnection>(adapter);
    adapter.setMessageListener([cec](uint8_t initiator, uint8_t destination,
                                     const std::vector<uint8_t>& body) {
        cec->onMessage(initiator, destination, body);
    });
    adapter.setAddressListener(
            [connection](uint16_t physicalAddress) { connection->onPhysicalAddress(physicalAddress); });
    if (::android::base::GetProperty("ro.boot.edge1.cec", "1") == "0")
        ALOGI("cec=0 in edge1-options.txt: the CEC bus is left alone");
    else if (!adapter.open("/dev/cec0"))
        ALOGE("no CEC adapter: CEC is off, HDMI reads as unplugged");

    const std::string cecName = std::string(HdmiCec::descriptor) + "/default";
    const std::string connectionName = std::string(HdmiConnection::descriptor) + "/default";
    if (AServiceManager_addService(cec->asBinder().get(), cecName.c_str()) != STATUS_OK ||
        AServiceManager_addService(connection->asBinder().get(), connectionName.c_str()) !=
                STATUS_OK) {
        ALOGE("could not register %s and %s", cecName.c_str(), connectionName.c_str());
        return 1;
    }
    ABinderProcess_joinThreadPool();
    return 1;  // joinThreadPool does not return
}
