#!/usr/bin/env python3
"""Local synthetic HLS fixture for LivePlayPauseUITests; requires ffmpeg on PATH.
Run this, then set TEST_RUNNER_LIVE_URL=http://127.0.0.1:18765/window/live.m3u8
(or /event/live.m3u8) when invoking xcodebuild test. Ctrl-C stops the server.
"""
import argparse
import http.server
import pathlib
import shutil
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=18765)
    args = parser.parse_args()
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        parser.error('ffmpeg is required on PATH')
    with tempfile.TemporaryDirectory(prefix='lom-live-fixture-') as directory:
        root = pathlib.Path(directory)
        subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                        'testsrc2=size=640x360:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=440',
                        '-t', '180', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '60',
                        '-sc_threshold', '0', '-c:a', 'aac', '-f', 'hls', '-hls_time', '2',
                        '-hls_list_size', '0', '-hls_segment_filename', str(root / 'seg%03d.ts'),
                        str(root / 'generated.m3u8')], check=True)
        started = {}

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                route = self.path.split('?')[0]
                if route in ('/window/live.m3u8', '/event/live.m3u8'):
                    mode = route.split('/')[1]
                    began = started.setdefault(mode, time.monotonic())
                    end = min(90, 35 + int((time.monotonic() - began) / 2))
                    first = max(0, end - 15) if mode == 'window' else 0
                    lines = ['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:2',
                             f'#EXT-X-MEDIA-SEQUENCE:{first}']
                    if mode == 'event':
                        lines.append('#EXT-X-PLAYLIST-TYPE:EVENT')
                    for i in range(first, end):
                        lines.extend(['#EXTINF:2.000000,', f'/seg{i:03d}.ts'])
                    payload = ('\n'.join(lines) + '\n').encode()
                    kind = 'application/vnd.apple.mpegurl'
                else:
                    path = root / pathlib.Path(route).name
                    if path.suffix != '.ts' or not path.is_file():
                        self.send_error(404)
                        return
                    payload, kind = path.read_bytes(), 'video/mp2t'
                self.send_response(200)
                self.send_header('Content-Type', kind)
                self.send_header('Content-Length', str(len(payload)))
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                try:
                    self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
        print(f'Live fixtures ready at http://127.0.0.1:{args.port}/window/live.m3u8 and /event/live.m3u8', flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()


if __name__ == '__main__':
    main()
