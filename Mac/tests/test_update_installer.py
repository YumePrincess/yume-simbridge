from pathlib import Path
import os,plistlib,runpy,stat,subprocess,sys,tempfile,unittest,zipfile
from unittest.mock import patch
INSTALLER=Path(__file__).resolve().parents[1]/'tools/install_update.py'
class UpdateSafetyTest(unittest.TestCase):
    def rejected(self,entries,build=1):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);archive=root/'update.zip';destination=root/'Yume SIM Hub.app';destination.mkdir();(destination/'preserved').write_text('old app')
            with zipfile.ZipFile(archive,'w') as target:
                for name,data,mode in entries:
                    entry=zipfile.ZipInfo(name);entry.external_attr=mode<<16;target.writestr(entry,data)
            result=subprocess.run([sys.executable,'-B',str(INSTALLER),'--archive',str(archive),'--destination',str(destination),'--signer','A'*40,'--current-build',str(build)],capture_output=True,text=True,env=dict(os.environ,HOME=str(root/'home')))
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

    def install_fixture(self, root, fail_stage=False):
        home=root/'home';workspace=home/'Library/Application Support/YumeSimHub/Updates'
        workspace.mkdir(parents=True)
        stale=workspace/'tmpabcdefgh';stale.mkdir();(stale/'old').write_text('partial update')
        credential=home/'Library/Application Support/YumeSimHub/credentials.json';credential.write_text('preserve')
        archive=workspace/'Yume SIM Hub 27.2.0 Build 2.zip'
        info=plistlib.dumps({'CFBundleIdentifier':'zone.yume.simhub','CFBundleVersion':'2','LSMinimumSystemVersion':'26.0','LSArchitecturePriority':['arm64']})
        with zipfile.ZipFile(archive,'w') as target:
            target.writestr('Yume SIM Hub.app/Contents/Info.plist',info)
            target.writestr('Yume SIM Hub.app/new','new app')
        destination=root/'Yume SIM Hub.app';destination.mkdir();(destination/'old').write_text('old app')
        old_backup=root/'.simhub-previous-12345678-1234-1234-1234-123456789abc.app';old_backup.mkdir()
        arguments=[str(INSTALLER),'--archive',str(archive),'--destination',str(destination),'--signer','A'*40,'--current-build','1']
        results=[subprocess.CompletedProcess([],0),subprocess.CalledProcessError(1,'codesign')] if fail_stage else [subprocess.CompletedProcess([],0)]*2
        with patch.object(sys,'argv',arguments),patch.object(sys,'path',[str(INSTALLER.parent),*sys.path]),patch('pathlib.Path.home',return_value=home),patch('subprocess.run',side_effect=results) as codesign:
            if fail_stage:
                with self.assertRaises(subprocess.CalledProcessError):runpy.run_path(str(INSTALLER),run_name='__main__')
            else:runpy.run_path(str(INSTALLER),run_name='__main__')
        self.assertEqual(codesign.call_count,2)  # Extracted bundle and copied stage.
        self.assertEqual(credential.read_text(),'preserve')
        self.assertFalse(stale.exists())
        self.assertFalse(list(root.glob('.simhub-install-*')))
        self.assertFalse(list(workspace.glob('simhub-update-*')))
        return destination,archive,old_backup

    def test_success_replaces_entire_bundle_and_cleans_packages_and_old_backups(self):
        with tempfile.TemporaryDirectory() as folder:
            destination,archive,backup=self.install_fixture(Path(folder))
            self.assertEqual((destination/'new').read_text(),'new app')
            self.assertFalse((destination/'old').exists())
            self.assertFalse(archive.exists())
            self.assertFalse(backup.exists())

    def test_stage_signature_failure_preserves_current_app_and_selected_archive(self):
        with tempfile.TemporaryDirectory() as folder:
            destination,archive,backup=self.install_fixture(Path(folder),fail_stage=True)
            self.assertEqual((destination/'old').read_text(),'old app')
            self.assertTrue(archive.exists())
            self.assertTrue(backup.exists())
if __name__=='__main__':unittest.main()
