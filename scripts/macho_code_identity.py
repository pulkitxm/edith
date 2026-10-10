import hashlib
import struct
import subprocess
import tempfile
from pathlib import Path

PAGE = 16384


def rounded(value):
    return (value + PAGE - 1) // PAGE * PAGE


def parse(data, signed):
    if len(data) < 32:
        raise ValueError('Truncated Mach-O header')
    header = struct.unpack_from('<8I', data)
    if header[0] != 0xfeedfacf or header[1] != 0x0100000c or header[2] != 0 or header[3] != 2:
        raise ValueError('Only thin arm64 executables are supported')
    count, size = header[4:6]
    if not 1 <= count <= 4096 or size > len(data) - 32:
        raise ValueError('Invalid load command bounds')
    offset = 32
    commands = []
    segments = []
    signatures = []
    for _ in range(count):
        if offset + 8 > 32 + size:
            raise ValueError('Truncated load command')
        command, length = struct.unpack_from('<II', data, offset)
        if length < 8 or length % 8 or offset + length > 32 + size:
            raise ValueError('Invalid load command size')
        commands.append((offset, command, length))
        if command == 0x19:
            if length < 72:
                raise ValueError('Truncated segment command')
            name, vmaddr, vmsize, fileoff, filesize, _, _, sections, _ = struct.unpack_from('<16sQQQQiiII', data, offset + 8)
            if sections > 1024 or length != 72 + sections * 80 or fileoff + filesize > len(data) or filesize > vmsize:
                raise ValueError('Invalid segment bounds')
            segment = {'offset': offset, 'name': name.rstrip(b'\0'), 'vmaddr': vmaddr, 'vmsize': vmsize, 'fileoff': fileoff, 'filesize': filesize, 'sections': sections}
            segments.append(segment)
            for index in range(sections):
                section = struct.unpack_from('<16s16sQQIIIIIIII', data, offset + 72 + index * 80)
                section_type = section[8] & 0xff
                if section[1].rstrip(b'\0') != segment['name']:
                    raise ValueError('Section belongs to a different segment')
                if section_type not in (1, 12, 18) and (section[4] < fileoff or section[4] + section[3] > fileoff + filesize):
                    raise ValueError('Section data is outside its segment')
        elif command == 0x1d:
            if length != 16:
                raise ValueError('Invalid code signature command')
            signatures.append((offset, *struct.unpack_from('<II', data, offset + 8)))
        offset += length
    if offset != 32 + size:
        raise ValueError('Load commands do not match header size')
    linkedit = [segment for segment in segments if segment['name'] == b'__LINKEDIT']
    if len(linkedit) != 1 or linkedit[0] is not segments[-1]:
        raise ValueError('Expected one terminal LINKEDIT segment')
    linkedit = linkedit[0]
    if linkedit['sections'] or linkedit['fileoff'] % PAGE or linkedit['vmaddr'] % PAGE or linkedit['fileoff'] + linkedit['filesize'] != len(data):
        raise ValueError('Invalid LINKEDIT segment layout')
    ranges = sorted((segment['fileoff'], segment['fileoff'] + segment['filesize']) for segment in segments if segment['filesize'])
    if any(right[0] < left[1] for left, right in zip(ranges, ranges[1:])):
        raise ValueError('Overlapping file segments')
    if signed:
        if len(signatures) != 1 or signatures[0][0] <= linkedit['offset']:
            raise ValueError('Expected one code signature command after LINKEDIT')
        _, start, length = signatures[0]
        if start < linkedit['fileoff'] or start < 32 + size or start % 16 or length < 1 or start + length != len(data):
            raise ValueError('Invalid code signature tail bounds')
        if linkedit['vmsize'] != rounded(linkedit['filesize']):
            raise ValueError('Signed LINKEDIT mapping does not match its file size')
    elif signatures:
        raise ValueError('Signature remains after removal')
    return {'header': header, 'commands': commands, 'linkedit': linkedit, 'signature': signatures[0] if signed else None}


def normalize_signed_and_unsigned(signed, unsigned):
    before = parse(signed, True)
    after = parse(unsigned, False)
    link_before, link_after = before['linkedit'], after['linkedit']
    signature_offset, signature_start, _ = before['signature']
    if len(unsigned) > signature_start or signature_start - len(unsigned) > 15 or any(signed[len(unsigned):signature_start]):
        raise ValueError('Unexpected bytes between unsigned payload and signature')
    if after['header'][4] != before['header'][4] - 1 or after['header'][5] != before['header'][5] - 16:
        raise ValueError('Unexpected load command removal')
    expected_commands = [(offset - (16 if offset > signature_offset else 0), command, length) for offset, command, length in before['commands'] if command != 0x1d]
    if after['commands'] != expected_commands:
        raise ValueError('Other load commands changed during signature removal')
    if link_after['vmsize'] != link_before['vmsize']:
        raise ValueError('Unexpected LINKEDIT mapping change during signature removal')
    expected = bytearray(signed[:len(unsigned)])
    struct.pack_into('<II', expected, 16, after['header'][4], after['header'][5])
    struct.pack_into('<Q', expected, link_before['offset'] + 48, link_after['filesize'])
    command_end = 32 + before['header'][5]
    expected[signature_offset:command_end - 16] = signed[signature_offset + 16:command_end]
    expected[command_end - 16:command_end] = bytes(16)
    if expected != unsigned:
        raise ValueError('Other executable bytes changed during signature removal')
    canonical = bytearray(unsigned)
    struct.pack_into('<Q', canonical, link_after['offset'] + 32, rounded(link_after['filesize']))
    return bytes(canonical)


def identity_from_bytes(signed, unsigned, expected=None):
    normalized = normalize_signed_and_unsigned(signed, unsigned)
    result = {'signedBytes': len(signed), 'signedSHA256': hashlib.sha256(signed).hexdigest(), 'rawUnsignedBytes': len(unsigned), 'rawUnsignedSHA256': hashlib.sha256(unsigned).hexdigest(), 'normalizedUnsignedSHA256': hashlib.sha256(normalized).hexdigest(), 'normalization': 'arm64-terminal-linkedit-vmsize-after-verified-signature-removal-v1'}
    if expected is not None and result['normalizedUnsignedSHA256'] != expected:
        raise ValueError('Executable code differs from the pinned source')
    return result


def executable_identity(path, expected=None):
    path = Path(path)
    signed = path.read_bytes()
    parse(signed, True)
    with tempfile.TemporaryDirectory(prefix='edith-static-code-') as directory:
        target = Path(directory) / 'Edith'
        target.write_bytes(signed)
        subprocess.run(['codesign', '--remove-signature', str(target)], check=True, capture_output=True, timeout=30)
        return identity_from_bytes(signed, target.read_bytes(), expected)
