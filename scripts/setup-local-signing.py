#!/usr/bin/env python3
"""Opt-in, per-user development signing. Never grants Accessibility or system trust."""
import hashlib
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import tempfile

ROOT = Path.home() / 'Library/Application Support/DJI Mic Remote/Signing'


def run(*args):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        # Do not include command arguments: security requires a keychain password.
        raise SystemExit(f'{Path(args[0]).name} failed: {result.stdout.strip()}')
    return result.stdout


def main():
    os.umask(0o077)
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    keychain = ROOT / 'development.keychain-db'
    certificate = ROOT / 'certificate.pem'
    password_file = ROOT / 'keychain-password'
    identity_file = ROOT / 'identity.txt'
    # Keep a partial identity on failure so retrying cannot silently rotate it.
    with tempfile.TemporaryDirectory(prefix='dji-signing-') as temporary:
        temp = Path(temporary)
        if not certificate.exists():
            if keychain.exists():
                raise SystemExit('An incomplete signing keychain already exists. Inspect it before creating another identity.')
            password_file.write_text(secrets.token_hex(32))
            config = temp / 'openssl.conf'
            config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=extensions\nprompt=no\n'
                              '[dn]\nCN=DJI Mic Remote Local Development\n'
                              '[extensions]\nbasicConstraints=critical,CA:TRUE\n'
                              'keyUsage=critical,digitalSignature,keyCertSign\n'
                              'extendedKeyUsage=critical,codeSigning\n')
            key = temp / 'private.pem'
            run('/usr/bin/openssl', 'req', '-new', '-newkey', 'rsa:3072', '-nodes', '-x509', '-sha256',
                '-days', '3650', '-config', str(config), '-keyout', str(key), '-out', str(certificate))
            # Retain only the encrypted identity until its keychain import succeeds.
            run('/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(certificate),
                '-out', str(ROOT / 'pending.p12'), '-passout', 'file:' + str(password_file))
        password = password_file.read_text().strip()
        if not keychain.exists():
            run('/usr/bin/security', 'create-keychain', '-p', password, str(keychain))
        run('/usr/bin/security', 'unlock-keychain', '-p', password, str(keychain))
        if (ROOT / 'pending.p12').exists():
            run('/usr/bin/security', 'import', str(ROOT / 'pending.p12'), '-k', str(keychain),
                '-P', password, '-T', '/usr/bin/codesign')
            run('/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s',
                '-k', password, str(keychain))
            (ROOT / 'pending.p12').unlink()
        # User-domain trust, constrained to the code-signing policy and codesign
        # executable. No SSL trust, system roots, Gatekeeper, or TCC changes.
        run('/usr/bin/security', 'add-trusted-cert', '-r', 'trustRoot', '-p', 'codeSign',
            '-a', '/usr/bin/codesign', '-k', str(keychain), str(certificate))
        der = temp / 'certificate.der'
        run('/usr/bin/openssl', 'x509', '-in', str(certificate), '-outform', 'DER', '-out', str(der))
        identity = hashlib.sha1(der.read_bytes()).hexdigest().upper()
        if identity_file.exists() and identity_file.read_text().strip() != identity:
            raise SystemExit('The configured identity does not match its certificate. Refusing to replace it.')
        # --keychain limits identity lookup, but codesign still uses the user
        # search list to resolve the certificate's scoped trust. Preserve every
        # existing keychain and its ordering when registering our own.
        search_list = shlex.split(run('/usr/bin/security', 'list-keychains', '-d', 'user'))
        if str(keychain) not in search_list:
            run('/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *search_list, str(keychain))
        verified_list = shlex.split(run('/usr/bin/security', 'list-keychains', '-d', 'user'))
        if str(keychain) not in verified_list or any(path not in verified_list for path in search_list):
            raise SystemExit('The signing keychain search list could not be verified.')
        # Prove the identity can sign before making it the build default.
        source = temp / 'probe.c'; source.write_text('int main(void) { return 0; }\n')
        binary = temp / 'probe'
        run('/usr/bin/clang', str(source), '-o', str(binary))
        run('/usr/bin/codesign', '--force', '--sign', identity, '--keychain', str(keychain),
            '--timestamp=none', str(binary))
        run('/usr/bin/codesign', '--verify', '--strict', str(binary))
        identity_file.write_text(identity + '\n')
    print(f'Local development identity ready: {identity}')
    print('Future builds reuse this certificate. Accessibility still requires your approval in System Settings.')


if __name__ == '__main__':
    main()
