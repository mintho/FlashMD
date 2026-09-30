#ifndef FLASHMD_USB_BRIDGE_H
#define FLASHMD_USB_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
typedef struct FMUSB FMUSB;
// Only enumerates matching USB interfaces; discovery never sends device commands.
size_t fm_usb_discover(uint32_t *locations, size_t capacity);
FMUSB *fm_usb_open(uint32_t location, int32_t *error);
int32_t fm_usb_write(FMUSB *device, const uint8_t *bytes, uint32_t count, uint32_t timeout);
int32_t fm_usb_read(FMUSB *device, uint8_t *bytes, uint32_t *count, uint32_t timeout);
void fm_usb_close(FMUSB *device);
#endif
