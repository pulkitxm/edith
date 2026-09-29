import hashlib
import json
import math
from pathlib import Path
import select
import struct
import subprocess
import sys
import uuid
import wave
import zlib

from edith_test_environment import isolated_test_environment


def png(path, color):
    width, height = 640, 360
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            bright = 0.75 if (x // 80 + y // 60) % 2 else 1
            rows.extend(int(channel * bright) for channel in color)

    def chunk(kind, value):
        return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value))

    path.write_bytes(b'\x89PNG\r\n\x1a\n'
                     + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def main():
    binary, root = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    root.mkdir(mode=0o700)
    environment = isolated_test_environment(root, 'com.pulkit.edith.test.review.' + uuid.uuid4().hex)

    def cli(*arguments, success=True):
        result = subprocess.run([str(binary), 'studio', 'edit', *map(str, arguments), '--json'],
                                env=environment, capture_output=True, text=True, timeout=300)
        if success:
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)
        assert result.returncode != 0
        return json.loads(result.stderr or result.stdout)

    png(root / 'blue.png', (30, 125, 195))
    png(root / 'amber.png', (215, 135, 30))
    sample_rate = 8000
    samples = []
    for index in range(sample_rate * 4):
        seconds = index / sample_rate
        distance = min(abs(seconds - beat) for beat in [1.501, 2.502, 3.503])
        envelope = max(0, 1 - distance / 0.025)
        samples.append(int(26000 * envelope * math.cos(2 * math.pi * 240 * seconds)))
    with wave.open(str(root / 'clicks.wav'), 'wb') as audio:
        audio.setparams((1, 2, sample_rate, 0, 'NONE', 'not compressed'))
        audio.writeframes(struct.pack('<' + 'h' * len(samples), *samples))
    project = root / 'rhythm.openscreen'
    cli('create', project, '--title', 'Synthetic rhythm review')
    plan = {'version': 1, 'operations': [
        {'addStill': {'path': str(root / 'blue.png'), 'name': 'blue', 'duration': 1.001}},
        {'addStill': {'path': str(root / 'amber.png'), 'name': 'amber', 'duration': 1.001}},
        {'videoSettings': {'settings': {'width': 640, 'height': 360, 'frameRateNumerator': 30000,
                                        'frameRateDenominator': 1001, 'colorSpace': 'rec709'}}},
        {'canvas': {'aspectRatio': 'native', 'padding': 0, 'backgroundColor': '#111111'}},
        {'addAudio': {'path': str(root / 'clicks.wav'), 'start': 0.25, 'offset': 1}},
        {'text': {'content': 'SYNTHETIC RHYTHM REVIEW', 'start': 0, 'end': 2.002}},
    ]}
    (root / 'plan.json').write_text(json.dumps(plan))
    cli('apply', project, '--plan', root / 'plan.json', '--overwrite')
    markers = [{'id': 'cue-' + str(frame), 'frame': frame,
                'frameRate': {'numerator': 30000, 'denominator': 1001},
                'kind': 'manual' if frame == 0 else 'transient', 'label': 'Synthetic cue'}
               for frame in [0, 15, 30, 45]]
    (root / 'markers.json').write_text(json.dumps({'version': 1, 'markers': markers}))
    cli('markers', 'import', project, '--input', root / 'markers.json')
    document = json.loads(project.read_text())
    asset = next(asset['id'] for asset in document['assets'] if asset['kind'] == 'audio')
    before = project.read_bytes()
    args = [str(project), '--time', '0', '--time', '0.501', '--time', '0.501', '--time', '1.502',
            '--columns', '2', '--cell-width', '320']
    plain = cli('contact-sheet', *args, '--output', root / 'plain.png')
    flags = ['--show-beat-markers', '--waveform-asset', asset, '--source-in', '1',
             '--source-out', '4', '--output-start', '0.25', '--playback-rate', '2']
    report = cli('contact-sheet', *args, '--output', root / 'cli.png', *flags)
    assert report['height'] == plain['height'] + 132 and report['width'] == plain['width']
    assert [frame['frame'] for frame in report['frames']] == [0, 15, 15, 45]
    overlay = report['overlays']
    assert len(overlay['markers']) == 4 and overlay['waveform']
    assert overlay['cells'][1]['x'] == overlay['cells'][2]['x']
    assert abs(overlay['cells'][1]['x'] - overlay['markers'][1]['x']) < 1e-6
    existing = (root / 'cli.png').read_bytes()
    invalid = flags.copy()
    invalid[2] = 'missing'
    cli('contact-sheet', *args, '--output', root / 'cli.png', '--overwrite', *invalid, success=False)
    assert (root / 'cli.png').read_bytes() == existing and project.read_bytes() == before
    process = subprocess.Popen([str(binary), 'mcp'], env=environment, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

    def send(message):
        process.stdin.write(json.dumps({'jsonrpc': '2.0', **message}) + '\n')
        process.stdin.flush()

    def receive(identifier):
        while True:
            assert select.select([process.stdout], [], [], 180)[0], 'MCP response timed out'
            line = process.stdout.readline()
            assert line, 'MCP closed early'
            message = json.loads(line)
            if message.get('id') == identifier:
                assert 'error' not in message, message
                return message['result']

    try:
        send({'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26',
              'capabilities': {}, 'clientInfo': {'name': 'review-fixture', 'version': '1'}}})
        receive(1)
        send({'method': 'notifications/initialized'})
        send({'id': 2, 'method': 'tools/call', 'params': {
            'name': 'edith_studio_edit_contact_sheet',
            'arguments': {'arguments': args + ['--output', str(root / 'mcp.png')] + flags}}})
        result = receive(2)
        assert not result.get('isError'), result
        mcp = json.loads(result['content'][0]['text'])
        assert mcp['overlays'] == overlay and mcp['sha256'] == report['sha256']
        assert hashlib.sha256((root / 'mcp.png').read_bytes()).hexdigest() == report['sha256']
        assert project.read_bytes() == before
    finally:
        process.terminate()
        process.wait(timeout=10)
    summary = {'cli': 'passed', 'mcp': 'passed', 'syntheticDataOnly': True,
               'frames': [frame['frame'] for frame in report['frames']],
               'savedMarkers': len(overlay['markers']), 'waveformBins': len(overlay['waveform']),
               'sourceMapping': overlay['waveformMapping'], 'unchangedOnInvalidSelection': True,
               'width': report['width'], 'height': report['height'], 'sha256': report['sha256']}
    (root / 'evidence.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
