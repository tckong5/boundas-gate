#!/usr/bin/env python3
"""Exercise the real Sparkle binary with disposable localhost app/feed fixtures."""
import functools
import http.server
import pathlib
import plistlib
import subprocess
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parents[1]
FRAMEWORK = ROOT / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
KEY = 'ATH06nujvadK3M79ihD6vc8A8b0nCsEzCf+VBP9a2TU='

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

with tempfile.TemporaryDirectory(prefix='boundas-updater-', dir='/private/tmp') as temporary:
    root = pathlib.Path(temporary)
    app = root / 'Updater Smoke.app'
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    (contents / 'Frameworks').mkdir()
    subprocess.run(['ditto', '--norsrc', '--noextattr', str(FRAMEWORK), str(contents / 'Frameworks/Sparkle.framework')], check=True)
    executable = contents / 'MacOS/Smoke'
    subprocess.run(['clang', '-fobjc-arc', '-fmodules', str(ROOT / 'Tests/Updater/Smoke.m'), '-F', str(FRAMEWORK.parent), '-framework', 'Sparkle', '-framework', 'AppKit', '-Wl,-rpath,@executable_path/../Frameworks', '-o', str(executable)], check=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    with open(contents / 'Info.plist', 'wb') as stream:
        plistlib.dump(dict(CFBundleIdentifier='com.boundasgate.updater-smoke', CFBundleExecutable='Smoke', CFBundleName='Updater Smoke', CFBundlePackageType='APPL', CFBundleVersion='7', CFBundleShortVersionString='1.2.0', SUPublicEDKey=KEY, SUVerifyUpdateBeforeExtraction=True, SUFeedURL=base + '/appcast.xml', SUEnableAutomaticChecks=False, NSAppTransportSecurity={'NSAllowsLocalNetworking': True}), stream)
    # Sign the nested helpers using the same packaging routine.
    subprocess.run(['zsh', str(ROOT / 'scripts/sign-sparkle.sh'), str(app), '--force', '--sign', '-'], check=True, capture_output=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    try:
        for name, feed in [
            ('standard', '<?xml version="1.0"?><rss version="2.0"><channel><title>Fixture</title></channel></rss>'),
            ('malformed', '<not-valid-xml'),
            ('unsigned', f'''<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Fixture</title><item><title>Test</title><sparkle:version>8</sparkle:version><enclosure url="{base}/unsigned.zip" length="3" type="application/octet-stream"/></item></channel></rss>''')
        ]:
            (root / 'appcast.xml').write_text(feed)
            (root / 'unsigned.zip').write_bytes(b'bad')
            result = subprocess.run([str(executable), name], capture_output=True, text=True, timeout=25)
            expected = '1000' if name == 'malformed' else '4005'
            unsigned_rejected = name != 'unsigned' or 'there is no EdDSA signature in the update' in result.stderr
            evidence = 'STANDARD CHECK LOADED FEED' if name == 'standard' else f'REJECTED SUSparkleErrorDomain {expected}'
            if result.returncode or 'INITIALIZED' not in result.stdout or evidence not in result.stdout or not unsigned_rejected:
                raise SystemExit(f'{name} failed: {result.stdout} {result.stderr}')
            print(f'{name}: {result.stdout.strip()}')
    finally:
        server.shutdown()
