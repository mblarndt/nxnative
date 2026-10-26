// DSU (cemuhook) client packets for the Mac front end: iPhones that the Mac host of AstrisPad serves on 127.0.0.1:26760 (AstrisPhoneController's MacHost, or MacSwitch) become players, analog.
// Pure packet code, no sockets, so tests/t_dsu.c checks it without a server; front_mac.m owns the socket. Protocol: https://v1993.github.io/cemuhook-protocol/ , little endian, packets
// "DSUC" (client) and "DSUS" (server): magic[4], version u16 (1001), length u16 (bytes after the 16-byte header), crc32 u32 (over the whole packet with this field zero), id u32, type u32, payload.
// The face buttons are the inverse of that server's: a phone's Switch A arrives as 0x40 of the second button byte, B 0x20, X 0x80, Y 0x10 (it names them as an Xbox pad's, which Astris reads), so
// they come out as the phone's own buttons here. Another DSU source (a DualShock) would read by position instead; this client is for that server.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "dm_input.h"

#define DSU_PORT 26760
#define DSU_SLOTS 4            // the server has one slot per player (1 to 4)
#define DSU_REGISTER_LEN 28
#define DSU_DATA_LEN 100
#define DSU_TYPE_DATA 0x100002u

typedef struct { int slot, connected; uint32_t number; uint64_t buttons; int32_t lx, ly, rx, ry; } dsu_pad;

static uint32_t dsu_crc32(const uint8_t *p, size_t n) {
    uint32_t c = ~0u;
    for (size_t i = 0; i < n; i++) { c ^= p[i]; for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1; }
    return ~c;
}
static void dsu_put32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static uint32_t dsu_get32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

// The registration for the data of every slot (flags 0). The server forgets a client after 8 s of silence, so the front end sends it again every second; the answer comes at once.
static void dsu_register(uint8_t out[DSU_REGISTER_LEN], uint32_t client_id) {
    memset(out, 0, DSU_REGISTER_LEN);
    memcpy(out, "DSUC", 4); out[4] = 1001 & 255; out[5] = 1001 >> 8; out[6] = 12;   // length: type (4) + payload (8: flags, slot, MAC)
    dsu_put32(out + 12, client_id); dsu_put32(out + 16, DSU_TYPE_DATA);
    dsu_put32(out + 8, dsu_crc32(out, DSU_REGISTER_LEN));
}

// 0..255 around `mid` → ±DM_STICK_MAX. X rests at 128; the server sends Y as 255 - y (the phone counts down from the top, DSU up from the bottom), so Y rests at 127 and larger is up, as in dm_input.
static int32_t dsu_axis(uint8_t v, int mid) {
    int32_t a = ((int32_t)v - mid) * DM_STICK_MAX / 127;
    return a > DM_STICK_MAX ? DM_STICK_MAX : a < -DM_STICK_MAX ? -DM_STICK_MAX : a;
}

// A server's controller data packet → pad. 0 for anything else (magic, length, type or checksum wrong). A slot without a phone parses too (connected 0), which is how a disconnect arrives.
static int dsu_parse(const uint8_t *p, size_t n, dsu_pad *out) {
    if (n != DSU_DATA_LEN || memcmp(p, "DSUS", 4) || (size_t)(p[6] | p[7] << 8) != n - 16 || dsu_get32(p + 16) != DSU_TYPE_DATA) return 0;
    uint8_t z[DSU_DATA_LEN]; memcpy(z, p, n); memset(z + 8, 0, 4);
    if (dsu_crc32(z, n) != dsu_get32(p + 8)) return 0;
    const uint8_t *d = p + 20;   // slot, state, model, connection, MAC[6], battery, connected, packet number u32, buttons 1 and 2, home, touch, LX LY RX RY, ...
    if (d[0] >= DSU_SLOTS) return 0;
    uint8_t b1 = d[16], b2 = d[17];
    uint64_t m = 0;
    #define B(byte, mask, bit) if ((byte) & (mask)) m |= (bit)
    B(b1, 0x01, DM_BTN_MINUS); B(b1, 0x02, DM_BTN_LS); B(b1, 0x04, DM_BTN_RS); B(b1, 0x08, DM_BTN_PLUS);
    B(b1, 0x10, DM_BTN_UP); B(b1, 0x20, DM_BTN_RIGHT); B(b1, 0x40, DM_BTN_DOWN); B(b1, 0x80, DM_BTN_LEFT);
    B(b2, 0x01, DM_BTN_ZL); B(b2, 0x02, DM_BTN_ZR); B(b2, 0x04, DM_BTN_L); B(b2, 0x08, DM_BTN_R);
    B(b2, 0x10, DM_BTN_Y); B(b2, 0x20, DM_BTN_B); B(b2, 0x40, DM_BTN_A); B(b2, 0x80, DM_BTN_X);
    #undef B
    out->slot = d[0]; out->connected = d[11] != 0; out->number = dsu_get32(d + 12); out->buttons = m;
    out->lx = dsu_axis(d[20], 128); out->ly = dsu_axis(d[21], 127); out->rx = dsu_axis(d[22], 128); out->ry = dsu_axis(d[23], 127);
    return 1;
}
