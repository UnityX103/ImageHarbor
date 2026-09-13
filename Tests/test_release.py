import base64
import importlib.util
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('make_appcast', Path(__file__).resolve().parents[1]/'scripts/make_appcast.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
class ReleaseTests(unittest.TestCase):
    def test_architecture_feeds_and_versions(self):
        config = {'version':'1.2.0','build':'1002000','minimum_macos':'13.0','repository':'example/ImageHarbor'}
        urls = []
        for arch in ['arm64','x86_64']:
            xml = module.appcast(config, arch, f'ImageHarbor-1.2.0-{arch}.zip', 500, base64.b64encode(bytes(64)).decode())
            item = ET.fromstring(xml).find('channel/item')
            urls.append(item.find('enclosure').attrib['url'])
            self.assertTrue(urls[-1].endswith(f'-{arch}.zip'))
            self.assertEqual(item.find(f'{{{module.NS}}}version').text, '1002000')
            self.assertEqual(item.find('enclosure').attrib['length'], '500')
        self.assertNotEqual(*urls)
    def test_invalid_signature_is_rejected(self):
        config = {'version':'1.2.0'}
        with self.assertRaises(AssertionError): module.appcast(config, 'arm64', 'a.zip', 1, 'YWJj')
if __name__ == '__main__': unittest.main()
