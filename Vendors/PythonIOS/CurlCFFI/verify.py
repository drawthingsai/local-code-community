"""Check platform metadata, native symbol isolation, and the per-slice size budget."""
import plistlib
import subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[1]
framework = root / 'Frameworks/CurlCFFI.xcframework'
metadata = plistlib.loads((framework / 'Info.plist').read_bytes())
expected = {'ios-arm64': ('ios', None, '2'), 'ios-arm64-simulator': ('ios', 'simulator', '7'), 'macos-arm64': ('macos', None, '1')}
private_prefixes = (
    '_SSL_', '_OPENSSL_', '_EVP_', '_CRYPTO_', '_BIO_', '_BN_', '_ERR_',
    '_X509_', '_ASN1_', '_AES_', '_RSA_', '_EC_', '_ECDSA_', '_ECDH_',
    '_HMAC_', '_SHA', '_CBS_', '_CBB_', '_d2i_', '_i2d_',
    '_curl_', '_nghttp', '_ngtcp', '_Brotli', '_ZSTD_',
)
assert {s['LibraryIdentifier'] for s in metadata['AvailableLibraries']} == expected.keys()
for item in metadata['AvailableLibraries']:
    identifier = item['LibraryIdentifier']
    platform, variant, load_platform = expected[identifier]
    assert item['SupportedArchitectures'] == ['arm64']
    assert item['SupportedPlatform'] == platform and item.get('SupportedPlatformVariant') == variant
    archive = framework / identifier / item['LibraryPath']
    assert archive.stat().st_size < 5 * 1024 * 1024, f'{identifier}: review native size increase'
    assert subprocess.check_output(['xcrun', 'lipo', '-archs', str(archive)], text=True).strip() == 'arm64'
    symbols = subprocess.check_output(['xcrun', 'nm', '-m', str(archive)], text=True)
    defined = [line.split()[-1] for line in symbols.splitlines() if ' external ' in line and '(undefined)' not in line]
    assert defined == ['_PyInit__wrapper'], (identifier, defined)
    for line in symbols.splitlines():
        if '(undefined)' in line:
            assert not line.split()[-1].startswith(private_prefixes), line
    commands = subprocess.check_output(['xcrun', 'otool', '-l', str(archive)], text=True)
    assert f'platform {load_platform}' in commands, identifier
    print(f'{identifier}: {archive.stat().st_size:,} bytes; native dependencies private')
