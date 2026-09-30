#include "USBBridge.h"
#include <stdlib.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

struct FMUSB { IOUSBInterfaceInterface190 **interface; UInt8 input; UInt8 output; };
static IOUSBInterfaceInterface190 **get_interface(io_service_t service) {
    IOCFPlugInInterface **plugin = NULL;
    IOUSBInterfaceInterface190 **interface = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID,
            kIOCFPlugInInterfaceID, &plugin, &score) == kIOReturnSuccess) {
        (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID190), (LPVOID *)&interface);
        IODestroyPlugInInterface(plugin);
    }
    return interface;
}
static io_iterator_t interfaces(void) {
    io_iterator_t iterator = 0;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOUSBInterfaceClassName), &iterator);
    return iterator;
}
static int matches(IOUSBInterfaceInterface190 **interface, uint32_t *location) {
    UInt16 vendor = 0, product = 0;
    UInt8 number = 255;
    if ((*interface)->GetDeviceVendor(interface, &vendor) || (*interface)->GetDeviceProduct(interface, &product) ||
        (*interface)->GetInterfaceNumber(interface, &number) || (*interface)->GetLocationID(interface, location)) return 0;
    return vendor == 0x0483 && product == 0x5740 && number == 0;
}
size_t fm_usb_discover(uint32_t *locations, size_t capacity) {
    io_iterator_t iterator = interfaces();
    if (!iterator) return 0;
    size_t count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        IOUSBInterfaceInterface190 **interface = get_interface(service);
        uint32_t location = 0;
        if (interface) {
            if (matches(interface, &location)) { if (count < capacity) locations[count] = location; count++; }
            (*interface)->Release(interface);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return count;
}
FMUSB *fm_usb_open(uint32_t location, int32_t *error) {
    *error = kIOReturnNoDevice;
    io_iterator_t iterator = interfaces();
    if (!iterator) return NULL;
    FMUSB *device = NULL;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        IOUSBInterfaceInterface190 **interface = get_interface(service);
        uint32_t candidate = 0;
        if (interface && matches(interface, &candidate) && candidate == location) {
            *error = (*interface)->USBInterfaceOpen(interface);
            if (*error == kIOReturnSuccess) {
                UInt8 endpoints = 0, input = 0, output = 0;
                (*interface)->GetNumEndpoints(interface, &endpoints);
                for (UInt8 pipe = 1; pipe <= endpoints; pipe++) {
                    UInt8 direction, number, type, interval; UInt16 packet;
                    if ((*interface)->GetPipeProperties(interface, pipe, &direction, &number, &type, &packet, &interval) == kIOReturnSuccess && type == kUSBBulk) {
                        if (direction == kUSBIn && number == 2) input = pipe;
                        if (direction == kUSBOut && number == 1) output = pipe;
                    }
                }
                if (input && output) {
                    device = calloc(1, sizeof(FMUSB));
                    if (device) { device->interface = interface; device->input = input; device->output = output; }
                    else *error = kIOReturnNoMemory;
                } else *error = kIOReturnUnsupported;
                if (!device) (*interface)->USBInterfaceClose(interface);
            }
        }
        if (interface && !device) (*interface)->Release(interface);
        IOObjectRelease(service);
        if (device) break;
    }
    IOObjectRelease(iterator);
    return device;
}
int32_t fm_usb_write(FMUSB *device, const uint8_t *bytes, uint32_t count, uint32_t timeout) {
    if (!device) return kIOReturnNoDevice;
    return (*device->interface)->WritePipeTO(device->interface, device->output, (void *)bytes, count, timeout, timeout);
}
int32_t fm_usb_read(FMUSB *device, uint8_t *bytes, uint32_t *count, uint32_t timeout) {
    if (!device) return kIOReturnNoDevice;
    return (*device->interface)->ReadPipeTO(device->interface, device->input, bytes, count, timeout, timeout);
}
void fm_usb_close(FMUSB *device) {
    if (!device) return;
    (*device->interface)->USBInterfaceClose(device->interface);
    (*device->interface)->Release(device->interface);
    free(device);
}
