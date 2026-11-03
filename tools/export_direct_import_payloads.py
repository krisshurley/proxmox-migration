#!/usr/bin/env python3
"""Export byte-exact offline payloads from the pinned VirtIO bundle (development only).

No downloads or Windows installer execution. Supports this reviewed WiX 3 bundle,
its MSZIP cabinets and its MSI compound-file format; unknown formats fail closed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_SHA256 = '21a2c7d7607ca52de3d7f57b57c8ba8752b9ba68ca89b54de48ff266091b14e4'


def u16(data, offset):
    return struct.unpack_from('<H', data, offset)[0]


def u32(data, offset):
    return struct.unpack_from('<I', data, offset)[0]


def cabinet(data):
    if data[:4] != b'MSCF' or u32(data, 8) != len(data) or u16(data, 30):
        raise ValueError('Unsupported cabinet header/flags')
    folders = []
    for index in range(u16(data, 26)):
        offset, blocks, compression = struct.unpack_from('<IHH', data, 36 + index * 8)
        if compression != 1:
            raise ValueError('Only MSZIP cabinets are supported')
        folder = bytearray()
        for _ in range(blocks):
            compressed, size = struct.unpack_from('<HH', data, offset + 4)
            payload = data[offset + 8:offset + 8 + compressed]
            if payload[:2] != b'CK':
                raise ValueError('Invalid MSZIP block')
            decoder = zlib.decompressobj(-15, zdict=bytes(folder[-32768:])) if folder else zlib.decompressobj(-15)
            block = decoder.decompress(payload[2:]) + decoder.flush()
            if len(block) != size or not decoder.eof:
                raise ValueError('Invalid decompressed block length')
            folder.extend(block)
            offset += 8 + compressed
        folders.append(folder)
    offset = u32(data, 16)
    files = {}
    for _ in range(u16(data, 28)):
        size, position, folder = struct.unpack_from('<IIH', data, offset)
        end = data.index(b'\0', offset + 16)
        name = data[offset + 16:end].decode('utf-8')
        if name in files or folder >= len(folders):
            raise ValueError('Invalid cabinet member')
        files[name] = bytes(folders[folder][position:position + size])
        if len(files[name]) != size:
            raise ValueError('Truncated cabinet member')
        offset = end + 1
    return files


class Msi:
    """Read only the MSI streams and string columns required for this export."""
    def __init__(self, data):
        self.data = data
        if data[:8] != bytes.fromhex('d0cf11e0a1b11ae1'):
            raise ValueError('Expected an MSI compound file')
        self.sector = 1 << u16(data, 30)
        if self.sector != 512 or u32(data, 72):
            raise ValueError('Unsupported compound-file layout')
        self.fat = []
        for sector in struct.unpack_from('<109I', data, 76):
            if sector < 0xfffffffa:
                self.fat.extend(struct.unpack('<128I', self.sector_bytes(sector)))
        directory = self.chain(u32(data, 48))
        entries = []
        for offset in range(0, len(directory), 128):
            row = directory[offset:offset + 128]
            length = u16(row, 64)
            if length:
                entries.append((self.decode_name(row[:length - 2].decode('utf-16le')), row[66], u32(row, 116), struct.unpack_from('<Q', row, 120)[0]))
        root = next(row for row in entries if row[1] == 5)
        mini = self.chain(root[2])
        raw_fat = self.chain(u32(data, 60))
        mini_fat = struct.unpack('<%dI' % (len(raw_fat) // 4), raw_fat)
        self.streams = {}
        for name, kind, first, size in entries:
            if kind != 2:
                continue
            if size >= 4096:
                value = self.chain(first)[:size]
            else:
                value = bytearray()
                visited = set()
                while first < 0xfffffffa:
                    if first in visited:
                        raise ValueError('Cyclic mini stream')
                    visited.add(first)
                    value.extend(mini[first * 64:(first + 1) * 64])
                    first = mini_fat[first]
                value = bytes(value[:size])
            if len(value) != size:
                raise ValueError('Truncated MSI stream')
            self.streams[name] = value
        pool, strings = self.streams['_StringPool'], self.streams['_StringData']
        if u32(pool, 0) != 1252:
            raise ValueError('Unexpected MSI string encoding')
        self.strings = ['']
        offset = 0
        for index in range(4, len(pool), 4):
            length = u16(pool, index)
            self.strings.append(strings[offset:offset + length].decode('cp1252'))
            offset += length

    def sector_bytes(self, index):
        return self.data[(index + 1) * self.sector:(index + 2) * self.sector]

    def chain(self, index):
        result, visited = bytearray(), set()
        while index < 0xfffffffa:
            if index in visited:
                raise ValueError('Cyclic compound-file chain')
            visited.add(index)
            result.extend(self.sector_bytes(index))
            index = self.fat[index]
        return bytes(result)

    @staticmethod
    def decode_name(name):
        alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._'
        result = ''
        for character in name:
            code = ord(character)
            if 0x3800 <= code < 0x4800:
                code -= 0x3800
                result += alphabet[code & 63] + alphabet[code >> 6]
            elif 0x4800 <= code < 0x4840:
                result += alphabet[code - 0x4800]
            elif code != 0x4840:
                result += character
        return result

    def file_names(self):
        data, widths = self.streams['File'], [2, 2, 2, 4, 2, 2, 2, 4]
        if len(data) % sum(widths):
            raise ValueError('Unexpected MSI File table')
        count = len(data) // sum(widths)
        return {self.strings[u16(data, row * 2)]: self.strings[u16(data, 4 * count + row * 2)].split('|')[-1] for row in range(count)}


def build():
    bundle = (ROOT / 'virtio-win-guest-tools.exe').read_bytes()
    if hashlib.sha256(bundle).hexdigest() != BUNDLE_SHA256:
        raise ValueError('Bundle differs from the reviewed artifact; re-audit before exporting')
    # Offsets are deliberately tied to the complete bundle hash, not guessed by scanning.
    payload = cabinet(bundle[600135:600135 + 30516628])
    driver_msi, agent_msi = payload['a0'], payload['a6']
    if hashlib.sha256(driver_msi).hexdigest() != '20a15bc93da585f90b4ca3b315652a9478e4c4a76f444d379b357167d727fee4':
        raise ValueError('Unexpected x64 driver MSI')
    if hashlib.sha256(agent_msi).hexdigest() != '22230284dda8ba4c96a834fe1087228a1db5d0b86247a9d7fcb164d279634817':
        raise ValueError('Unexpected x64 QEMU MSI')
    msi = Msi(driver_msi)
    cabinets = [stream for stream in msi.streams.values() if stream.startswith(b'MSCF')]
    if len(cabinets) != 1:
        raise ValueError('Ambiguous embedded driver cabinet')
    members, names = cabinet(cabinets[0]), msi.file_names()
    output = {'qemu-ga-x86_64.msi': agent_msi}
    for member, content in members.items():
        match = re.fullmatch(r'FILE_(netkvm|vioscsi|vioser)(?:_.*?)?_(2k16|2k19|2k22|2k25)_amd64(?:\.(?:cat|inf|sys))?', member)
        if not match:
            continue
        driver, os = match.groups()
        name = names[member]
        if '/' in name or '\\' in name or name in ('.', '..'):
            raise ValueError('Unsafe MSI filename')
        driver = {'netkvm': 'NetKVM', 'vioser': 'vioserial'}.get(driver, driver)
        path = f'drivers/{driver}/{os}/amd64/{name}'
        if path in output:
            raise ValueError('Duplicate payload path')
        output[path] = content
    for driver, inf in [('NetKVM', 'netkvm'), ('vioscsi', 'vioscsi'), ('vioserial', 'vioser')]:
        for os in ['2k16', '2k19', '2k22', '2k25']:
            for extension in ['inf', 'cat', 'sys']:
                if f'drivers/{driver}/{os}/amd64/{inf}.{extension}' not in output:
                    raise ValueError(f'Missing complete {driver}/{os} driver package')
    manifest = {'schemaVersion': '1.0', 'bundleSha256': BUNDLE_SHA256, 'files': [{'path': path, 'sha256': hashlib.sha256(content).hexdigest()} for path, content in sorted(output.items())]}
    output['manifest.json'] = (json.dumps(manifest, indent=2) + '\n').encode()
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    output = build()
    destination = ROOT / 'direct-import'
    for relative, content in output.items():
        path = destination / relative
        if args.check:
            if not path.is_file() or path.read_bytes() != content:
                raise SystemExit(f'Payload differs: {relative}')
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
    manifest_hash = hashlib.sha256(output['manifest.json']).hexdigest()
    if args.check and manifest_hash not in (ROOT / 'Migration.DirectImport.ps1').read_text():
        raise SystemExit('Runtime manifest pin does not match exported payloads')
    print(f'{"Verified" if args.check else "Exported"} {len(output) - 1} byte-exact payloads; manifest SHA-256: {manifest_hash}')


if __name__ == '__main__':
    main()
