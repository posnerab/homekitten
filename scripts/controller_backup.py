#!/usr/bin/env python3
"""Read Controller's legacy .backup envelope locally; never submit HomeKit writes.

The legacy format uses fixed compatibility constants, not an account password.
Treat the decoded YAML as private: it may contain manually saved pairing codes.
No third-party packages are needed on macOS. Future formats fail closed.
"""
import argparse
import base64
import binascii
import ctypes
import datetime
import hashlib
import os
import pathlib
import sys
import uuid

from homekit_backup import BackupStore

MAX_BYTES = 32 * 1024 * 1024


def decode(data):
    if len(data) > MAX_BYTES:
        raise ValueError("Controller backup exceeds the 32 MiB input limit")
    try:
        ciphertext = base64.b64decode(data.strip(), validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("Not a supported base64 Controller backup") from error
    if not ciphertext or len(ciphertext) % 16:
        raise ValueError("Not a supported legacy AES block envelope")
    if sys.platform != "darwin":
        raise RuntimeError("Legacy decoding currently requires macOS CommonCrypto")
    crypt = ctypes.CDLL('/usr/lib/system/libcommonCrypto.dylib').CCCrypt
    crypt.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                      ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                      ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    crypt.restype = ctypes.c_int
    output = ctypes.create_string_buffer(len(ciphertext) + 16)
    count = ctypes.c_size_t()
    # Controller's legacy AES-128-CBC / PKCS7 file-format constants. These are
    # universal format parameters, never fetched from user credentials/keychains.
    status = crypt(1, 0, 1, b'passwordpassword', 16, b'drowssapdrowssap',
                   ciphertext, len(ciphertext), output, len(output), ctypes.byref(count))
    if status:
        raise ValueError("Legacy decryption failed; unsupported or damaged backup")
    try:
        yaml = output.raw[:count.value].decode('utf-8')
    except UnicodeDecodeError as error:
        raise ValueError("Decoded content is not UTF-8 YAML") from error
    if not yaml.startswith('uniqueIdentifier: ') or '\nhomeName:' not in yaml or '\naccessories:' not in yaml:
        raise ValueError("Decoded content is not the supported Controller backup schema")
    # CBC is unauthenticated; padding/schema checks are not authenticity proof.
    return yaml


def archive(data, yaml, store=None):
    store = store or BackupStore()
    record = {"version": 1, "id": str(uuid.uuid4()).upper(),
              "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "label": "Controller legacy backup archive", "status": "external_archive",
              "inventory": {"homes": []}, "request": None,
              "sourceArtifact": {"format": "controller-legacy-aes-yaml", "originalBase64": base64.b64encode(data).decode('ascii'),
                                 "originalSHA256": hashlib.sha256(data).hexdigest(), "decodedYAML": yaml},
              "limitations": ["Private Controller archive may contain pairing/setup codes, icons, ordering and other app metadata.",
                              "Legacy CBC has no authentication; checksums verify storage integrity only.",
                              "Controller UUIDs belong to its client; never substitute by name or replay as HomeKitten writes.",
                              "Archival only; this artifact cannot be used by automatic HomeKitten restore."]}
    store.write(record)
    return store.summary(record)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('backup', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path, help='New private YAML file; existing files are never overwritten')
    parser.add_argument('--archive', action='store_true', help='Retain original and decoded YAML in the checksum-verified primary/mirror backup store')
    args = parser.parse_args()
    if not args.output and not args.archive:
        parser.error('Choose --output and/or --archive; decoded private data is never printed')
    with args.backup.open('rb') as source:
        data = source.read(MAX_BYTES + 1)
    yaml = decode(data)
    if args.output:
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as output:
            output.write(yaml); output.flush(); os.fsync(output.fileno())
        print('Decoded YAML saved privately:', args.output)
    if args.archive:
        import json
        print(json.dumps(archive(data, yaml), indent=2))


if __name__ == '__main__':
    main()
