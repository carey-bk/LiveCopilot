#!/usr/bin/env python3
"""Stage an isolated mock app at build 100 and a signed loopback update at 101.

Requires a current Debug build. Does not launch, install, or modify the production app.
Private EdDSA keys stay in Keychain. Start a server on 127.0.0.1:18746 to run the UI check.
"""
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
QA = ROOT / 'build/updater-qa'
TOOLS = ROOT / 'build/SparkleTools/bin'
SOURCE = ROOT / 'build/Build/Products/Debug/LiveCopilot.app'


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


assert not QA.exists(), 'Use a new QA staging directory; preserve existing evidence.'
for kind, version in [('installed', '100'), ('candidate', '101')]:
    app = QA / kind / 'LiveCopilot.app'
    app.parent.mkdir(parents=True)
    run('/usr/bin/ditto', SOURCE, app)
    path = app / 'Contents/Info.plist'
    info = plistlib.loads(path.read_bytes())
    info.update(CFBundleIdentifier='com.livecopilot.updater-qa', CFBundleVersion=version,
                CFBundleName='LiveCopilot Update QA', CFBundleDisplayName='LiveCopilot Update QA',
                LiveCopilotOnboardingPreview=True,
                LiveCopilotUpdaterTestFeed='http://127.0.0.1:18746/appcast.xml',
                SUFeedURL='http://127.0.0.1:18746/appcast.xml',
                NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
    path.write_bytes(plistlib.dumps(info))
    run('/usr/bin/codesign', '--force', '--deep', '--sign', '-', app)
server = QA / 'server'
server.mkdir()
archive = server / 'LiveCopilot-QA-101.zip'
run('/usr/bin/ditto', '-c', '-k', '--keepParent', QA / 'candidate/LiveCopilot.app', archive)
(server / 'LiveCopilot-QA-101.html').write_text('<h2>Isolated updater check</h2><p>Mock app only: build 100 to 101. No recording, AI requests, or production settings.</p>')
run(TOOLS / 'generate_appcast', '--account', 'LiveCopilot', '--maximum-deltas', '0',
    '--download-url-prefix', 'http://127.0.0.1:18746/', '--embed-release-notes', server)
run(TOOLS / 'sign_update', '--account', 'LiveCopilot', '--verify', server / 'appcast.xml')
print('Ready:', QA / 'installed/LiveCopilot.app')
