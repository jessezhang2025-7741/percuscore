import importlib.util
from pathlib import Path
import unittest
import tempfile
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from scripts.large_pdf_benchmark_support import fixture_identity

class BenchmarkContract(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('benchmark', Path(__file__).with_name('run_large_pdf_benchmark.py'))
        self.module = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.module)
    def test_fixture_identity_changes_with_same_size_content(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / 'scan.pdf'
            fixture.write_bytes(b'first')
            first = fixture_identity(fixture)
            fixture.write_bytes(b'other')
            self.assertNotEqual(first, fixture_identity(fixture))
    def test_rejects_missing_fixture(self):
        with self.assertRaisesRegex(ValueError, 'fixture'): self.module.validate('/missing.pdf', 5)
    def test_rejects_zero_runs(self):
        with self.assertRaisesRegex(ValueError, 'runs'): self.module.validate(__file__, 0)
    def test_missing_timing_is_not_a_successful_run(self):
        with self.assertRaises(ValueError): self.module.summarize([{'open_ms': 1}])

if __name__ == '__main__': unittest.main()
