"""Compare native ZIP inspection with the unmodified pinned dsh inspector.

The reference dependencies are test-only. Install them in an ignored directory:
  npm install --prefix Vendors/LibreOffice/.build/zip-parity --ignore-scripts --no-audit --no-fund fflate@0.8.2 saxes@6.0.0 fontkit@2.0.4
Build //Vendors/LibreOffice:DocumentFontTests for --inspector. Requires Node >=22.19.
"""
import argparse
import hashlib
import html
import io
import json
from pathlib import Path
import re
import struct
import subprocess
import zipfile

PIN = 'b19bb73c74ed893b8a5d1716d32df32a113ed31b'


def zip_bytes(entries, *, level=6, streamed=False, wide=False):
    class Stream(io.BytesIO):
        def seekable(self): return False
        def seek(self, *args): raise io.UnsupportedOperation('stream')
    stream = Stream() if streamed else io.BytesIO()
    with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED if level else zipfile.ZIP_STORED, compresslevel=level or None) as archive:
        for name, value in entries:
            if isinstance(value, str): value = value.encode()
            with archive.open(name, 'w', force_zip64=wide) as file: file.write(value)
    return stream.getvalue()


def docx_entries(family='Helvetica', text='Font ABC 中文测试'):
    font, text = html.escape(family, quote=True), html.escape(text)
    return [('[Content_Types].xml', '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'),
        ('_rels/.rels', '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'),
        ('word/document.xml', f'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:rPr><w:rFonts w:ascii="{font}" w:hAnsi="{font}"/></w:rPr><w:t>{text}</w:t></w:r></w:p></w:body></w:document>')]


def layout(data):
    end = data.rfind(b'PK\x05\x06')
    position = struct.unpack_from('<I', data, end+16)[0]
    entries = {}
    for _ in range(struct.unpack_from('<H', data, end+8)[0]):
        name, extra, comment = struct.unpack_from('<HHH', data, position+28)
        key = data[position+46:position+46+name].decode()
        local = struct.unpack_from('<I', data, position+42)[0]
        n, e = struct.unpack_from('<HH', data, local+26)
        entries[key] = (position, local, local+30+n+e)
        position += 46+name+extra+comment
    return end, entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kit', type=Path, required=True)
    parser.add_argument('--dependencies', type=Path, required=True)
    parser.add_argument('--inspector', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    kit, dependencies, inspector, root = [p.resolve() for p in [args.kit, args.dependencies, args.inspector, args.output]]
    assert subprocess.check_output(['git', '-C', str(kit), 'rev-parse', 'HEAD'], text=True).strip() == PIN
    for name, version in [('fflate', '0.8.2'), ('saxes', '6.0.0'), ('fontkit', '2.0.4')]:
        assert json.loads((dependencies/'node_modules'/name/'package.json').read_text())['version'] == version
    root.mkdir(parents=True, exist_ok=False)
    oracle = dependencies/'oracle'; oracle.mkdir(exist_ok=True)
    # Copy verbatim, checking against the pinned Git blobs. Only a runner is ours.
    sources = {}
    for name in ['document.ts', 'ooxml.ts', 'errors.ts', 'fonts.ts', 'font-file-identity.ts']:
        relative = 'packages/entry/src/'+name
        data = subprocess.check_output(['git', '-C', str(kit), 'show', PIN+':'+relative])
        (oracle/name).write_bytes(data); sources[relative] = hashlib.sha256(data).hexdigest()
    (oracle/'package.json').write_text('{"type":"module"}\n')
    (oracle/'run.mjs').write_text('''import { readFileSync } from 'node:fs';
import { inspectDocument } from './document.ts';
const cases = JSON.parse(readFileSync(process.argv[2], 'utf8'));
for (const test of cases) {
  let result;
  try {
    const metadata = inspectDocument(new Uint8Array(readFileSync(test.path)), test.kind,
      { maxArchiveEntries: test.entries, maxUncompressedBytes: test.bytes });
    result = { ok: true, families: [...metadata.families.values()], points: [...metadata.codePoints].sort((a,b)=>a-b) };
  } catch (error) { result = { ok: false, code: error.code, error: error.message }; }
  console.log(JSON.stringify(result));
}
''')
    cases = []
    def add(name, data, kind='docx', *, valid=True, entries=20000, budget=2**20, difference=False):
        path = root/(name+'.'+kind); path.write_bytes(data)
        cases.append(dict(name=name, path=str(path), kind=kind, entries=entries, bytes=budget, valid=valid, difference=difference))

    # Same family/script/format matrix as dsh's ooxml-fuzz.spec.ts. Actual PPTX
    # and XLSX fixtures come from its pinned repository; no engine is invoked.
    families = ['SimSun', 'Microsoft YaHei', 'Songti SC', 'Arial', 'Times New Roman', 'Fixture & Serif']
    scripts = ['中文预览', 'Καλημέρα', 'Привет', 'مرحبا', 'שלום', 'हिन्दी', '한국어', '日本語']
    generated = {}
    for kind in ['docx', 'pptx', 'xlsx']:
        for seed in range(24):
            family = families[seed % len(families)]
            text = f'{scripts[seed % len(scripts)]} seed-{seed} <&> '+('Ab中9'*(8+seed%17))
            if kind == 'docx': entries = docx_entries(family, text)
            else:
                with zipfile.ZipFile(kit/'test/fixtures'/('one-slide.pptx' if kind == 'pptx' else 'one-sheet.xlsx')) as archive:
                    files = {name: archive.read(name) for name in archive.namelist()}
                if kind == 'pptx':
                    name = 'ppt/slides/slide1.xml'
                    xml = re.sub(r'typeface="[^"]*"', 'typeface="'+html.escape(family, quote=True)+'"', files[name].decode())
                    files[name] = re.sub(r'<a:t>.*?</a:t>', '<a:t>'+html.escape(text)+'</a:t>', xml)
                else:
                    name = 'xl/worksheets/sheet1.xml'
                    files[name] = re.sub(r'<t>.*?</t>', '<t>'+html.escape(text)+'</t>', files[name].decode())
                    files['xl/styles.xml'] = '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><name val="'+html.escape(family, quote=True)+'"/></font></fonts></styleSheet>'
                entries = files.items()
            data = zip_bytes(entries, level=seed%3)
            add(f'generated-{kind}-{seed}', data, kind)
            if seed == 7: generated[kind] = data
        add('entry-limit-'+kind, data, kind, valid=False, entries=1)
        add('declared-limit-'+kind, data, kind, valid=False, budget=1)

    entries = docx_entries()+[('word/media/unused.bin', 'unreferenced payload')]
    source = zip_bytes(entries); end, offsets = layout(source)
    central, local, body = offsets['word/document.xml']
    uc, ul, ub = offsets['word/media/unused.bin']
    def change(name, edits, valid=True):
        data = bytearray(source)
        for offset, fmt, value in edits: struct.pack_into(fmt, data, offset, value)
        add(name, data, valid=valid)
    add('trailing-bytes', source+b'harmless trailing data')
    add('directory-padding', source[:end]+b'padding after directory'+source[end:])
    change('wrong-crcs', [(central+16,'<I',1),(local+14,'<I',2),(uc+16,'<I',3)])
    change('local-flags', [(local+6,'<H',0x2049)])
    change('local-method', [(local+8,'<H',99)])
    change('local-sizes', [(local+18,'<I',1),(local+22,'<I',2)])
    change('local-name', [(local+30,'<B',ord('X'))])
    change('unused-header-signatures', [(local,'<I',0),(central,'<I',0)])
    change('directory-size', [(end+12,'<I',0)])
    change('comment-length', [(end+20,'<H',65535)])
    change('unused-disk-fields', [(end+4,'<I',0x00010001),(central+34,'<H',1)])
    change('unused-compression', [(uc+10,'<H',99)])
    change('unused-bad-deflate', [(ub,'<B',7)])
    change('unused-invalid-offset', [(uc+42,'<I',0xffffffff)])
    change('unsupported-metadata-compression', [(central+10,'<H',99)], False)
    change('metadata-out-of-bounds', [(central+42,'<I',len(source)-8)])
    change('declared-size-too-large', [(uc+24,'<I',2**21)], False)
    change('deflate-declared-too-small', [(central+24,'<I',1)])
    change('deflate-declared-too-large', [(central+24,'<I',60000)])
    change('bad-metadata-deflate', [(body,'<B',7)], False)
    add('duplicate-entry', zip_bytes(docx_entries()+[('word/document.xml','<duplicate/>')]), valid=False)
    add('wrong-type', zip_bytes([(n, v.replace('wordprocessingml.document.main+xml','other.type') if n=='[Content_Types].xml' else v) for n,v in docx_entries()]), valid=False)
    add('missing-main', zip_bytes(docx_entries()[:2]), valid=False)
    add('truncated-directory', source[:-13], valid=False)
    for wide in [False, True]:
        stream = bytearray(zip_bytes(entries, streamed=True, wide=wide))
        _, layout_ = layout(stream); c,l,b = layout_['word/document.xml']
        descriptor = b+struct.unpack_from('<I',stream,c+20)[0]
        stream[descriptor:descriptor+16] = b'bad descriptor!!'
        add('ignored-descriptor-'+str(wide),stream)
    # Full ZIP64 directory/end records, including all three 64-bit entry fields.
    directory = bytearray()
    for c,l,b in offsets.values():
        name, extra, comment = struct.unpack_from('<HHH',source,c+28)
        record = bytearray(source[c:c+46+name+extra+comment])
        compressed, expanded = struct.unpack_from('<II',record,20)
        struct.pack_into('<II',record,20,0xffffffff,0xffffffff)
        struct.pack_into('<I',record,42,0xffffffff)
        field = struct.pack('<HHQQQ',1,24,expanded,compressed,l)
        struct.pack_into('<H',record,30,extra+len(field))
        record[46+name:46+name] = field
        directory += record
    start = struct.unpack_from('<I',source,end+16)[0]
    zip64 = source[:start]+directory
    locator = len(zip64)
    zip64 += struct.pack('<IQHHIIQQQQ',0x06064b50,44,45,45,0,0,len(offsets),len(offsets),len(directory),start)
    zip64 += struct.pack('<IIQI',0x07064b50,0,locator,1)
    zip64 += struct.pack('<IHHHHIIH',0x06054b50,0,0,65535,65535,0xffffffff,0xffffffff,0)
    add('zip64-directory',zip64)
    # Names use Latin-1 without bit 11 and TextDecoder replacement with it.
    # Distinct byte names that decode equally are still duplicates upstream.
    for name, raw, flags in [('latin1',b'\xe9',0),('invalid-utf8',b'\xff\xfe',2048)]:
        first = 'é' if not flags else '��'
        second = 'X'*len(raw)
        data = bytearray(zip_bytes(docx_entries()+[(first,'unused'),(second,'unused')]))
        _, layout_ = layout(data); c,l,b = layout_[second]
        data[c+46:c+46+len(raw)] = raw; struct.pack_into('<H',data,c+8,flags)
        add('duplicate-decoded-name-'+name,data,valid=False)
    bom = zip_bytes([(('﻿'+n if n=='word/document.xml' else n),v) for n,v in docx_entries()])
    add('utf8-bom-name',bom)
    # Two directory entries may refer to the same local bytes; both still count.
    overlap = zip_bytes(docx_entries()+[('word/alias.xml','<ignored/>')])
    _, layout_ = layout(overlap); c,l,b = layout_['word/document.xml']; ac,_,_ = layout_['word/alias.xml']
    overlap = bytearray(overlap)
    overlap[ac+10:ac+28] = overlap[c+10:c+28]; struct.pack_into('<I',overlap,ac+42,l)
    add('overlapping-entry-data',overlap)
    # ODF selects its manifest, content and styles, with exact MIME matching.
    odf = [('mimetype','application/vnd.oasis.opendocument.text'),('META-INF/manifest.xml','<manifest/>'),('content.xml', '<r xmlns:f="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" f:font-family="Songti SC">中文</r>')]
    add('odf',zip_bytes(odf),'odt')
    add('odf-mime-suffix',zip_bytes([(n,v+'x' if n=='mimetype' else v) for n,v in odf]),'odt',valid=False)
    for name in ['word/theme/theme1.xml','word/fontTable.xml','word/media/image.png']:
        skipped = bytearray(zip_bytes(docx_entries()+[(name,'not decoded')]))
        _, layout_ = layout(skipped); c,l,b = layout_[name]; struct.pack_into('<H',skipped,c+10,99)
        add('skip-'+Path(name).stem,skipped)
    # The intentional native difference: count ACTUAL selected-part expansion
    # even when a smaller directory size makes fflate clip its metadata buffer.
    for aggregate in [False, True]:
        parts = docx_entries()+[('word/large.xml','<r>'+('X'*(2500 if aggregate else 100000))) ]
        if aggregate: parts += [('word/large2.xml','<r>'+('Y'*2500))]
        data = bytearray(zip_bytes(parts)); _, layout_ = layout(data)
        for name,(c,l,b) in layout_.items():
            if name.startswith('word/large'): struct.pack_into('<I',data,c+24,1)
        add('actual-limit-'+str(aggregate),data,budget=4096,difference=True)
        add('within-actual-limit-'+str(aggregate),data)

    # Seeded mutations use the same PRNG and truncation schedule as upstream.
    # Native out-of-bounds rejection is allowed where JS slicing is permissive.
    for kind, data in generated.items():
        state = 0x4832+len(kind)
        def random():
            nonlocal state
            state=(state*1664525+1013904223)&0xffffffff; return state/2**32
        for seed in range(64):
            size = max(1,int(len(data)*random())) if seed%4==0 else len(data)
            altered = bytearray(data[:size])
            for _ in range(1+seed%4):
                offset=min(len(altered)-1,int(random()*len(altered)))
                altered[offset] ^= 1+int(random()*255)
            add(f'mutation-{kind}-{seed}',altered,kind,valid=None)
    manifest=root/'cases.json'; manifest.write_text(json.dumps(cases))
    output=subprocess.check_output(['node',str(oracle/'run.mjs'),str(manifest)],text=True,timeout=60)
    reference=[json.loads(line) for line in output.splitlines()]; assert len(reference)==len(cases)
    records=[]; bounds_differences=[]; mismatches=[]
    for case,upstream in zip(cases,reference):
        native=json.loads(subprocess.check_output([str(inspector),'--inspect',case['path'],case['kind'],str(case['entries']),str(case['bytes'])],text=True,timeout=5))
        if case['difference']:
            assert upstream['ok'] and not native['ok'] and 'actual' in native['error'],(case,upstream,native)
        else:
            bounds = (upstream['ok'] and not native['ok'] and native['code']=='invalid-document'
                and native['error'] in ['Truncated Office container', 'Truncated ZIP local header', 'Truncated ZIP metadata', 'Missing ZIP64 sizes', 'Truncated ZIP64 sizes', 'Invalid ZIP extra field'])
            if bounds:
                bounds_differences.append(case['name'])
            elif native['ok']!=upstream['ok']:
                mismatches.append((case,upstream,native))
            if native['ok'] and upstream['ok']:
                if case['valid'] is not None:
                    assert native['families']==upstream['families'] and native['points']==upstream['points'],(case,upstream,native)
                assert len(native['families'])<=128 and len(native['points'])<=4096
            elif not native['ok'] and not upstream['ok']: assert native['code']==upstream['code']=='invalid-document',(case,upstream,native)
        if case['valid'] is not None: assert upstream['ok']==case['valid'],(case,upstream)
        records.append(dict(name=case['name'],upstream=upstream,native=native))
    report=dict(passed=not mismatches,cases=len(cases),intentionalActualByteLimitDifferences=sum(c['difference'] for c in cases),nativeBoundsDifferences=bounds_differences,sourceSHA256=sources,records=records)
    (root/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    assert not mismatches,mismatches
    print(json.dumps({k:v for k,v in report.items() if k not in ['sourceSHA256','records']}))


if __name__=='__main__': main()
