#!/usr/bin/env python3
"""Check an explicit publication directory without printing matched values."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory', type=Path)
parser.add_argument('--git-metadata', action='store_true')
parser.add_argument('--require-gitleaks', action='store_true')
args = parser.parse_args()
root = args.directory.resolve()
if not root.is_dir():
    parser.error('Publication directory does not exist')

patterns = {
    'absolute user-home path': re.compile(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/|[A-Z]:\\Users\\[^\\\s]+\\'),
    'personal email provider': re.compile(rb'[A-Za-z0-9._%+-]+@(?:gmail|icloud|hotmail|outlook|yahoo|protonmail|proton)\.[A-Za-z]{2,}', re.I),
    'private key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'),
    'provider credential': re.compile(rb'\b(?:sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[A-Z0-9]{16})'),
}
private_names = {'handoff.md', 'auth.json', 'credentials.json', '.env', '.env.local'}
private_suffixes = {'.p12', '.pfx', '.pem', '.key', '.log'}
denied_parts = {'work', 'release', 'node_modules', '.codex', '.claude', '.private'}
failures = []
checked = 0
personal_terms = [Path.home().name] + os.environ.get('PRIVACY_DENY_TERMS', '').split(',')
personal_terms = [re.sub(r'[^a-z0-9]', '', x.lower()) for x in personal_terms
                  if len(x.strip()) >= 6 and x.lower() not in {'runner', 'runneradmin', 'root', 'oai'}]
for path in sorted(root.rglob('*')):
    rel = path.relative_to(root)
    if '.git' in rel.parts:
        continue
    if path.is_symlink():
        failures.append((str(rel), 'symlink requires explicit review'))
        continue
    if not path.is_file():
        continue
    checked += 1
    if (path.name.lower() in private_names or path.suffix.lower() in private_suffixes
            or any(x.lower() in denied_parts for x in rel.parts)):
        failures.append((str(rel), 'private/working material'))
    data = path.read_bytes()
    for kind, regex in patterns.items():
        if regex.search(data):
            failures.append((str(rel), kind))
    normalized = re.sub(r'[^a-z0-9]', '', data.decode('utf-8', errors='ignore').lower())
    if any(term in normalized for term in personal_terms):
        failures.append((str(rel), 'local personal identifier'))

if args.git_metadata:
    output = subprocess.check_output([
        'git', '-C', str(root), 'log', '--all', '--format=%aN%x00%aE%x00%cN%x00%cE'
    ]).decode().splitlines()
    for line in output:
        fields = line.split('\0')
        for name, email in [(fields[0], fields[1]), (fields[2], fields[3])]:
            if name not in {'Golps', 'github-actions[bot]'} or not email.endswith('@users.noreply.github.com'):
                failures.append(('Git metadata', 'unapproved public author/committer identity'))
                break

scanner = shutil.which('gitleaks')
if scanner:
    result = subprocess.run([
        scanner, 'dir', str(root), '--redact=100', '--no-banner',
        '--ignore-gitleaks-allow', '--max-archive-depth=3'
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        failures.append(('Gitleaks', 'credential scan found a candidate or could not complete'))
elif args.require_gitleaks:
    failures.append(('Gitleaks', 'required scanner is unavailable'))

for path, kind in sorted(set(failures)):
    print(f'BLOCKED: {path}: {kind}')
print(f'Privacy review: {checked} files; {len(set(failures))} blocking findings')
if not scanner:
    print('Credential scanner was not available; pattern checks alone are incomplete.')
sys.exit(bool(failures))
