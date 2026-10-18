import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('proof', Path(__file__).with_name('hosted-public-release') / 'static-proof.py')
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class StaticProofTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self):
        self.temporary.cleanup()

    def file(self, name, data):
        path = self.root/name
        path.write_bytes(data)
        path.chmod(0o600)
        return path

    def test_stable_file(self):
        data = b'synthetic bytes'
        self.assertEqual(proof.file_hash(self.file('document',data)), {'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})

    def test_fifo_does_not_block(self):
        path = self.root/'fifo'
        os.mkfifo(path,0o600)
        with self.assertRaises(ValueError):
            proof.file_hash(path)

    def test_hard_link_is_rejected(self):
        path = self.file('document',b'one')
        os.link(path,self.root/'second')
        with self.assertRaises(ValueError):
            proof.file_hash(path)

    def test_mutation_with_restored_size_and_mtime(self):
        path = self.file('document',b'one')
        before = path.stat()
        def mutation():
            path.write_bytes(b'two')
            os.utime(path,ns=(before.st_atime_ns,before.st_mtime_ns))
        with self.assertRaises(ValueError):
            proof.file_hash(path,after_read=mutation)

    def test_replaced_path(self):
        path = self.file('document',b'one')
        replacement = self.file('replacement',b'one')
        with self.assertRaises(ValueError):
            proof.file_hash(path,after_read=lambda:os.replace(replacement,path))

    def test_duplicate_json_key(self):
        with self.assertRaises(ValueError):
            proof.document(self.file('document',b'{"schema":1,"schema":1}'))

    def test_escaped_duplicate_document_key_is_rejected(self):
        with self.assertRaises(ValueError):
            proof.document(self.file('document', b'{"schema":1,"\\u0073chema":2}'))

    def test_ci_artifact_extraction_is_closed_crc_checked_and_private(self):
        outer = self.file('outer.zip', b'placeholder')
        with zipfile.ZipFile(outer, 'w') as archive:
            archive.writestr('host-release-proof.json', b'{"schema":1}')
            archive.writestr('build-metadata.json', b'{"source":"synthetic"}')
        destination = self.root / 'extracted'
        receipt = proof.extract_artifact(outer, destination, ['host-release-proof.json', 'build-metadata.json'])
        self.assertTrue(receipt['zipCRCVerified'])
        self.assertEqual(proof.document(destination / 'host-release-proof.json'), {'schema': 1})
        self.assertEqual((destination / 'build-metadata.json').stat().st_mode & 0o777, 0o600)
        with self.assertRaises(ValueError):
            proof.extract_artifact(outer, self.root / 'missing', ['host-release-proof.json'])
        with zipfile.ZipFile(outer, 'w') as archive:
            archive.writestr('../foreign', b'synthetic')
        with self.assertRaises(ValueError):
            proof.extract_artifact(outer, self.root / 'traversal', ['../foreign'])
        self.assertFalse((self.root / 'foreign').exists())

    def original(self):
        value = plistlib.dumps({'CFBundleShortVersionString':'1.0.0','CFBundleVersion':'1','CFBundleIdentifier':'fixture'})
        return {'Resources/Info.plist':value,'Resources/HelperInfo.plist':value,'Casks/edith.rb':b'cask "edith" do\n  version "1.0.0"\n  sha256 "old"\nend\n'}

    def child(self, original):
        value = plistlib.dumps({'CFBundleShortVersionString':'1.1.0','CFBundleVersion':'2','CFBundleIdentifier':'fixture'})
        return {'Resources/Info.plist':value,'Resources/HelperInfo.plist':value,'Casks/edith.rb':b'cask "edith" do\n  version "1.1.0"\n  sha256 "'+b'a'*64+b'"\nend\n'}

    def qualify(self, original, changed, parents=None):
        return proof.version_child(original,changed,parents if parents is not None else ['1'*40],'1'*40,'1.1.0','2','a'*64)

    def test_exact_three_file_child(self):
        original = self.original()
        self.assertEqual(self.qualify(original,self.child(original)),'version-stamp-child')

    def test_truly_changed_subset(self):
        original = self.original()
        changed = self.child(original)
        original['Resources/Info.plist']=changed.pop('Resources/Info.plist')
        original['Resources/HelperInfo.plist']=changed.pop('Resources/HelperInfo.plist')
        self.assertEqual(self.qualify(original,changed),'version-stamp-child')

    def test_wrong_and_multiple_parent(self):
        original=self.original()
        for parents in [['2'*40],['1'*40,'2'*40],[]]:
            with self.assertRaises(ValueError):
                self.qualify(original,self.child(original),parents)

    def test_extra_file_key_source_and_cask_changes(self):
        original=self.original()
        for variation in ['file','key','source','cask']:
            changed=self.child(original)
            if variation=='file':changed['Sources/Extra.swift']=b'fixture'
            if variation in ('key','source'):
                value=plistlib.loads(changed['Resources/Info.plist'])
                value['Extra' if variation=='key' else 'CFBundleIdentifier']='changed'
                changed['Resources/Info.plist']=plistlib.dumps(value)
            if variation=='cask':changed['Casks/edith.rb']+=b'changed\n'
            with self.assertRaises(ValueError):self.qualify(original,changed)

    def test_zip_expanded_bytes_and_traversal(self):
        for name in ['fixture/data.json','fixture/../escape']:
            archive=self.root/'package.zip'
            with zipfile.ZipFile(archive,'w') as target:target.writestr(name,b'{}')
            archive.chmod(0o600)
            data=archive.read_bytes()
            if '..' in name:
                with self.assertRaises(ValueError):proof.archive_metrics(archive,'fixture',len(data),hashlib.sha256(data).hexdigest())
            else:
                result=proof.archive_metrics(archive,'fixture',len(data),hashlib.sha256(data).hexdigest())
                self.assertEqual(result['installedBytes'],2)
                self.assertFalse(result['codeExecuted'])

    def test_raw_tag_object_and_current_main(self):
        source = '1'*40
        plist = self.child(self.original())['Resources/Info.plist']
        cask = self.child(self.original())['Casks/edith.rb']
        for kind, main in [(b'commit',source),(b'tag',source),(b'commit','2'*40)]:
            def git(arguments, **options):
                action = arguments[3:]
                if action[0] == 'cat-file':return kind+b'\n'
                if action[0] == 'rev-parse':return (main if action[1]=='refs/remotes/origin/main' else source).encode()+b'\n'
                return cask if action[-1].endswith('Casks/edith.rb') else plist
            with patch.object(proof.subprocess,'check_output',git):
                if kind == b'commit' and main == source:
                    self.assertEqual(proof.qualify_tag(self.root,source,'v1.1.0','1.1.0','2','a'*64)['tagMode'],'direct-source')
                else:
                    with self.assertRaises(ValueError):proof.qualify_tag(self.root,source,'v1.1.0','1.1.0','2','a'*64)

    def test_host_proof_source_identity_size_and_tier(self):
        dmg = self.file('Edith.dmg',b'synthetic DMG bytes')
        appcast = self.file('appcast.xml',b'synthetic appcast bytes')
        dmg_hash = proof.file_hash(dmg)
        source, index, team = '1'*40, '2'*64, 'ABCDEFGHIJ'
        key = 'ZmEn7Nvq56SkxwSOm7ey0kyBdFERSQgDywlDCuvxZgk='
        value = {'schema':1,'sourceCommit':source,'workflowSourceCommit':source,'sourceMode':'current-workflow-source','version':'1.1.0','build':'2','indexSHA256':index,'sparklePublicKey':key,'certificateCategory':'Developer ID Application','teamIdentifier':team,'verifiedDesignatedRequirement':f'identifier "com.pulkit.edith" and anchor apple generic and certificate leaf[subject.OU] = "{team}"','installedBytes':9000000,'extensionPayloadBytes':0,'indexedExtensions':39,'hostExecutableSHA256':'3'*64,'deepStrictSignatureVerified':True,'sparkleEd25519Verified':True,'publicationVerified':False,'managedViewsVerified':False,'hardwareVerified':False,'sourceQualification':'clean','notarization':'skipped','dmgBytes':dmg_hash['bytes'],'dmgSHA256':dmg_hash['sha256'],'appcastSHA256':proof.file_hash(appcast)['sha256'],'dmgURL':'https://github.com/pulkitxm/edith/releases/download/v1.1.0/Edith.dmg'}
        def check(record):return proof.host_proof(record,source,'1.1.0','2',index,key,team,'Developer ID Application',dmg,appcast)
        self.assertEqual(check(value)['installedBytes'],9000000)
        for field, changed in [('sourceCommit','4'*40),('indexedExtensions',38),('installedBytes',10000000),('extensionPayloadBytes',1),('certificateCategory','Apple Development'),('teamIdentifier','XXXXXXXXXX'),('sourceMode','tag-rebuild'),('publicationVerified',True),('sourceQualification','dirty'),('dmgSHA256','5'*64),('unknown',1)]:
            with self.assertRaises(ValueError):check({**value,field:changed})


if __name__ == '__main__':
    unittest.main()
