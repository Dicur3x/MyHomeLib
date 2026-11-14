"""Explicit read-only real-book check; never part of a synthetic-only run."""
import os
import unittest

from test_native_external_formats import NativeExternalFormatTests


@unittest.skipUnless(os.environ.get('HL_REAL_EPUB_ARCHIVE'), 'Select an explicit read-only real EPUB archive')
class NativeRealEpubCompressionTests(NativeExternalFormatTests):
    def test_selected_real_book_compresses_and_remains_complete(self):
        self.check_real_flibrary_epub()


for _name in dir(NativeExternalFormatTests):
    if _name.startswith('test_'):
        setattr(NativeRealEpubCompressionTests, _name, None)
del NativeExternalFormatTests
