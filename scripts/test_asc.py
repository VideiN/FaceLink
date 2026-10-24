"""asc.py 시험 (네트워크 없이 되는 부분만). python3 -m unittest discover -s scripts -v"""

import json
import os
import tempfile
import unittest

import asc


def der(r, s):
    """ECDSA 서명 DER: SEQUENCE { INTEGER r, INTEGER s }"""
    def integer(value):
        body = value.lstrip(b"\0") or b"\0"
        if body[0] & 0x80:
            body = b"\0" + body
        return bytes([0x02, len(body)]) + body
    content = integer(r) + integer(s)
    return bytes([0x30, len(content)]) + content


class DerToRawTests(unittest.TestCase):
    def test_plain_values(self):
        r, s = bytes(range(1, 33)), bytes(range(33, 65))
        self.assertEqual(asc.der_to_raw(der(r, s)), r + s)

    def test_high_bit_gets_leading_zero_in_der_but_not_in_jwt(self):
        r, s = b"\xff" * 32, b"\x80" + b"\x01" * 31
        encoded = der(r, s)
        self.assertEqual(encoded[3], 33)
        self.assertEqual(asc.der_to_raw(encoded), r + s)

    def test_short_values_are_padded_to_32_bytes(self):
        r, s = b"\0\0" + b"\x11" * 30, b"\0" * 31 + b"\x05"
        self.assertEqual(asc.der_to_raw(der(r, s)), r + s)

    def test_rejects_other_formats(self):
        with self.assertRaises(ValueError):
            asc.der_to_raw(b"\x31\x00")


class UploadResultTests(unittest.TestCase):
    def check(self, content):
        handle, path = tempfile.mkstemp(suffix=".json")
        try:
            with os.fdopen(handle, "w") as file:
                file.write(content)
            return asc.upload_result(path)
        finally:
            os.remove(path)

    def test_success(self):
        self.assertTrue(self.check(json.dumps({"success-message": "No errors uploading", "os-version": "26"})))

    def test_product_errors_fail_even_with_success_message(self):
        result = {"success-message": "No errors uploading", "product-errors": [{"message": "90502"}]}
        self.assertFalse(self.check(json.dumps(result)))

    def test_no_success_message_fails(self):
        self.assertFalse(self.check(json.dumps({"product-errors": [{"message": "auth"}]})))

    def test_empty_or_broken_output_fails(self):
        self.assertFalse(self.check(""))
        self.assertFalse(self.check("Error: something"))


if __name__ == "__main__":
    unittest.main()
