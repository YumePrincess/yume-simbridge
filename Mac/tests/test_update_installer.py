from pathlib import Path
import plistlib,stat,subprocess,sys,tempfile,unittest,zipfile
INSTALLER=Path(__file__).resolve().parents[1]/'tools/install_update.py'
class UpdateSafetyTest(unittest.TestCase):
    def rejected(self,entries,build=1):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);archive=root/'update.zip';destination=root/'Yume SIM Hub.app';destination.mkdir();(destination/'preserved').write_text('old app')
            with zipfile.ZipFile(archive,'w') as target:
                for name,data,mode in entries:
                    entry=zipfile.ZipInfo(name);entry.external_attr=mode<<16;target.writestr(entry,data)
            result=subprocess.run([sys.executable,str(INSTALLER),'--archive',str(archive),'--destination',str(destination),'--signer','A'*40,'--current-build',str(build)],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual((destination/'preserved').read_text(),'old app')
            self.assertFalse((root/'outside').exists())
            return result.stderr
    def test_zip_path_traversal_is_rejected(self):
        self.assertIn('Unsafe',self.rejected([('../outside',b'bad',stat.S_IFREG|0o644)]))
    def test_zip_symlinks_are_rejected(self):
        self.assertIn('Unsafe',self.rejected([('Yume SIM Hub.app/link',b'../../outside',stat.S_IFLNK|0o777)]))
    def test_same_build_does_not_replace_existing_app(self):
        info=plistlib.dumps({'CFBundleIdentifier':'zone.yume.simhub','CFBundleVersion':'2'})
        self.assertIn('newer',self.rejected([('Yume SIM Hub.app/Contents/Info.plist',info,stat.S_IFREG|0o644)],build=2))
    def test_unsigned_bundle_does_not_replace_existing_app(self):
        info=plistlib.dumps({'CFBundleIdentifier':'zone.yume.simhub','CFBundleVersion':'2','LSMinimumSystemVersion':'26.0','LSArchitecturePriority':['arm64']})
        self.assertIn('signature',self.rejected([('Yume SIM Hub.app/Contents/Info.plist',info,stat.S_IFREG|0o644)]))
if __name__=='__main__':unittest.main()
