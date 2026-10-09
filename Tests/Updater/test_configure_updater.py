import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('updater', ROOT / 'scripts/configure-updater.py')
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)

class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir='/private/tmp')
        self.addCleanup(self.directory.cleanup)
        self.path = pathlib.Path(self.directory.name) / 'Info.plist'
        self.path.write_bytes(plistlib.dumps({'CFBundleVersion': '7', 'CFBundleShortVersionString': '1.2.0'}))

    def read(self):
        return plistlib.loads(self.path.read_bytes())

    def testUnconfiguredReleaseIsDisabledWithKey(self):
        with patch.dict('os.environ', {}, clear=True):
            updater.configure(self.path)
        info = self.read()
        self.assertNotIn('SUFeedURL', info)
        self.assertFalse(info['SUEnableAutomaticChecks'])
        self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])
        self.assertEqual(info['SUPublicEDKey'], updater.PUBLIC_KEY)
        self.assertEqual(info['CFBundleVersion'], '7')

    def testHTTPSProductionConfiguration(self):
        with patch.dict('os.environ', {'BOUNDAS_UPDATE_FEED_URL': 'https://example.com/appcast.xml'}, clear=True):
            updater.configure(self.path)
        self.assertEqual(self.read()['SUFeedURL'], 'https://example.com/appcast.xml')
        self.assertTrue(self.read()['SUEnableAutomaticChecks'])
        self.assertNotIn('NSAppTransportSecurity', self.read())

    def testTestBundleClearsProductionFeed(self):
        with patch.dict('os.environ', {'BOUNDAS_UPDATE_FEED_URL': 'https://example.com/appcast.xml', 'BOUNDAS_TEST_FEED_URL': 'http://127.0.0.1:8765/appcast.xml'}, clear=True):
            updater.configure(self.path)
            updater.configure(self.path, test=True)
        self.assertNotIn('SUFeedURL', self.read())
        self.assertEqual(self.read()['BoundasGateTestFeedURL'], 'http://127.0.0.1:8765/appcast.xml')
        self.assertTrue(self.read()['NSAppTransportSecurity']['NSAllowsLocalNetworking'])

    def testUnsafeProductionFeedRejectedWithoutWriting(self):
        original = self.path.read_bytes()
        for feed in ['http://example.com/feed', 'https://localhost/feed', 'https://user:password@example.com/feed']:
            with patch.dict('os.environ', {'BOUNDAS_UPDATE_FEED_URL': feed}, clear=True):
                with self.assertRaises(ValueError):
                    updater.configure(self.path)
            self.assertEqual(self.path.read_bytes(), original)

if __name__ == '__main__':
    unittest.main()
