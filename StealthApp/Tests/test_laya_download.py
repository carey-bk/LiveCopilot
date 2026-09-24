import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('download_installer', Path(__file__).parents[1] / 'Resources/LayaRuntime/install.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class DownloadTests(unittest.TestCase):
    def setUp(self): module.SOURCE = 'mirror'; module.DISTRIBUTION_BASE = None
    def test_file_count_event_matches_pinned_install_plan(self):
        pins = json.loads((Path(__file__).parents[1] / 'Resources/LayaRuntime/pins.json').read_text())
        total = 2 + len(pins['wheels']) + len(pins['model'])
        self.assertEqual(total, 32)
        events = []
        with patch.object(module, 'output', events.append):
            module.announce_file(1, total)
            module.announce_file(len(pins['wheels']) + 2, total)
            module.announce_file(len(pins['wheels']) + 2 + len(pins['model']), total)
        self.assertEqual(events, [
            {'file_index': 1, 'file_total': 32},
            {'file_index': 21, 'file_total': 32},
            {'file_index': 32, 'file_total': 32},
        ])
    def test_modelscope_precedes_both_fallbacks_without_credentials(self):
        module.SOURCE = 'distribution'; module.DISTRIBUTION_BASE = 'https://modelscope.cn/models/livecopilot/artifacts/resolve/master'
        item = {'name': 'tokenizer/tokenizer.json', 'url': 'https://huggingface.co/a/b', 'sha256': 'a' * 64}
        module.MODEL_NAMES = {item['name']}
        self.assertEqual(module.candidates(item['url'], item), [
            'https://modelscope.cn/models/livecopilot/artifacts/resolve/master/laya/model/tokenizer/tokenizer.json',
            'https://hf-mirror.com/a/b', item['url']])
    def test_fallback_clears_failed_range_chunks(self):
        module.SOURCE = 'distribution'; module.DISTRIBUTION_BASE = 'https://example.org/models'
        item = {'name': 'x.whl', 'url': 'https://files.pythonhosted.org/packages/x.whl', 'sha256': 'a' * 64}
        with tempfile.TemporaryDirectory() as folder:
            cache = Path(folder); chunks = cache / (item['sha256'] + '.chunks'); chunks.mkdir(); (chunks / '0').write_bytes(b'bad')
            with patch.object(module, 'download_one', side_effect=[OSError('oss'), Path('ok')]):
                self.assertEqual(module.download_locked(item, cache), Path('ok'))
            self.assertFalse(chunks.exists())
    def test_transfer_bytes_include_completed_and_partial_chunks(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            chunks = root / ('a' * 64 + '.chunks'); chunks.mkdir()
            (chunks / '0').write_bytes(b'x' * 100)
            (chunks / '100.partial').write_bytes(b'x' * 50)
            item = {'sha256': 'a' * 64, 'size': 32 * 1024 * 1024}
            count, fraction = module.transfer_snapshot(item, root, root / 'temporary')
            self.assertEqual(count, 150)
            self.assertEqual(fraction, 150 / item['size'])
    def test_unknown_size_reports_bytes_without_fake_percentage(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); partial = root / 'partial'; partial.write_bytes(b'123')
            self.assertEqual(module.transfer_snapshot({}, root, partial), (3, None))
    def test_pinned_path_preserved(self):
        url = 'https://huggingface.co/owner/model/resolve/abc/file'
        self.assertEqual(module.candidates(url), [url.replace('huggingface.co', 'hf-mirror.com'), url])
        self.assertEqual(module.candidates('https://github.com/a/b'), ['https://github.com/a/b'])
    def test_original_preference(self):
        module.SOURCE = 'original'
        self.assertEqual(module.candidates('https://huggingface.co/a'), ['https://huggingface.co/a'])
    def test_only_exact_hosts_rewritten(self):
        url = 'https://huggingface.co.example.org/a'
        self.assertEqual(module.candidates(url), [url])
    def test_checksum_failure_falls_back_with_same_pin(self):
        item = {'url': 'https://huggingface.co/a', 'sha256': 'a' * 64}
        with patch.object(module, 'download_one', side_effect=[ValueError('checksum'), Path('ok')]) as fetch:
            self.assertEqual(module.download_locked(item, Path('cache')), Path('ok'))
            self.assertEqual(fetch.call_args_list[0].args[0]['sha256'], fetch.call_args_list[1].args[0]['sha256'])
            self.assertEqual(fetch.call_args_list[1].args[0]['url'], item['url'])
    def test_all_sources_fail(self):
        with patch.object(module, 'download_one', side_effect=OSError('offline')):
            with self.assertRaises(OSError):
                module.download_locked({'url':'https://huggingface.co/a'}, Path('cache'))
    def test_pypi_mirror_preserves_artifact(self):
        url='https://files.pythonhosted.org/packages/aa/wheel.whl'
        self.assertEqual(module.candidates(url)[0], 'https://mirrors.tuna.tsinghua.edu.cn/pypi/web/packages/aa/wheel.whl')
    def test_github_release_prefers_university_mirrors(self):
        url = 'https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.12.14%2B20260901-aarch64-apple-darwin-install_only_stripped.tar.gz'
        release = 'https://mirrors.ustc.edu.cn/github-release/astral-sh/python-build-standalone/20260901/cpython-3.12.14%2B20260901-aarch64-apple-darwin-install_only_stripped.tar.gz'
        addresses = module.candidates(url)
        self.assertEqual(addresses[0], release)
        self.assertEqual(addresses[1], release.replace('mirrors.ustc.edu.cn', 'mirror.nju.edu.cn'))
        self.assertEqual(addresses[-1], url)
        self.assertIn('https://gh-proxy.com/' + url, addresses)
    def test_other_release_assets_use_accelerators_before_origin(self):
        url = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx'
        self.assertEqual(module.candidates(url), [
            'https://gh-proxy.com/' + url,
            'https://hk.gh-proxy.com/' + url,
            'https://ghproxy.net/' + url,
            url])
    def test_source_archive_uses_the_only_working_accelerator(self):
        url = 'https://codeload.github.com/mizorewww/laya-mlx/tar.gz/abc'
        self.assertEqual(module.candidates(url), ['https://hk.gh-proxy.com/' + url, url])
    def test_original_preference_skips_github_mirrors(self):
        module.SOURCE = 'original'
        url = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx'
        self.assertEqual(module.candidates(url), [url])

if __name__ == '__main__': unittest.main()
