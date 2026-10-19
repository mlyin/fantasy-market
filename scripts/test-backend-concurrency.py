"""Harness guard checks; these do not exercise any backend RPC."""
import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('concurrency', Path(__file__).with_name('backend-concurrency.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class LocalGuardTests(unittest.TestCase):
    @patch.dict(os.environ, {}, clear=True)
    def test_accepts_explicit_disposable_loopback(self):
        for host in ('localhost', '127.0.0.1', '::1'):
            dsn = f'host={host} dbname=fantasy_market_concurrency_test'
            self.assertEqual(module.checked_dsn(dsn), dsn)

    @patch.dict(os.environ, {}, clear=True)
    def test_rejects_remote_missing_and_redirected_targets(self):
        for dsn in ('', 'host=production dbname=fantasy_market_concurrency_test',
                    'host=localhost dbname=postgres',
                    'host=localhost dbname=fantasy_market_concurrency_test hostaddr=192.0.2.1',
                    'host=localhost dbname=fantasy_market_concurrency_test service=production'):
            with self.subTest(dsn=dsn), self.assertRaises(ValueError):
                module.checked_dsn(dsn)

    def test_rejects_environment_redirection(self):
        for key in ('PGHOSTADDR','PGSERVICE'):
            with patch.dict(os.environ, {key:'production'}, clear=True), self.assertRaises(ValueError):
                module.checked_dsn('host=localhost dbname=fantasy_market_concurrency_test')

if __name__ == '__main__':
    unittest.main()
