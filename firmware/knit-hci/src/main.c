/*
 * A Bluetooth LE controller over USB for knit-peer: Zephyr's hci_usb sample, plus a public address.
 *
 * Zephyr's controller reports 00:00:00:00:00:00 as its public address and runs on a static random one. knit-peer
 * binds every socket to its adapter's public address, and the scripts find adapters by the address sysfs shows, so
 * each dongle reports its factory device address as public instead (.agents/context/linux-peer.md, "The adapter").
 */

#include <zephyr/bluetooth/controller.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/usb/usbd.h>

#include <hal/nrf_ficr.h>
#include <sample_usbd.h>

/* The 48-bit device address Nordic programs into each chip's FICR, least significant byte first, as HCI wants it.
 * An HCI Reset clears only the random address, so this one holds until the dongle loses power. */
static void set_public_address(void)
{
    uint32_t low = nrf_ficr_deviceaddr_get(NRF_FICR, 0);
    uint32_t high = nrf_ficr_deviceaddr_get(NRF_FICR, 1);
    uint8_t address[6] = {
        low & 0xff, (low >> 8) & 0xff, (low >> 16) & 0xff, (low >> 24) & 0xff, high & 0xff, (high >> 8) & 0xff,
    };

    bt_ctlr_set_public_addr(address);
}

int main(void)
{
    struct usbd_context *usbd;

    /* Before USB comes up, so the host's first Read BD_ADDR already sees it. */
    set_public_address();

    usbd = sample_usbd_init_device(NULL);
    if (usbd == NULL) {
        printk("Failed to initialize USB device\n");
        return -ENODEV;
    }
    if (usbd_enable(usbd) != 0) {
        printk("Failed to enable USB\n");
        return 0;
    }
    return 0;
}
