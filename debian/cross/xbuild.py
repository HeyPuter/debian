#!/usr/bin/env python3
"""Cross-build Debian source packages for musl-linux-wasm32 with Debian's own
debian/rules (dpkg-buildpackage), in the build chroot.

    xbuild.py --chroot DIR --prefix GEXCC_PREFIX --env ENVDIR --work DIR SRCPKG...

For each source package, in order:
  1. fetch and unpack it (debsrc.py: Debian's patches; ours only if
     debian/patches/SRCPKG exists, which for this build it should not);
  2. its Build-Depends, split as Debian's cross builds split them: a
     dependency that is `:native`, Architecture: all or Multi-Arch: foreign
     runs on the build machine and must be in the chroot; Architecture: all
     ones also go into the gexcc sysroot (headers, pkg-config and CMake files
     the target build reads); everything else is a library for the target,
     which must be one of the wasm32 packages built before (WORK/debs) and is
     unpacked into the sysroot;
  3. dpkg-buildpackage -a musl-linux-wasm32 -B, in the chroot
     (in-chroot.sh), with the build profiles cross, nocheck and nodoc;
  4. its .debs go to WORK/debs, its log to WORK/logs/SRCPKG.log.

A dependency that cannot be met stops that package with the list of what is
missing (`needs`), so the caller can build those first.
"""
import argparse, glob, os, re, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
import debfetch  # noqa: E402

PROFILES = {'cross', 'nocheck', 'nodoc', 'noudeb', 'noinsttest'}
ARCH = 'musl-linux-wasm32'
# What gexcc itself is for the target: its C library, C++ runtime and kernel
# headers are the sysroot's, its pkg-config the wrapper over the sysroot (a
# cross build's PKG:wasm32 of these)
TOOLCHAIN = {'libc6-dev', 'libc-dev', 'linux-libc-dev', 'pkg-config', 'pkgconf', 'libstdc++-dev',
             'libstdc++-14-dev', 'libgcc-14-dev', 'libgcc-s1', 'libatomic1', 'libc++-dev', 'libc++abi-dev'}


def deps_of(control):
    """Build-Depends and Build-Depends-Arch of a debian/control, first
    alternatives that apply to this build: [(name, qualifier)]."""
    src = next(debfetch.stanzas(control))
    text = ', '.join(src.get(k, '') for k in ('Build-Depends', 'Build-Depends-Arch'))
    out = []
    for clause in text.split(','):
        for alt in clause.split('|'):
            alt = alt.strip()
            if not alt:
                continue
            # [arch] restrictions: none of ours name wasm32, so a positive
            # list excludes it and a negated one keeps it
            archs = re.findall(r'\[([^]]*)\]', alt)
            if archs and not all(a.strip().startswith('!') for a in archs[0].split()):
                continue
            # <profile> restrictions: a group applies when all its terms do
            groups = re.findall(r'<([^>]*)>', alt)
            if groups and not any(all((t[1:] not in PROFILES) if t.startswith('!') else (t in PROFILES)
                                      for t in g.split()) for g in groups):
                continue
            m = re.match(r'([a-z0-9][a-z0-9+.-]*)(?::(native|any))?', alt)
            if m:
                out.append((m.group(1), m.group(2)))
            break
    return out


def installed(chroot):
    names = set()
    with open(os.path.join(chroot, 'var/lib/dpkg/status')) as f:
        for s in debfetch.stanzas(f.read()):
            names.add(s['Package'])
            for p in s.get('Provides', '').split(','):
                p = p.strip().split(' ')[0]
                if p:
                    names.add(p)
    return names


def built_debs(work):
    """Our wasm32 packages: {name: path}, newest last wins; and what they provide."""
    out = {}
    for p in sorted(glob.glob(os.path.join(work, 'debs', '*.deb'))):
        ctl = subprocess.run(['dpkg-deb', '-f', p], capture_output=True, text=True).stdout
        s = next(debfetch.stanzas(ctl))
        out[s['Package']] = p
        for q in s.get('Provides', '').split(','):
            q = q.strip().split(' ')[0]
            if q:
                out.setdefault(q, p)
    return out


def into_sysroot(deb, sysroot, done):
    """Unpack a package's target-side files into the sysroot (once)."""
    if deb in done:
        return
    done.add(deb)
    with tempfile.TemporaryDirectory() as t:
        subprocess.run(['dpkg-deb', '-x', deb, t], check=True)
        for sub in ('usr/include', 'usr/lib', 'usr/share/pkgconfig', 'usr/share/cmake', 'usr/share/aclocal',
                    'usr/share/ECM', 'usr/lib/cmake'):
            s = os.path.join(t, sub)
            if os.path.isdir(s):
                os.makedirs(os.path.join(sysroot, sub), exist_ok=True)
                subprocess.run(['cp', '-a', '--remove-destination', s + '/.', os.path.join(sysroot, sub)],
                               check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--chroot', required=True)
    ap.add_argument('--prefix', required=True)
    ap.add_argument('--env', required=True)
    ap.add_argument('--work', required=True)
    ap.add_argument('--cache', default=os.environ.get('DEB_CACHE'))
    ap.add_argument('--jobs', default=os.environ.get('JOBS', '8'))
    ap.add_argument('--keep', action='store_true', help='reuse an unpacked source tree')
    ap.add_argument('pkgs', nargs='+')
    a = ap.parse_args()
    work = os.path.abspath(a.work)
    cache = a.cache or os.path.join(work, 'deb')
    for d in ('src', 'debs', 'logs'):
        os.makedirs(os.path.join(work, d), exist_ok=True)
    sysroot = os.path.join(a.prefix, 'sysroot')
    debian, _ = debfetch.packages(cache, 'trixie', 'amd64')
    chroot_has = installed(a.chroot)
    unpacked = set()
    failed = 0
    for name in a.pkgs:
        r = subprocess.run([sys.executable, '-I', os.path.join(HERE, '..', 'debsrc.py'), '--cache', cache,
                            '--into', os.path.join(work, 'src'), name], capture_output=True, text=True)
        if r.returncode:
            print(f'FAIL {name}: fetch: {r.stderr.strip()[-300:]}')
            failed += 1
            continue
        _, ver, srcdir = r.stdout.split()[:3]
        ours = built_debs(work)
        needs, native_missing = [], []
        for dep, q in deps_of(open(os.path.join(srcdir, 'debian/control')).read()):
            if dep in TOOLCHAIN:
                continue
            p = debian.get(dep)
            build_side = q == 'native' or (p is not None and (p.get('Architecture') == 'all'
                                                                or p.get('Multi-Arch') == 'foreign'))
            if build_side or (p is None and dep in chroot_has and dep not in ours):
                if dep not in chroot_has:
                    native_missing.append(dep)
                if p is not None and p.get('Architecture') == 'all' and q != 'native':
                    into_sysroot(debfetch.fetch(cache, p), sysroot, unpacked)
                continue
            if dep in ours:
                into_sysroot(ours[dep], sysroot, unpacked)
            else:
                needs.append(dep)
        if needs or native_missing:
            print(f'FAIL {name}: needs {" ".join(needs) or "-"}; chroot lacks {" ".join(native_missing) or "-"}')
            failed += 1
            continue
        log = os.path.join(work, 'logs', f'{name}.log')
        env = (f'GEXCC_SHARED={os.environ.get("GEXCC_SHARED", "1")} DEB_BUILD_PROFILES="cross nocheck nodoc noudeb" '
               f'DEB_BUILD_OPTIONS="nocheck nodoc noautodbgsym parallel={a.jobs}" '
               'DPKG_GENSYMBOLS_CHECK_LEVEL=0')
        cmd = f'cd {srcdir} && {env} dpkg-buildpackage -a {ARCH} -d -B -uc -us'
        with open(log, 'w') as f:
            r = subprocess.run([os.path.join(HERE, 'in-chroot.sh'), a.chroot, a.prefix, a.env, '--bind', work,
                                '--', 'bash', '-c', cmd], stdout=f, stderr=subprocess.STDOUT)
        if r.returncode:
            tail = open(log, errors='replace').read().strip().split('\n')[-3:]
            print(f'FAIL {name}: build (log {log}): ' + ' | '.join(tail))
            failed += 1
            continue
        parent = os.path.dirname(srcdir)
        made = []
        for f in glob.glob(os.path.join(parent, f'*_{ver.split(":")[-1]}_*.deb')):
            shutil.move(f, os.path.join(work, 'debs', os.path.basename(f)))
            made.append(os.path.basename(f))
        for f in glob.glob(os.path.join(parent, f'{name}_*.buildinfo')) + glob.glob(os.path.join(parent, f'{name}_*.changes')):
            os.unlink(f)
        print(f'ok {name} {ver}: {" ".join(sorted(made))}')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
