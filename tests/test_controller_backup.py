import base64
import ctypes
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / 'scripts'))
import controller_backup as controller
from homekit_backup import BackupStore


@unittest.skipUnless(sys.platform == 'darwin', 'CommonCrypto requires macOS')
class ControllerBackupTests(unittest.TestCase):
    def envelope(self, content):
        data = content.encode()
        crypt = ctypes.CDLL('/usr/lib/system/libcommonCrypto.dylib').CCCrypt
        crypt.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                          ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                          ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
        output = ctypes.create_string_buffer(len(data) + 16)
        count = ctypes.c_size_t()
        self.assertEqual(crypt(0, 0, 1, b'passwordpassword', 16, b'drowssapdrowssap', data, len(data), output, len(output), ctypes.byref(count)), 0)
        return base64.b64encode(output.raw[:count.value])

    def test_decode_and_archive_keep_source_and_all_unknown_fields_without_home_writes(self):
        yaml = 'uniqueIdentifier: example\nhomeName: fixture\naccessories: []\nunknownFutureField: keep\n'
        original = self.envelope(yaml)
        self.assertEqual(controller.decode(original), yaml)
        with tempfile.TemporaryDirectory() as temp:
            store = BackupStore(temp)
            result = controller.archive(original, yaml, store)
            record = store.load(result['id'])
            self.assertEqual(record['sourceArtifact']['decodedYAML'], yaml)
            self.assertEqual(base64.b64decode(record['sourceArtifact']['originalBase64']), original)
            self.assertEqual(record['inventory']['homes'], [])
            self.assertEqual(record['status'], 'external_archive')
            self.assertEqual(store.path(result['id']).stat().st_mode & 0o777, 0o600)

    def test_unsupported_corrupt_and_non_schema_content_fail_closed(self):
        for value in (b'bad!', base64.b64encode(b'tiny'), self.envelope('not a Controller schema')):
            with self.assertRaises(ValueError): controller.decode(value)
        value = bytearray(base64.b64decode(self.envelope('uniqueIdentifier: x\nhomeName: y\naccessories: []\n')))
        value[-1] ^= 0x7f
        with self.assertRaises(ValueError): controller.decode(base64.b64encode(value))
