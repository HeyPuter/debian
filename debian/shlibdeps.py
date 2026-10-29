#!/usr/bin/env python3
"""Our .debs' library Depends, as dpkg-shlibdeps would have given them.

    shlibdeps.py OUT POOL...

dpkg-shlibdeps reads ELF, and our programs and libraries are wasm modules,
so in a cross build their ${shlibs:Depends} comes out empty: a package apt
installs arrives without the libraries it loads (libcurl4t64 without
libnghttp3-9, fdisk without libfdisk1). Here each module's needed libraries
(its dylink.0 section; a program's module is inside gexcc's ELF executable)
are looked up in the pool as dpkg-shlibdeps looks them up: the package whose
symbols file names the soname (>= that package's upstream version), else
the one whose shlibs file does, with that file's version (`libcurl 4
libcurl4t64 (>= 8.14.1)`), else the package that ships a file of that
name, unversioned. What Depends does not already name is added to it.

POOL: directories of .debs, a later pool's copy of a package taking the
place of an earlier one's (as kde/build-wasm32.sh). OUT gets every one of
them: a link to the original where nothing changed, a .deb whose control
archive is rewritten (the data archive as it was) where Depends gained
something, another architecture's .debs as links. OUT/shlibdeps.txt lists
what was added.
"""
import glob, io, os, re, shutil, subprocess, sys, tarfile, tempfile

ARCH = 'musl-linux-wasm32'
# the toolchain's (gexcc's libc.so, which no package ships: kde/build-wasm32.sh
# puts it in the tree)
TOOLCHAIN_SONAMES = {'libc.so'}


def leb(b, i):
    r = s = 0
    while True:
        x = b[i]
        i += 1
        r |= (x & 0x7f) << s
        s += 7
        if x < 0x80:
            return r, i


def needed(b):
    """A wasm module's needed libraries (dylink.0's WASM_DYLINK_NEEDED), or
    None when B is no wasm module."""
    if b[:4] != b'\0asm':
        return None
    i, out = 8, []
    while i < len(b):
        sid = b[i]
        size, i = leb(b, i + 1)
        end = i + size
        if sid == 0:
            nl, j = leb(b, i)
            if b[j:j + nl] == b'dylink.0':
                j += nl
                while j < end:
                    t = b[j]
                    sl, j = leb(b, j + 1)
                    if t == 2:
                        n, k = leb(b, j)
                        for _ in range(n):
                            ln, k = leb(b, k)
                            out.append(b[k:k + ln].decode())
                            k += ln
                    j += sl
                return out
        # dylink.0 is the first section: past it there is none
        return out
    return out


def elf_needed(b):
    """An ELF file's DT_NEEDED names (our programs are wasm modules in an
    ELF container, 32- or 64-bit, little-endian), or None when B is no ELF."""
    if b[:4] != b'\x7fELF' or b[5] != 1:
        return None
    import struct
    is64 = b[4] == 2
    if is64:
        phoff, phentsize, phnum = struct.unpack_from('<Q', b, 32)[0], *struct.unpack_from('<HH', b, 54)
    else:
        phoff, phentsize, phnum = struct.unpack_from('<I', b, 28)[0], *struct.unpack_from('<HH', b, 42)
    loads, dyn = [], None
    for i in range(phnum):
        o = phoff + i * phentsize
        if is64:
            typ, _, off, vaddr, _, filesz = struct.unpack_from('<IIQQQQ', b, o)
        else:
            typ, off, vaddr, _, filesz = struct.unpack_from('<IIIII', b, o)
        if typ == 1:
            loads.append((vaddr, off, filesz))
        elif typ == 2:
            dyn = (off, filesz)
    if not dyn:
        return []
    ents, strtab = [], None
    size = 16 if is64 else 8
    for o in range(dyn[0], dyn[0] + dyn[1], size):
        tag, val = struct.unpack_from('<qQ' if is64 else '<iI', b, o)
        if tag == 0:
            break
        if tag == 1:
            ents.append(val)
        elif tag == 5:
            strtab = val
    if strtab is None:
        return []
    base = next((off + strtab - va for va, off, sz in loads if va <= strtab < va + sz), strtab)
    out = []
    for v in ents:
        s = base + v
        out.append(b[s:b.index(b'\0', s)].decode())
    return out


def ar_members(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'!<arch>\n', path
    i, out = 8, []
    while i < len(data):
        h = data[i:i + 60]
        name = h[:16].decode().strip().rstrip('/')
        size = int(h[48:58].decode().strip())
        out.append((name, data[i + 60:i + 60 + size]))
        i += 60 + size + (size & 1)
    return out


def ar_write(path, members):
    with open(path, 'wb') as f:
        f.write(b'!<arch>\n')
        for name, body in members:
            f.write(f'{name:<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(body):<10}`\n'.encode())
            f.write(body)
            if len(body) & 1:
                f.write(b'\n')


def tar_open(name, body):
    if name.endswith('.xz'):
        return tarfile.open(fileobj=io.BytesIO(body), mode='r:xz')
    if name.endswith('.gz'):
        return tarfile.open(fileobj=io.BytesIO(body), mode='r:gz')
    if name.endswith('.zst'):
        raw = subprocess.run(['zstd', '-dc'], input=body, capture_output=True, check=True).stdout
        return tarfile.open(fileobj=io.BytesIO(raw), mode='r:')
    return tarfile.open(fileobj=io.BytesIO(body), mode='r:')


def fields(text):
    out, key = {}, None
    for line in text.splitlines():
        if line[:1] in (' ', '\t') and key:
            out[key] += '\n' + line
        elif ':' in line:
            key, v = line.split(':', 1)
            out[key] = v.strip()
    return out


def clause_names(dep):
    return {alt.strip().split(' ')[0].split(':')[0] for c in dep.split(',') for alt in c.split('|') if alt.strip()}


def soname_of(lib, major):
    # shlibs' `libfoo 1` is libfoo.so.1; `libfoo-1.0 0` is libfoo-1.0.so.0
    return f'{lib}.so.{major}' if major else f'{lib}.so'


def main():
    out, pools = sys.argv[1], sys.argv[2:]
    if not pools:
        sys.exit(__doc__)
    debs, others = {}, {}
    for p in pools:
        for d in sorted(glob.glob(os.path.join(p, '*.deb'))):
            n = os.path.basename(d).split('_')[0]
            debs.pop(n, None)
            others.pop(n, None)
            (debs if d.endswith(f'_{ARCH}.deb') else others)[n] = os.path.realpath(d)
    # (another architecture's, as they are)
    os.makedirs(out, exist_ok=True)
    for d in others.values():
        if not os.path.lexists(os.path.join(out, os.path.basename(d))):
            os.symlink(d, os.path.join(out, os.path.basename(d)))
    info = {}
    by_shlibs, by_symbols, by_file = {}, {}, {}
    for pkg, d in sorted(debs.items()):
        members = ar_members(d)
        ctl_name, ctl = next((n, b) for n, b in members if n.startswith('control.tar'))
        data_name, data = next((n, b) for n, b in members if n.startswith('data.tar'))
        control = shlibs = symbols = ''
        with tar_open(ctl_name, ctl) as t:
            for m in t:
                base = os.path.basename(m.name)
                if base in ('control', 'shlibs', 'symbols') and m.isfile():
                    text = t.extractfile(m).read().decode('utf-8', 'replace')
                    if base == 'control':
                        control = text
                    elif base == 'shlibs':
                        shlibs = text
                    else:
                        symbols = text
        need, names = set(), set()
        with tar_open(data_name, data) as t:
            for m in t:
                base = os.path.basename(m.name)
                if '.so' in base:
                    names.add(base)
                if m.isfile() and m.size > 8:
                    f = t.extractfile(m)
                    head = f.read(4)
                    if head in (b'\0asm', b'\x7fELF'):
                        body = head + f.read()
                        n = needed(body) if head == b'\0asm' else elf_needed(body)
                        if head == b'\x7fELF' and not n:
                            # gexcc's programs: the wasm module inside an
                            # ELF executable with no dynamic section
                            at = body.find(b'\0asm\x01\0\0\0')
                            n = needed(body[at:]) if at > 0 else None
                        if n:
                            need.update(n)
        info[pkg] = (d, members, ctl_name, control, need, names)
        for n in names:
            # a library's own package before a -dev package's link to it
            if n not in by_file or (by_file[n].endswith('-dev') and not pkg.endswith('-dev')):
                by_file[n] = pkg
        for line in shlibs.splitlines():
            w = line.split(None, 2)
            if len(w) == 3 and not line.startswith(('udeb:', '#')):
                by_shlibs.setdefault(soname_of(w[0], w[1]), w[2].strip())
        # a symbols file's header lines: `libcurl.so.4 libcurl4t64 #MINVER#`
        # (>= the version without its Debian revision, epoch kept)
        version = fields(control).get('Version', '')
        minver = re.sub(r'-[^-]*$', '', version)
        for line in symbols.splitlines():
            w = line.split()
            if len(w) >= 2 and not line[0].isspace() and not line.startswith(('*', '|', '#')):
                by_symbols.setdefault(w[0], f'{w[1]} (>= {minver})' if minver else w[1])
    known = set(info)
    for pkg, (d, members, ctl_name, control, need, names) in info.items():
        known |= clause_names(fields(control).get('Provides', ''))
    os.makedirs(out, exist_ok=True)
    report, gained = [], 0
    for pkg, (d, members, ctl_name, control, need, names) in sorted(info.items()):
        f = fields(control)
        have = clause_names(f.get('Depends', '')) | clause_names(f.get('Pre-Depends', '')) | {pkg}
        add = []
        for so in sorted(need - names - TOOLCHAIN_SONAMES):
            # symbols before shlibs, as dpkg-shlibdeps; a name neither file's
            # package has (a shlibs file older than its package's rename,
            # libphonon4qt6-4 in libphonon4qt6-4t64's) is the file's owner
            dep = next((x for x in (by_symbols.get(so), by_shlibs.get(so)) if x and x.split(' ')[0] in known), None) \
                or by_file.get(so)
            if not dep:
                continue
            name = dep.split(' ')[0]
            if name not in have and name != pkg:
                have.add(name)
                add.append(dep)
        dst = os.path.join(out, os.path.basename(d))
        if os.path.lexists(dst):
            os.remove(dst)
        if not add:
            os.symlink(d, dst)
            continue
        gained += 1
        report.append(f'{pkg}: {", ".join(add)}')
        dep = ', '.join(filter(None, [f.get('Depends', '')] + add))
        if 'Depends' in f:
            control = re.sub(r'^Depends:.*(\n[ \t].*)*', 'Depends: ' + dep.replace('\\', r'\\'), control, count=1, flags=re.M)
        else:
            # after Pre-Depends or before Description, where dpkg-gencontrol puts it
            control = re.sub(r'^(Description:)', f'Depends: {dep}\n' + r'\1', control, count=1, flags=re.M)
        with tempfile.TemporaryDirectory() as t:
            z = {'.xz': ['-J'], '.gz': ['-z'], '.zst': ['--zstd']}.get(os.path.splitext(ctl_name)[1], [])
            subprocess.run(['tar', '-C', t, '-xf', '-'] + z,
                           input=dict(members)[ctl_name], check=True)
            open(os.path.join(t, 'control'), 'w').write(control)
            body = subprocess.run(['tar', '-C', t, '--owner=0', '--group=0', '--numeric-owner', '--sort=name',
                                   '-cJf', '-', '.'], capture_output=True, check=True).stdout
        ar_write(dst, [('control.tar.xz', body) if n == ctl_name else (n, b) for n, b in members])
    open(os.path.join(out, 'shlibdeps.txt'), 'w').write('\n'.join(report) + '\n')
    print(f'{gained} of {len(info)} packages gained Depends ({out}/shlibdeps.txt)', file=sys.stderr)


if __name__ == '__main__':
    main()
