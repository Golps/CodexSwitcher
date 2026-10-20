"""Regression checks using generated, non-routable synthetic fixtures only."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

CHECK = Path(__file__).resolve().parents[1] / 'scripts/check-privacy.py'


class PrivacyCheck(unittest.TestCase):
    def run_check(self, root, *options):
        return subprocess.run([sys.executable, str(CHECK), str(root), *options],
                              capture_output=True, text=True)

    def fixture(self, name, content):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / name).write_text(content)
        return root

    def test_synthetic_account_is_allowed(self):
        root = self.fixture('README.md', 'Demo account: personal@example.com')
        self.assertEqual(self.run_check(root).returncode, 0)

    def test_home_path_is_blocked_without_echoing_its_value(self):
        value = '/' + 'Users/' + 'fixture-user/Project'
        result = self.run_check(self.fixture('README.md', value))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(value, result.stdout)

    def test_personal_email_provider_is_blocked(self):
        value = 'fixture' + '@' + 'outlook.invalid'
        result = self.run_check(self.fixture('README.md', value))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(value, result.stdout)

    def test_private_notes_are_blocked(self):
        self.assertNotEqual(self.run_check(self.fixture('HANDOFF.md', 'Internal notes')).returncode, 0)

    def test_credential_pattern_is_blocked_without_echoing_value(self):
        value = 'sk-' + 'proj-' + 'SYNTHETIC' * 5
        result = self.run_check(self.fixture('sample.txt', value))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(value, result.stdout)

    def test_symlink_is_blocked(self):
        root = self.fixture('README.md', 'Clean source')
        (root / 'linked.txt').symlink_to('README.md')
        self.assertNotEqual(self.run_check(root).returncode, 0)

    def test_commit_and_committer_metadata_are_checked(self):
        root = self.fixture('README.md', 'Clean source')
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        subprocess.run(['git', '-C', str(root), 'add', 'README.md'], check=True)
        env = dict(os.environ, GIT_AUTHOR_NAME='Golps', GIT_COMMITTER_NAME='Golps',
                   GIT_AUTHOR_EMAIL='0+fixture@users.noreply.github.com',
                   GIT_COMMITTER_EMAIL='0+fixture@users.noreply.github.com')
        subprocess.run(['git', '-C', str(root), '-c', 'commit.gpgsign=false',
                        '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'Synthetic fixture'],
                       env=env, check=True)
        self.assertEqual(self.run_check(root, '--git-metadata').returncode, 0)
        env['GIT_COMMITTER_EMAIL'] = 'fixture' + '@' + 'outlook.invalid'
        subprocess.run(['git', '-C', str(root), '-c', 'commit.gpgsign=false',
                        '-c', 'core.hooksPath=/dev/null', 'commit', '--allow-empty', '-qm',
                        'Synthetic committer fixture'], env=env, check=True)
        self.assertNotEqual(self.run_check(root, '--git-metadata').returncode, 0)


if __name__ == '__main__':
    unittest.main()
