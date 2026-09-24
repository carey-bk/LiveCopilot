"""Exercise the actual Swift download delegate against a throttled loopback server."""
import http.server
import pathlib
import subprocess
import tempfile
import threading
import time
import unittest

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        if self.path != '/unknown': self.send_header('Content-Length', str(32 * 65536))
        self.end_headers()
        try:
            for _ in range(32):
                self.wfile.write(b'x' * 65536); self.wfile.flush(); time.sleep(.05)
        except (BrokenPipeError, ConnectionResetError): pass
    def log_message(self, *args): pass

class ProgressTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        root = pathlib.Path(cls.temp.name)
        source = (pathlib.Path(__file__).parents[1] / 'Sources/Stealth/Core/LocalModelInstaller.swift').read_text()
        observer = source[source.index('final class ModelDownloadObserver'):]
        probe = r'''
@main struct Probe {
 static func main() async throws {
  let observer = ModelDownloadObserver { value, rate in print("UPDATE", value ?? -1, rate) }
  let session = URLSession(configuration: .ephemeral, delegate: observer, delegateQueue: nil)
  defer { session.invalidateAndCancel() }
  let task = Task { try await observer.run(session: session, address: URL(string: CommandLine.arguments[1])!, resumeData: nil) }
  if CommandLine.arguments.last == "cancel" {
   try await Task.sleep(nanoseconds: 350_000_000); task.cancel()
   do { _ = try await task.value; fatalError("Cancellation failed") }
   catch is CancellationError { print("CANCELLED") }
  } else {
   let (file, _) = try await task.value
   print("BYTES", try Data(contentsOf: file).count)
   try FileManager.default.removeItem(at: file)
  }
 }
}
'''
        swift = root / 'probe.swift'; swift.write_text('import Foundation\n' + observer + probe)
        cls.binary = root / 'probe'
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-sdk', sdk, '-parse-as-library', str(swift), '-o', str(cls.binary)], check=True)
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.temp.cleanup()
    def run_probe(self, path, *args):
        return subprocess.check_output([str(self.binary), f'http://127.0.0.1:{self.server.server_port}/{path}', *args], text=True, timeout=15)
    def test_intermediate_percent_and_speed(self):
        result = self.run_probe('known')
        values = [float(line.split()[1]) for line in result.splitlines() if line.startswith('UPDATE')]
        self.assertGreater(len(values), 2)
        self.assertTrue(any(0 < n < 1 for n in values))
        self.assertEqual(values[-1], 1)
        self.assertIn('MB/s', result)
        self.assertIn('BYTES 2097152', result)
    def test_unknown_length_still_reports_bytes_and_speed(self):
        result = self.run_probe('unknown')
        self.assertIn('UPDATE -1.0', result)
        self.assertIn('MB/s', result)
        self.assertIn('BYTES 2097152', result)
    def test_cancellation_completes(self):
        self.assertIn('CANCELLED', self.run_probe('known', 'cancel'))

if __name__ == '__main__': unittest.main()
