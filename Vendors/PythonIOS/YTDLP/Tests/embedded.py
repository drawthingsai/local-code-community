"""Run with StaticInlinePythonMacOS python3 <file>, never host Python."""
import gc
import asyncio
import http.server
import json
import os
import pathlib
import subprocess
import tempfile
import threading
import urllib.parse

import curl_cffi
from curl_cffi import requests
import yt_dlp
from yt_dlp.postprocessor.ffmpeg import FFmpegPostProcessor
from yt_dlp.networking.impersonate import ImpersonateTarget
from yt_dlp.downloader.external import FFmpegFD
from yt_dlp.utils import Popen
from yt_dlp.utils._jsruntime import NodeJsRuntime
from yt_dlp.extractor.youtube import YoutubeIE
from yt_dlp.extractor.youtube.jsc._builtin.node import NodeJCP
from yt_dlp.extractor.youtube.jsc.provider import JsChallengeRequest, JsChallengeType, NChallengeInput
from yt_dlp.extractor.youtube.pot._director import YoutubeIEContentProviderLogger

assert subprocess.run.__module__ is None, 'Requires the embedded ios_system bridge'
assert curl_cffi.__version__ == '0.16.0'
assert 'BoringSSL' in curl_cffi.Curl().version().decode()
assert yt_dlp.version.__version__ == '2026.08.19'
assert NodeJsRuntime().info.version.startswith('24.')
stdout, stderr, status = Popen.run(
    ['node', '--permission', '-'], input='console.log(JSON.stringify({value: 42}))',
    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert status == 0 and json.loads(stdout)['value'] == 42, (status, stdout, stderr)
assert FFmpegPostProcessor().available and FFmpegPostProcessor().probe_available

# Load the bundled, hash-validated EJS scripts through the actual Node provider.
with yt_dlp.YoutubeDL({'quiet': True}) as downloader:
    ie = YoutubeIE(downloader)
    provider = NodeJCP(ie, YoutubeIEContentProviderLogger(ie, 'jsc'), {})
    assert provider.is_available()
    challenge = JsChallengeRequest(JsChallengeType.N, NChallengeInput('fixture', ['abc']))
    script = provider._construct_stdin('_result.n = s => s.split("").reverse().join("");', True, [challenge])
    result = json.loads(provider._run_js_runtime(script))
    assert result['responses'][0]['data'] == {'abc': 'cba'}, result
    provider.close()

payload = bytes(range(256)) * 2048
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/media.mp4')
            self.send_header('Set-Cookie', 'test_cookie=present')
            self.end_headers()
            return
        body = source.read_bytes() if urllib.parse.urlsplit(self.path).path == '/input.wav' else payload
        self.send_response(200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
base = f'http://127.0.0.1:{server.server_port}'
try:
    for profile in ('chrome136', 'safari184'):
        with requests.Session(impersonate=profile) as session:
            response = session.get(base + '/redirect', timeout=5)
            assert response.content == payload and session.cookies['test_cookie'] == 'present'
            with session.stream('GET', base + '/media.mp4', timeout=5) as response:
                assert b''.join(response.iter_content()) == payload
            # Early close must release the transfer and permit another request.
            with session.stream('GET', base + '/media.mp4', timeout=5) as response:
                next(response.iter_content())
            assert session.get(base + '/media.mp4', timeout=5).content == payload
        del session, response
        gc.collect()
    async def check_async():
        async with requests.AsyncSession(impersonate='chrome136') as session:
            responses = await asyncio.gather(*(session.get(base + '/media.mp4') for _ in range(3)))
            assert all(response.content == payload for response in responses)
    asyncio.run(check_async())
    with tempfile.TemporaryDirectory() as directory:
        output = pathlib.Path(directory) / 'download.bin'
        with yt_dlp.YoutubeDL({'quiet': True, 'outtmpl': str(output), 'force_generic_extractor': True,
                              'impersonate': ImpersonateTarget.from_str('chrome')}) as downloader:
            downloader.download([base + '/media.mp4'])
        assert output.read_bytes() == payload
        # Exercise native FFmpeg postprocessing through yt-dlp, not just --version.
        source = pathlib.Path(directory) / 'input.wav'
        subprocess.run(['ffmpeg', '-y', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.1', str(source)],
                       capture_output=True, check=True)
        target = pathlib.Path(directory) / 'output.m4a'
        FFmpegPostProcessor().run_ffmpeg(str(source), str(target), ['-c:a', 'aac'])
        info = FFmpegPostProcessor().get_metadata_object(str(target))
        assert info['streams'][0]['codec_name'] == 'aac'
        assert float(info['format']['duration']) > 0
        with yt_dlp.YoutubeDL({'quiet': True}) as downloader:
            external = pathlib.Path(directory) / 'external.wav'
            assert FFmpegFD(downloader, {}).real_download(str(external), {
                'url': base + '/input.wav', 'ext': 'wav', 'protocol': 'http'})
            assert external.stat().st_size > 100
            # Both inputs must use the explicit proxy; the origin cannot resolve.
            merged = pathlib.Path(directory) / 'merged.mkv'
            remote = {'url': 'http://fixture.invalid/input.wav', 'ext': 'wav', 'protocol': 'http'}
            assert FFmpegFD(downloader, {'proxy': base}).real_download(str(merged), {
                **remote, 'ext': 'mkv', 'requested_formats': [remote, remote]})
            assert len(FFmpegPostProcessor().get_metadata_object(str(merged))['streams']) == 2
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)
assert not thread.is_alive()
print('curl_cffi / yt-dlp embedded integration passed')
