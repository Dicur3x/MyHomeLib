"""A smaller raw JPEG must not beat a more compact PNG inside a ZIP."""
import importlib.util
from pathlib import Path
import random
import unittest

spec = importlib.util.spec_from_file_location('container_image_quality',Path(__file__).resolve().parents[1]/'image_quality.py')
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)


class ContainerSelection(unittest.TestCase):
    def setUp(self):
        noise = random.Random(38)
        self.original = b'\x89PNG\r\n\x1a\n' + noise.randbytes(4000)
        self.clearer = b'\x89PNG\r\n\x1a\n' + b'clear repeated pixels '*130
        self.smaller_raw = b'\xff\xd8\xff' + noise.randbytes(1200)
        self.profiles = {'high':[self.original],'balanced':[self.clearer],'economy':[self.smaller_raw]}

    def test_actual_container_reverses_raw_ranking(self):
        self.assertLess(len(self.smaller_raw),len(self.clearer))
        self.assertIs(quality.select_container_profiles(self.profiles,'economy','raw')['economy'][0],self.smaller_raw)
        for storage in ('epub','fb2-zip'):
            self.assertIs(quality.select_container_profiles(self.profiles,'economy',storage)['economy'][0],self.clearer)
        self.assertIs(self.profiles['economy'][0],self.smaller_raw)

    def test_estimates_use_same_choice_and_keep_clearer_ties(self):
        result=quality.select_container_profiles(self.profiles,'estimate','epub')
        self.assertIs(result['economy'][0],result['balanced'][0])
        same={'high':[self.clearer],'balanced':[bytes(bytearray(self.clearer))],
              'economy':[bytes(bytearray(self.clearer))]}
        self.assertIsNot(same['high'][0],same['balanced'][0])
        self.assertIs(quality.select_container_profiles(same,'economy','epub')['economy'][0],same['high'][0])

    def test_split_page_geometry_and_boundary_report_survive(self):
        profiles={name:[values*2] for name,values in self.profiles.items()}
        profiles['_unsplit']=[0]
        result=quality.select_container_profiles(profiles,'economy','fb2-zip',True)
        self.assertEqual(result['_unsplit'],[0])
        self.assertEqual(len(result['economy']),1)
        self.assertEqual(result['economy'][0],[self.clearer,self.clearer])

    def test_container_context_is_explicit_and_validated(self):
        self.assertEqual(quality.image_storage('.epub'),'epub')
        self.assertEqual(quality.image_storage('.epub','raw'),'raw')
        self.assertEqual(quality.image_storage('.fb2','fb2-zip'),'fb2-zip')
        with self.assertRaises(ValueError): quality.image_storage('.epub','fb2-zip')


if __name__ == '__main__': unittest.main()
