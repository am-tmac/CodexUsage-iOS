"""Checks actual Xcode expansion, without importing a signing identity."""
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]

class SigningConfigurationTests(unittest.TestCase):
    def test_profile_bundle_ids_and_shared_groups_expand_per_target(self):
        result = subprocess.run([
            'xcodebuild', '-project', 'CodexUsage.xcodeproj', '-alltargets',
            '-configuration', 'Release', '-sdk', 'iphoneos', '-showBuildSettings', '-json',
            'CODE_SIGNING_ALLOWED=NO', 'CODEX_APP_BUNDLE_IDENTIFIER=com.example.CodexUsage',
            'APP_GROUP_IDENTIFIER=group.com.example.CodexUsage',
            'KEYCHAIN_GROUP_IDENTIFIER=com.example.CodexUsage.shared',
            'AppIdentifierPrefix=YOURTEAMID.',
        ], cwd=ROOT, capture_output=True, text=True, check=True)
        targets = {t['target']: t['buildSettings'] for t in json.loads(result.stdout)}
        for target, bundle in [('CodexUsage', 'com.example.CodexUsage'),
                               ('CodexUsageWidget', 'com.example.CodexUsage.Widget')]:
            with self.subTest(target=target):
                s = targets[target]
                self.assertEqual(s['PRODUCT_BUNDLE_IDENTIFIER'], bundle)
                self.assertEqual(s['APP_GROUP_IDENTIFIER'], 'group.com.example.CodexUsage')
                self.assertEqual(s['AppIdentifierPrefix'] + s['KEYCHAIN_GROUP_IDENTIFIER'],
                                 'YOURTEAMID.com.example.CodexUsage.shared')

if __name__ == '__main__':
    unittest.main()
