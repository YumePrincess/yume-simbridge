import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from update_cleanup import clean_workspace,update_workspace


class CleanupTests(unittest.TestCase):
    def test_active_update_excludes_other_cleanup_and_preserves_unrelated_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            keep=root/'Yume SIM Hub 27.2.0 Build 2.zip';keep.touch()
            old=root/'Yume SIM Hub 27.2.0 Build 1.dmg';old.touch()
            unrelated=root/'my-backup.zip';unrelated.touch()
            with update_workspace(root):
                with self.assertRaises(BlockingIOError):
                    with update_workspace(root):pass
                clean_workspace(root,keep=[keep])
            self.assertTrue(keep.exists())
            self.assertTrue(unrelated.exists())
            self.assertFalse(old.exists())
            self.assertEqual(root.stat().st_mode&0o777,0o700)

    def test_release_cleanup_removes_only_older_recognized_packages(self):
        script=Path(__file__).resolve().parents[2]/'scripts/cleanup-release.py'
        spec=importlib.util.spec_from_file_location('release_cleanup',script)
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            names=['Yume SIM Hub 27.2.0 Build 1.zip','Yume SIM Hub 27.2.0 Build 2.dmg',
                   'Yume SIM Hub 27.2.0 Build 3.zip','luci-app-yume-simhub_27.2.0-1_aarch64.ipk','personal.zip']
            for name in names:(root/name).touch()
            module.clean(root,2,'mac')
            self.assertFalse((root/names[0]).exists())
            for name in names[1:]:self.assertTrue((root/name).exists())
            module.clean(root,2,'openwrt')
            self.assertFalse((root/names[3]).exists())


if __name__=='__main__':unittest.main()
