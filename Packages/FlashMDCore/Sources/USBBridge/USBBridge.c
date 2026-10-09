#include "USBBridge.h"
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

struct FMUSB { IOUSBDeviceInterface **device; IOUSBInterfaceInterface190 **interface; UInt8 input; UInt8 output; };
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
static io_iterator_t devices(void) {
    io_iterator_t iterator = 0;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOUSBDeviceClassName), &iterator);
    return iterator;
}
static uint32_t property(io_service_t service, CFStringRef key) {
    uint32_t value = 0;
    CFTypeRef number = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (number) {
        if (CFGetTypeID(number) == CFNumberGetTypeID()) CFNumberGetValue(number, kCFNumberSInt32Type, &value);
        CFRelease(number);
    }
    return value;
}
static int matches(io_service_t service, uint32_t *location) {
    *location = property(service, CFSTR("locationID"));
    return property(service, CFSTR("idVendor")) == 0x0483 && property(service, CFSTR("idProduct")) == 0x5740;
}
static IOUSBDeviceInterface **get_device(io_service_t service) {
    IOCFPlugInInterface **plugin = NULL;
    IOUSBDeviceInterface **device = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
            kIOCFPlugInInterfaceID, &plugin, &score) == kIOReturnSuccess) {
        (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&device);
        IODestroyPlugInInterface(plugin);
    }
    return device;
}
size_t fm_usb_discover(uint32_t *locations, size_t capacity) {
    io_iterator_t iterator = devices();
    if (!iterator) return 0;
    size_t count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        uint32_t location = 0;
        if (matches(service, &location)) { if (count < capacity) locations[count] = location; count++; }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return count;
}
FMUSB *fm_usb_open(uint32_t location, int32_t *error) {
    *error = kIOReturnNoDevice;
    io_iterator_t iterator = devices();
    if (!iterator) return NULL;
    IOUSBDeviceInterface **usb = NULL;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        uint32_t candidate = 0;
        if (matches(service, &candidate) && candidate == location) usb = get_device(service);
        IOObjectRelease(service);
        if (usb) break;
    }
    IOObjectRelease(iterator);
    if (!usb) return NULL;
    *error = (*usb)->USBDeviceOpen(usb);
    if (*error != kIOReturnSuccess) { (*usb)->Release(usb); return NULL; }

    // A newly attached STM32 can remain unconfigured. Select its advertised USB
    // configuration before enumerating interfaces. Some boards use interface 1.
    UInt8 configuration = 0;
    *error = (*usb)->GetConfiguration(usb, &configuration);
    if (*error == kIOReturnSuccess && configuration == 0) {
        IOUSBConfigurationDescriptorPtr descriptor = NULL;
        *error = (*usb)->GetConfigurationDescriptorPtr(usb, 0, &descriptor);
        if (*error == kIOReturnSuccess && descriptor && descriptor->bConfigurationValue != 0)
            *error = (*usb)->SetConfiguration(usb, descriptor->bConfigurationValue);
        else if (*error == kIOReturnSuccess) *error = kIOReturnUnsupported;
    }
    if (*error != kIOReturnSuccess) { (*usb)->USBDeviceClose(usb); (*usb)->Release(usb); return NULL; }

    IOUSBFindInterfaceRequest request = { kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
        kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare };
    iterator = 0;
    *error = (*usb)->CreateInterfaceIterator(usb, &request, &iterator);
    FMUSB *device = NULL;
    if (*error == kIOReturnSuccess) {
        *error = kIOReturnUnsupported;
        while ((service = IOIteratorNext(iterator))) {
            IOUSBInterfaceInterface190 **interface = get_interface(service);
            IOObjectRelease(service);
            if (!interface) continue;
            UInt8 number = 255;
            IOReturn status = (*interface)->GetInterfaceNumber(interface, &number);
            if (status == kIOReturnSuccess && number <= 1) {
                *error = (*interface)->USBInterfaceOpen(interface);
                if (*error == kIOReturnSuccess) {
                    UInt8 endpoints = 0, input = 0, output = 0;
                    (*interface)->GetNumEndpoints(interface, &endpoints);
                    for (UInt8 pipe = 1; pipe <= endpoints; pipe++) {
                        UInt8 direction, endpoint, type, interval; UInt16 packet;
                        if ((*interface)->GetPipeProperties(interface, pipe, &direction, &endpoint, &type, &packet, &interval) == kIOReturnSuccess && type == kUSBBulk) {
                            if (direction == kUSBIn && endpoint == 2) input = pipe;
                            if (direction == kUSBOut && endpoint == 1) output = pipe;
                        }
                    }
                    if (input && output) {
                        device = calloc(1, sizeof(FMUSB));
                        if (device) { device->device = usb; device->interface = interface; device->input = input; device->output = output; }
                        else *error = kIOReturnNoMemory;
                    } else *error = kIOReturnUnsupported;
                    if (!device) (*interface)->USBInterfaceClose(interface);
                }
            }
            if (device) break;
            (*interface)->Release(interface);
        }
        IOObjectRelease(iterator);
    }
    if (!device) { (*usb)->USBDeviceClose(usb); (*usb)->Release(usb); }
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
    (*device->device)->USBDeviceClose(device->device);
    (*device->device)->Release(device->device);
    free(device);
}
