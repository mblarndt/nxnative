// DSU client packets (dsu_pad.h, GitHub: AstrisPad's Mac host serves phones as controllers): the registration the front end sends and the controller data it reads back.
// The server packets are built here as AstrisPhoneController's MacHost/DSUServer.swift builds them (payload layout, checksum), so a change on either side shows up as a failed check.
#include <stdio.h>
#include "../dsu_pad.h"

static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); } } while (0)

// A server data packet for `slot`: connected phone or not, packet number, the two button bytes, the four axes as the server sends them (0..255: X rests at 128, Y at 127, up = 255)
static void server_packet(uint8_t p[DSU_DATA_LEN], int slot, int connected, uint32_t number, uint8_t b1, uint8_t b2, const uint8_t axes[4]) {
    memset(p, 0, DSU_DATA_LEN);
    memcpy(p, "DSUS", 4); p[4] = 1001 & 255; p[5] = 1001 >> 8; p[6] = DSU_DATA_LEN - 16;
    dsu_put32(p + 12, 0x1234); dsu_put32(p + 16, DSU_TYPE_DATA);
    uint8_t *d = p + 20;
    d[0] = slot; d[1] = connected ? 2 : 0; d[2] = connected ? 1 : 0; d[3] = connected ? 2 : 0; d[9] = slot + 1; d[10] = connected ? 5 : 0;
    d[11] = connected; dsu_put32(d + 12, number); d[16] = b1; d[17] = b2;
    memcpy(d + 20, axes, 4);
    dsu_put32(p + 8, dsu_crc32(p, DSU_DATA_LEN));
}

int main(void) {
    CHECK(dsu_crc32((const uint8_t *)"123456789", 9) == 0xCBF43926u, "CRC-32 check value");

    uint8_t reg[DSU_REGISTER_LEN]; dsu_register(reg, 0xABCD);
    CHECK(!memcmp(reg, "DSUC", 4) && reg[4] == 0xE9 && reg[5] == 0x03 && reg[6] == 12 && reg[7] == 0, "registration: magic, version 1001, length 12");
    CHECK(dsu_get32(reg + 12) == 0xABCD && dsu_get32(reg + 16) == DSU_TYPE_DATA && reg[20] == 0, "registration: client id, data request, all slots");
    uint8_t z[DSU_REGISTER_LEN]; memcpy(z, reg, sizeof z); memset(z + 8, 0, 4);
    CHECK(dsu_crc32(z, sizeof z) == dsu_get32(reg + 8), "registration: checksum over the packet with its field zero");
    static const uint8_t known[DSU_REGISTER_LEN] = {0x44,0x53,0x55,0x43,0xe9,0x03,0x0c,0x00,0x1c,0xc2,0x2c,0x74,0xcd,0xab,0,0,0x02,0,0x10,0, 0,0,0,0,0,0,0,0};
    CHECK(!memcmp(reg, known, sizeof known), "registration: the bytes MacSwitch's DSUServer test also parses");

    const uint8_t mid[4] = {128, 127, 128, 127};   // a phone's sticks at rest (Y is sent as 255 - 128)
    uint8_t p[DSU_DATA_LEN]; dsu_pad d;
    server_packet(p, 2, 1, 77, 0, 0, mid);
    CHECK(dsu_parse(p, sizeof p, &d) && d.slot == 2 && d.connected && d.number == 77 && d.buttons == 0 && !d.lx && !d.ly && !d.rx && !d.ry, "a connected phone at rest");

    // every bit of both button bytes and nothing else: the phone's own buttons, the inverse of the server's mapping
    static const struct { int byte; uint8_t mask; uint64_t bit; const char *name; } map[] = {
        {1, 0x01, DM_BTN_MINUS, "-"}, {1, 0x02, DM_BTN_LS, "L3"}, {1, 0x04, DM_BTN_RS, "R3"}, {1, 0x08, DM_BTN_PLUS, "+"},
        {1, 0x10, DM_BTN_UP, "up"}, {1, 0x20, DM_BTN_RIGHT, "right"}, {1, 0x40, DM_BTN_DOWN, "down"}, {1, 0x80, DM_BTN_LEFT, "left"},
        {2, 0x01, DM_BTN_ZL, "ZL"}, {2, 0x02, DM_BTN_ZR, "ZR"}, {2, 0x04, DM_BTN_L, "L"}, {2, 0x08, DM_BTN_R, "R"},
        {2, 0x10, DM_BTN_Y, "Y"}, {2, 0x20, DM_BTN_B, "B"}, {2, 0x40, DM_BTN_A, "A"}, {2, 0x80, DM_BTN_X, "X"},
    };
    uint64_t all = 0;
    for (size_t i = 0; i < sizeof map / sizeof *map; i++) {
        server_packet(p, 0, 1, 1, map[i].byte == 1 ? map[i].mask : 0, map[i].byte == 2 ? map[i].mask : 0, mid);
        char msg[64]; snprintf(msg, sizeof msg, "button %s alone", map[i].name);
        CHECK(dsu_parse(p, sizeof p, &d) && d.buttons == map[i].bit, msg);
        all |= map[i].bit;
    }
    CHECK(all == 0xFFFF, "the sixteen buttons are the sixteen NpadButton bits");
    server_packet(p, 0, 1, 1, 0xFF, 0xFF, mid);
    CHECK(dsu_parse(p, sizeof p, &d) && d.buttons == 0xFFFF, "all together");

    // axes: X rests at 128, Y at 127; full deflection is ±32767, up is positive
    const uint8_t full[4] = {255, 255, 0, 0}, part[4] = {192, 64, 128, 255};   // lx right by half, ly down by half, rx rests, ry full up
    server_packet(p, 1, 1, 1, 0, 0, full);
    CHECK(dsu_parse(p, sizeof p, &d) && d.lx == DM_STICK_MAX && d.ly == DM_STICK_MAX && d.rx == -DM_STICK_MAX && d.ry == -DM_STICK_MAX, "sticks at full deflection");
    server_packet(p, 1, 1, 1, 0, 0, part);
    CHECK(dsu_parse(p, sizeof p, &d) && d.lx > 16000 && d.lx < 17000 && d.ly < -16000 && d.ly > -17000 && d.rx == 0 && d.ry == DM_STICK_MAX, "half deflection and the middle");

    server_packet(p, 3, 0, 9, 0xFF, 0xFF, full);
    CHECK(dsu_parse(p, sizeof p, &d) && d.slot == 3 && !d.connected, "a slot without a phone parses as disconnected");

    // what is not a data packet of this protocol is refused
    server_packet(p, 0, 1, 1, 0, 0, mid);
    uint8_t q[DSU_DATA_LEN];
    memcpy(q, p, sizeof q); q[30] ^= 1; CHECK(!dsu_parse(q, sizeof q, &d), "a flipped bit fails the checksum");
    memcpy(q, p, sizeof q); q[0] = 'X'; CHECK(!dsu_parse(q, sizeof q, &d), "wrong magic");
    memcpy(q, p, sizeof q); dsu_put32(q + 16, 0x100001); dsu_put32(q + 8, 0); dsu_put32(q + 8, dsu_crc32(q, sizeof q)); CHECK(!dsu_parse(q, sizeof q, &d), "another message type");
    CHECK(!dsu_parse(p, DSU_DATA_LEN - 1, &d) && !dsu_parse(p, 0, &d), "a short packet");
    memcpy(q, p, sizeof q); q[20] = DSU_SLOTS; dsu_put32(q + 8, 0); dsu_put32(q + 8, dsu_crc32(q, sizeof q)); CHECK(!dsu_parse(q, sizeof q, &d), "a slot past the last one");

    printf("%d checks, %d failed\n", checks, fails);
    return fails != 0;
}
