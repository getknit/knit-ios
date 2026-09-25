// The few BlueZ socket definitions KnitBlueZ needs, written out from the kernel ABI so the build does not
// depend on libbluetooth-dev. Linux only; empty elsewhere. Spike (e) checked them against hci1 on
// 2026-09-25 (.agents/context/linux-peer.md): the address size, the LE address type, a dynamic PSM at
// BT_SECURITY_LOW, and BT_MODE reading back LE flow control.
#ifndef KNIT_BLUETOOTH_SHIM_H
#define KNIT_BLUETOOTH_SHIM_H

#ifdef __linux__
#include <stdint.h>
#include <sys/socket.h>

#define KNIT_BTPROTO_L2CAP 0
#define KNIT_SOL_BLUETOOTH 274

#define KNIT_BDADDR_BREDR 0x00
#define KNIT_BDADDR_LE_PUBLIC 0x01
#define KNIT_BDADDR_LE_RANDOM 0x02

#define KNIT_BT_SECURITY 4
#define KNIT_BT_SECURITY_LOW 1
#define KNIT_BT_SNDMTU 12
#define KNIT_BT_RCVMTU 13
#define KNIT_BT_MODE 15
#define KNIT_BT_MODE_LE_FLOWCTL 0x03

typedef struct {
    uint8_t b[6];
} __attribute__((packed)) knit_bdaddr_t;

struct knit_sockaddr_l2 {
    sa_family_t l2_family;
    unsigned short l2_psm;
    knit_bdaddr_t l2_bdaddr;
    unsigned short l2_cid;
    uint8_t l2_bdaddr_type;
};

struct knit_bt_security {
    uint8_t level;
    uint8_t key_size;
};
#endif

#endif
