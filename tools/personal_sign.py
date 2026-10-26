#!/usr/bin/env python3
"""Sign your built app with your own Apple ID's profile, and optionally install it.

    uv run python tools/personal_sign.py --app APP --output SIGNED_APP [--profile FILE] [--install --device ID]

Without --profile, the newest unexpired profile Xcode saved for the app's bundle
ID is used. Make one by running any iOS app with that bundle ID on your iPhone
from Xcode, signed in with your Apple ID (see the README). Signing uses an
identity already in your keychain; nothing signs in, uploads or uninstalls.
Installing replaces an existing app with the same bundle ID in place, keeping
its imported content and saves.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.personal_build import BuildError, outside_repo

PROFILE_DIRECTORIES = [Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles',
                       Path.home() / 'Library/MobileDevice/Provisioning Profiles']


def read_profile(path: Path) -> dict:
    decoded = subprocess.run(['security', 'cms', '-D', '-i', str(path)], capture_output=True, check=True).stdout
    return plistlib.loads(decoded)


def team_of(profile: dict) -> str:
    teams = profile.get('TeamIdentifier') or []
    if len(teams) != 1 or not re.fullmatch(r'[A-Z0-9]{10}', teams[0]):
        raise BuildError('Provisioning profile has no single team')
    return teams[0]


def covers(profile: dict, bundle_id: str, device: str | None = None, now: datetime | None = None) -> bool:
    """Whether this profile can sign `bundle_id` (exactly or by wildcard) for `device` right now."""
    now = now or datetime.now(timezone.utc)
    expires = profile.get('ExpirationDate')
    if not isinstance(expires, datetime) or expires.replace(tzinfo=timezone.utc) <= now:
        return False
    if 'iOS' not in profile.get('Platform', ['iOS']):
        return False
    team = team_of(profile)
    pattern = str(profile.get('Entitlements', {}).get('application-identifier', ''))
    if not pattern.startswith(team + '.'):
        return False
    pattern = pattern[len(team) + 1:]
    if pattern != bundle_id and not (pattern.endswith('*') and bundle_id.startswith(pattern[:-1])):
        return False
    if device and not profile.get('ProvisionsAllDevices') and device not in profile.get('ProvisionedDevices', []):
        return False
    return True


def find_profile(bundle_id: str, device: str | None, directories=None, reader=read_profile):
    """Prefer an exact App ID over a wildcard, then the latest expiry."""
    found = []
    for directory in directories or PROFILE_DIRECTORIES:
        for path in sorted(Path(directory).glob('*.mobileprovision')) if Path(directory).is_dir() else []:
            try:
                profile = reader(path)
            except (subprocess.CalledProcessError, plistlib.InvalidFileException, BuildError):
                continue
            if covers(profile, bundle_id, device):
                exact = profile['Entitlements']['application-identifier'].endswith('.' + bundle_id)
                found.append((exact, profile['ExpirationDate'], path, profile))
    if not found:
        raise BuildError(f'No unexpired provisioning profile for {bundle_id}' + (f' and device {device}' if device else '') +
                         '. Run an app with this bundle ID on your iPhone from Xcode once, then try again.')
    found.sort(key=lambda row: (row[0], row[1]))
    return found[-1][2], found[-1][3]


def signing_identity(profile: dict, listing: str | None = None) -> str:
    """The keychain identity whose certificate the profile names."""
    certificates = {hashlib.sha1(der).hexdigest().upper() for der in profile.get('DeveloperCertificates', [])}
    if listing is None:
        listing = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                                 capture_output=True, text=True, check=True).stdout
    for match in re.finditer(r'\b([0-9A-F]{40})\b', listing):
        if match.group(1) in certificates:
            return match.group(1)
    raise BuildError("The profile's signing certificate is not in your keychain. "
                     'Sign in to Xcode with the same Apple ID that made the profile.')


def entitlements(profile: dict, bundle_id: str) -> dict:
    team = team_of(profile)
    return {'application-identifier': f'{team}.{bundle_id}', 'com.apple.developer.team-identifier': team,
            'get-task-allow': bool(profile.get('Entitlements', {}).get('get-task-allow', False))}


def sign(app: Path, output: Path, profile_path: Path | None, device: str | None):
    app, output = outside_repo(app), outside_repo(output)
    if output.exists() or output.is_symlink() or not output.parent.is_dir() or output.suffix != '.app':
        raise BuildError('Give a new .app path for the signed copy, in an existing folder')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    bundle_id = info.get('CFBundleIdentifier')
    if info.get('DTPlatformName') != 'iphoneos' or not isinstance(bundle_id, str):
        raise BuildError('Sign the iPhone build (build-iphoneos), not the Simulator build')
    if profile_path is None:
        profile_path, profile = find_profile(bundle_id, device)
    else:
        profile = read_profile(outside_repo(profile_path))
        if not covers(profile, bundle_id, device):
            raise BuildError(f'This profile is expired or does not cover {bundle_id}' + (f' on {device}' if device else ''))
    identity = signing_identity(profile)
    subprocess.run(['ditto', str(app), str(output)], check=True)
    (output / 'embedded.mobileprovision').write_bytes(Path(profile_path).read_bytes())
    with tempfile.NamedTemporaryFile('wb', suffix='.plist', delete=False) as stream:
        plistlib.dump(entitlements(profile, bundle_id), stream)
        entitlement_path = Path(stream.name)
    try:
        subprocess.run(['codesign', '--force', '--sign', identity, '--entitlements', str(entitlement_path),
                        '--timestamp=none', str(output)], check=True)
    finally:
        entitlement_path.unlink(missing_ok=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(output)], check=True)
    return {'app': str(output), 'bundle_id': bundle_id, 'team': team_of(profile),
            'profile': profile.get('Name'), 'profile_uuid': profile.get('UUID'),
            'expires': profile['ExpirationDate'].replace(tzinfo=timezone.utc).isoformat(), 'identity': identity}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--app', type=Path, required=True, help='build-iphoneos/protector_ios_interactive.app')
    parser.add_argument('--output', type=Path, required=True, help='new path for the signed .app')
    parser.add_argument('--profile', type=Path, help='a .mobileprovision; default: newest matching one from Xcode')
    parser.add_argument('--device', help='device identifier from `xcrun devicectl list devices`')
    parser.add_argument('--install', action='store_true', help='install over the existing app on --device')
    args = parser.parse_args()
    try:
        if args.install and not args.device:
            raise BuildError('--install needs --device')
        result = sign(args.app, args.output, args.profile, args.device)
        if args.install:
            subprocess.run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', args.device, result['app']],
                           check=True)
            result['installed_on'] = args.device
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(2, f'Personal signing: {error}\n')


if __name__ == '__main__':
    main()
