import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('download_installer', Path(__file__).parents[1] / 'Resources/LayaRuntime/install.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class DownloadTests(unittest.TestCase):
    def setUp(self): module.SOURCE = 'mirror'
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

if __name__ == '__main__': unittest.main()
