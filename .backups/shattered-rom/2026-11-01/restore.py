from pathlib import Path
import hashlib
import json
import zipfile

root = Path(__file__).resolve().parent
manifest = json.loads((root / 'backup-manifest.json').read_text())
destination = root / 'restored'
destination.mkdir(exist_ok=True)
for archive in manifest['archives']:
    output = destination / archive['name']
    with output.open('wb') as writer:
        for part in archive['parts']:
            data = (root / part['name']).read_bytes()
            assert len(data) == part['size_bytes'], part['name']
            assert hashlib.sha256(data).hexdigest() == part['sha256'], part['name']
            writer.write(data)
    assert output.stat().st_size == archive['size_bytes'], output.name
    assert hashlib.sha256(output.read_bytes()).hexdigest() == archive['sha256'], output.name
    with zipfile.ZipFile(output) as zipped:
        assert zipped.testzip() is None, output.name
        for member in archive['members']:
            data = zipped.read(member['name'])
            assert len(data) == member['size_bytes'], member['name']
            assert hashlib.sha256(data).hexdigest() == member['sha256'], member['name']
    print('Verified:', output)
