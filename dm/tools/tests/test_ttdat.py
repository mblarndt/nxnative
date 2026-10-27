"""TT Games' DAT archives (LEGO Star Wars: The Skywalker Saga): the index at the end of the file, files stored or in OODL chunks, and the shaders in them (code area right before the control section)."""
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
_had = os.environ.get('DM_GAME'); os.environ['DM_GAME'] = '010042D00D900000'   # shader_split loads a profile at import; other tests expect no default game
sys.path.insert(0, str(REPO / 'dm/gfx/tools')); import shader_split as ss
if _had is None: del os.environ['DM_GAME']
else: os.environ['DM_GAME'] = _had


def shader(stage_bits, n=0x100, fill=1):
    code = bytearray(n); code[:4] = ss.GFX_MAGIC; struct.pack_into('<I', code, 0x30, stage_bits << 10); code[0x80:] = bytes([fill]) * (n - 0x80)
    ctl = bytearray(0x880); ctl[:4] = ss.CTL_MAGIC; struct.pack_into('<I', ctl, 0x20, 0x880); struct.pack_into('<I', ctl, 0x704, n)
    return bytes(code), bytes(ctl)


def chunk(payload, unpacked=None):   # a chunk of a mode 9 file; equal lengths are stored as they are, so the test needs no decoder
    return b'OODL' + struct.pack('<II', len(payload), unpacked or len(payload)) + payload


def dat(files):
    """files: [(mode, stored bytes, unpacked length)] → the archive's bytes: 8 header bytes, the files, then the big-endian index"""
    body, ents, pos = b'', [], 8
    for mode, raw, ul in files:
        ents.append((pos, mode, len(raw), ul)); body += raw; pos += len(raw)
    names = b'a\0\0\0'
    idx = struct.pack('>III', 0x2e434334, 0x30544144, 0xfffffff3) + struct.pack('>IIII', 2, 1, 1, len(names)) + names + bytes(12) + bytes(4)
    idx += struct.pack('>iI', -13, len(ents)) + b''.join(struct.pack('>QII', mode << 56 | p, cl, ul) for p, mode, cl, ul in ents)
    idx = struct.pack('>I', len(idx)) + idx
    return b'\x01\x02\x03\x04' + struct.pack('<I', len(idx)) + body + idx


class TtDat(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)

    def write(self, data, name='GAME.DAT'):
        p = os.path.join(self.tmp.name, name)
        with open(p, 'wb') as f: f.write(data)
        return p

    def test_index_and_files(self):
        code, ctl = shader(5)
        blob = b'RESH header ' + code + ctl + b'tail'
        raw = chunk(blob[:20]) + chunk(blob[20:])
        p = self.write(dat([(0, b'stored file', 11), (9, raw, len(blob))]))
        ents = ss.ttdat_index(p)
        self.assertEqual([(e[0], e[2], e[3], e[4]) for e in ents], [(0, 11, 11, 0), (1, len(raw), len(blob), 9)])
        with open(p, 'rb') as f: d = f.read()
        self.assertEqual(ss.ttdat_read(d, ents[0][1], ents[0][2], ents[0][3], 0, 'x'), b'stored file')
        self.assertEqual(ss.ttdat_read(d, ents[1][1], ents[1][2], ents[1][3], 9, 'x'), blob)
        self.assertIsNone(ss.ttdat_read(d, ents[1][1], ents[1][2], ents[1][3], 6, 'x'))   # ZIPX files are not read

    def test_not_a_dat(self):
        self.assertIsNone(ss.ttdat_index(self.write(b'\0' * 64)))
        self.assertIsNone(ss.ttdat_index(self.write(b'\1\2\3\4' + struct.pack('<I', 0x10) + b'\0' * 64)))

    def test_shaders_at_any_alignment_and_stage(self):
        ps, ctl_ps = shader(5, 0x100, 1); vs, ctl_vs = shader(1, 0x200, 2)
        blob = b'x' + ps + ctl_ps + b'yyy' + vs + ctl_vs
        out = []; ss.tt_shaders(blob, '/GAME.DAT#0', out)
        self.assertEqual([(w.split('#TT@')[1], st, len(code)) for w, st, _, code in out], [(hex(1 + 0x100), 'ps', 0x100), (hex(1 + 0x100 + 0x880 + 3 + 0x200), 'vs', 0x200)])
        self.assertEqual(out[0][3], ps)

    def test_a_control_section_without_its_code_is_left_out(self):
        _, ctl = shader(5)
        out = []; ss.tt_shaders(b'\0' * 0x40 + ctl, '/x', out)
        self.assertEqual(out, [])

    def test_jobs_cover_every_entry_once(self):
        p = self.write(dat([(0, b'a' * 10, 10), (0, b'b' * 20, 20), (0, b'c' * 30, 30)]))
        jobs, taken = ss.ttdat_jobs([(p, 'GAME.DAT'), (self.write(b'plain', 'x.bin'), 'x.bin')], parts=2)
        self.assertEqual(taken, {p})
        self.assertEqual(sorted(e[0] for _, _, (_, ents) in jobs for e in ents), [0, 1, 2])


if __name__ == '__main__':
    unittest.main()
