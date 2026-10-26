#!/usr/bin/env python3
"""Compile a gettext .po file into a LuCI .lmo catalog.

Port of luci-base src/po2lmo.c (openwrt-25.12) that writes the same bytes as the
official tool: the same line reader (fgets with a 4096-byte buffer), string
extraction, key layout (msgctxt \\1 msgid \\2 index), sfh_hash from lib/lmo.c,
4-byte padding and big-endian index.  Inputs the C tool would turn into
undefined output (unterminated strings, colliding keys) are refused instead.

Usage: po2lmo.py input.po output.lmo
"""
import os
import struct
import sys

BUF = 4096          # char line[4096], tmp[4096], key[4096] in po2lmo.c
MAX_PLURALS = 10    # char *val[10]
MASK = 0xFFFFFFFF


class PoError(Exception):
    pass


def sfh_hash(data, init):
    """Paul Hsieh's SuperFastHash as in lib/lmo.c (little-endian 16-bit reads)."""
    length = len(data)
    if length <= 0:
        return 0

    def get16(o):
        return data[o] | (data[o + 1] << 8)

    def schar(b):
        return b - 256 if b > 127 else b

    h = init & MASK
    rem = length & 3
    i = 0
    for _ in range(length >> 2):
        h = (h + get16(i)) & MASK
        tmp = ((get16(i + 2) << 11) ^ h) & MASK
        h = ((h << 16) ^ tmp) & MASK
        i += 4
        h = (h + (h >> 11)) & MASK

    if rem == 3:
        h = (h + get16(i)) & MASK
        h ^= (h << 16) & MASK
        h ^= (schar(data[i + 2]) << 18) & MASK
        h = (h + (h >> 11)) & MASK
    elif rem == 2:
        h = (h + get16(i)) & MASK
        h ^= (h << 11) & MASK
        h = (h + (h >> 17)) & MASK
    elif rem == 1:
        h = (h + schar(data[i])) & MASK
        h ^= (h << 10) & MASK
        h = (h + (h >> 1)) & MASK

    h ^= (h << 3) & MASK
    h = (h + (h >> 5)) & MASK
    h ^= (h << 4) & MASK
    h = (h + (h >> 17)) & MASK
    h ^= (h << 25) & MASK
    h = (h + (h >> 6)) & MASK
    return h


def read_lines(data):
    """Yield what repeated fgets(line, 4096, in) sees, cut at the first NUL like strlen()."""
    pos = 0
    while pos < len(data):
        nl = data.find(b'\n', pos, pos + BUF - 1)
        end = nl + 1 if nl >= 0 else min(pos + BUF - 1, len(data))
        yield data[pos:end].split(b'\0', 1)[0]
        pos = end


def extract_string(line, lineno):
    """extract_string(): the first quoted string; \\" and \\\\ unescaped, other escapes kept."""
    if line.startswith(b'#'):
        return None
    start = line.find(b'"')
    if start < 0:
        return None
    out = bytearray()
    esc = False
    for c in line[start + 1:BUF]:
        if esc:
            if c in b'"\\':
                out[-1] = c
            else:
                out.append(c)
            esc = False
        elif c == 0x5C:
            out.append(c)
            esc = True
        elif c == 0x22:
            return bytes(out)
        else:
            out.append(c)
    raise PoError('line %d: unterminated string (or a line longer than %d bytes)' % (lineno, BUF - 1))


def parse_plural_index(line, lineno):
    digits = line[7:].lstrip(b' \t')
    n = 0
    for c in digits:
        if not 0x30 <= c <= 0x39:
            break
        n = n * 10 + c - 0x30
    if digits[:1] == b'-' or n >= MAX_PLURALS:
        raise PoError('line %d: Too many plural forms' % lineno)
    return n


def pad(b):
    return b + b'\0' * ((4 - len(b) % 4) % 4)


class Catalog:
    def __init__(self):
        self.blob = bytearray()
        self.entries = []
        self.keys = {}

    def add(self, key_id, val_id, value, what):
        if key_id in self.keys:
            raise PoError('%s and %s have the same key hash; the official tool would order them '
                          'arbitrarily' % (self.keys[key_id], what))
        self.keys[key_id] = what
        self.entries.append((key_id, val_id, len(self.blob), len(value)))
        self.blob.extend(pad(value))

    def add_msg(self, msg):
        if msg['id'] is not None and msg['val'][0] is not None:
            for i in range(msg['plural'] + 1):
                val = msg['val'][i]
                if val is None:
                    continue
                if msg['ctxt'] is not None and msg['id_plural'] is not None:
                    key = msg['ctxt'] + b'\1' + msg['id'] + b'\2' + str(i).encode()
                elif msg['ctxt'] is not None:
                    key = msg['ctxt'] + b'\1' + msg['id']
                elif msg['id_plural'] is not None:
                    key = msg['id'] + b'\2' + str(i).encode()
                else:
                    key = msg['id']
                key = key[:BUF - 1]
                key_id = sfh_hash(key, len(key))
                if key_id != sfh_hash(val, len(val)):
                    self.add(key_id, msg['plural'] + 1, val, 'msgid %r' % key)
        elif msg['val'][0] is not None:
            self.add_header(msg['val'][0])

    def add_header(self, header):
        # Only fields terminated by a literal "\n" are looked at, as in print_msg().
        start = 0
        esc = False
        for idx, c in enumerate(header):
            if esc:
                if c == 0x6E:
                    field = header[start:idx - 1]
                    if field[:14].lower() == b'plural-forms: ':
                        self.add(0, 0, field[14:], 'the Plural-Forms header')
                        return
                    start = idx + 1
                esc = False
            elif c == 0x5C:
                esc = True

    def write(self, path):
        if not self.blob:
            # po2lmo.c unlinks an output without any translation
            if os.path.exists(path):
                os.unlink(path)
            return False
        with open(path, 'wb') as out:
            out.write(self.blob)
            for entry in sorted(self.entries):
                out.write(struct.pack('>IIII', *entry))
            out.write(struct.pack('>I', len(self.blob)))
        return True


def new_msg():
    return {'plural': -1, 'ctxt': None, 'id': None, 'id_plural': None, 'val': [None] * MAX_PLURALS}


def compile_po(data):
    cat = Catalog()
    msg = new_msg()
    cur = None
    lines = list(read_lines(data))
    for lineno, line in enumerate(lines + [None], 1):
        eof = line is None
        if eof:
            line = b''
        started = msg['id'] is not None or msg['val'][0] is not None
        if line.startswith(b'msgctxt "'):
            if started:
                cat.add_msg(msg)
                msg = new_msg()
            msg['ctxt'] = None
            cur = ('ctxt',)
        elif eof or line.startswith(b'msgid "'):
            if started:
                cat.add_msg(msg)
                msg = new_msg()
            msg['id'] = None
            cur = ('id',)
        elif line.startswith(b'msgid_plural "'):
            msg['id_plural'] = None
            cur = ('id_plural',)
        elif line.startswith(b'msgstr "') or line.startswith(b'msgstr['):
            n = parse_plural_index(line, lineno) if line[6:7] == b'[' else 0
            msg['plural'] = n
            msg['val'][n] = None
            cur = ('val', n)
        if eof:
            break
        if cur is None:
            continue
        s = extract_string(line, lineno)
        if not s:
            continue
        if cur[0] == 'val':
            msg['val'][cur[1]] = (msg['val'][cur[1]] or b'') + s
        else:
            msg[cur[0]] = (msg[cur[0]] or b'') + s
    return cat


def main(argv):
    if len(argv) != 3:
        sys.stderr.write('Usage: %s input.po output.lmo\n' % argv[0])
        return 1
    try:
        with open(argv[1], 'rb') as f:
            data = f.read()
        compile_po(data).write(argv[2])
    except (OSError, PoError) as e:
        sys.stderr.write('Error: %s\n' % e)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
