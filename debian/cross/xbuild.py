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
import debsrc  # noqa: E402

PROFILES = {'cross', 'nocheck', 'nodoc', 'noudeb', 'noinsttest',
            # Debian's bootstrap profiles (what rebootstrap uses to break
            # build-dependency cycles): stage1 builds a source's libraries
            # without the parts that need the rest of the archive (systemd's
            # is libsystemd and libudev only), the no* ones drop language
            # bindings, and the pkg.SRC.* ones each source's optional extras.
            # (stage1 is per source, in cuts.txt: some sources' stage1 and
            # nodoc together do not build)
            'pkg.util-linux.noverity', 'nopython', 'nogir', 'nojava', 'noruby', 'nobiarch',
            'pkg.ncurses.noexamples', 'pkg.openldap.noslapd', 'pkg.unbound.libonly', 'pkg.elfutils.nodebuginfod', 'pkg.systemd.nobpf',
            'pkg.cyrus-sasl2.nogssapi', 'pkg.cyrus-sasl2.nosql', 'pkg.curl.noldap', 'pkg.glib2.0.nosysprof',
            'pkg.pango1.0.nosysprof', 'pkg.postgresql.nollvm', 'pkg.freetype.nodemos', 'pkg.sysprof.nogui',
            'pkg.ffmpeg.stage1', 'pkg.libwebp.notiff', 'pkg.openjpeg2.noapache', 'pkg.libsndfile.nompeg3',
            'pkg.libcamera.nosdl', 'pkg.libcamera.noqt', 'pkg.libcamera.nopython', 'pkg.libcamera.notrace'}
ARCH = 'musl-linux-wasm32'
# What gexcc itself is for the target: its C library, C++ runtime and kernel
# headers are the sysroot's, its pkg-config the wrapper over the sysroot (a
# cross build's PKG:wasm32 of these)
TOOLCHAIN = {'libc6-dev', 'libc-dev', 'linux-libc-dev', 'pkg-config', 'pkgconf', 'libstdc++-dev',
             'libstdc++-14-dev', 'libgcc-14-dev', 'libgcc-s1', 'libatomic1', 'libc++-dev', 'libc++abi-dev'}
# What Debian's architecture-properties provides on wasm32 (its
# architecture-is-${DEB_HOST_ARCH_ENDIAN}-endian and -${BITS}-bit): a
# Build-Depends on the target's endianness or word size (lerc's), true here.
TOOLCHAIN |= {'architecture-is-little-endian', 'architecture-is-32-bit'}


def load_cuts(path=os.path.join(HERE, 'cuts.txt')):
    """cuts.txt: {source: {'cut': set, 'drop': set, 'cmake': [(var, value)],
    'meson': [option=value], 'env': [VAR=value], 'profile': set}}."""
    out = {}
    for line in open(path):
        line = line.split('|')[0].strip()
        if not line or line.startswith('#'):
            continue
        src, kind, what = line.split(None, 2)  # a make value may have spaces
        what = what.strip()
        c = out.setdefault(src, {'cut': set(), 'drop': set(), 'cmake': [], 'meson': [], 'env': [], 'profile': set(), 'patch': set(), 'exclude': set(), 'make': [], 'autoconf': [], 'headers': set(), 'arch': set(), 'suite': set()})
        if kind == 'profile':
            c['profile'].add(what)
        elif kind in ('env', 'meson', 'make', 'autoconf'):
            c[kind].append(what)
        elif kind == 'cmake':
            c['cmake'].append(tuple(what.split('=', 1)))
        else:
            c[kind].add(what)
    return out


CUTS = load_cuts()


def add_arch(control, binaries):
    """cuts.txt's `arch BIN`: BIN's Architecture list (Debian's ports
    of it, as a port adds itself) gains this one."""
    stanzas = open(control).read().split('\n\n')
    for i, st in enumerate(stanzas):
        m = re.search(r'(?m)^Package: *(\S+)', st)
        if m and m.group(1) in binaries:
            stanzas[i] = re.sub(r'(?m)^(Architecture:(?!.*\b' + re.escape(ARCH) + r'\b).*)$', r'\1 ' + ARCH, st)
    open(control, 'w').write('\n\n'.join(stanzas))


def suite_of(src):
    """cuts.txt's `suite S`: SOURCE comes from Debian's suite S, not
    trixie (a later release that has the port)."""
    return next(iter(CUTS.get(src, {}).get('suite', ())), 'trixie')


def profiles_of(src):
    return PROFILES | CUTS.get(src, {}).get('profile', set())


def arch_matches(term):
    """Whether a Debian architecture or wildcard (linux-any, any-wasm32,
    musl-linux-any, any) names musl-linux-wasm32."""
    if term in ('any', ARCH, 'linux-any', 'any-wasm32', 'musl-linux-any', 'musl-any-any', 'any-any-wasm32'):
        return True
    return False


def deps_of(control, profiles=PROFILES):
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
            if archs:
                terms = archs[0].split()
                hit = any(arch_matches(t.lstrip('!')) for t in terms)
                if (hit if terms[0].startswith('!') else not hit):
                    continue
            # <profile> restrictions: a group applies when all its terms do
            groups = re.findall(r'<([^>]*)>', alt)
            if groups and not any(all((t[1:] not in profiles) if t.startswith('!') else (t in profiles)
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


def cmake_install_prefix(text, sysroot):
    """A CMake export's check of where it was installed, made the sysroot's.

    The export compares its own directory, resolved, with the one it was
    installed in (/usr/lib/wasm32-linux-musl/cmake/PKG) and, if they are the
    same, takes /usr as the prefix of its headers and libraries. The chroot's
    /usr/lib/wasm32-linux-musl is a link to the sysroot's, so the two match and
    the headers would be looked for in the chroot's /usr/include. An
    export of programs (Qt's and KDE's tools) keeps /usr: its programs are
    the build machine's, which the chroot has there."""
    if re.search(r'add_executable\([^)]*IMPORTED', text):
        return text
    text = re.sub(r'(?<=")/usr/lib/wasm32-linux-musl/cmake/', sysroot + '/usr/lib/wasm32-linux-musl/cmake/', text)
    # a package Config file (configure_package_config_file) says the prefix
    # outright when the check matches
    return re.sub(r'(if\(_realCurr STREQUAL _realOrig\)\s*set\(PACKAGE_PREFIX_DIR ")/usr("\))', lambda m: m.group(1) + sysroot + '/usr' + m.group(2), text)


def into_sysroot(deb, sysroot, done, chroot=None, share_only=False):
    """Unpack a package's target-side files into the sysroot (once), and its
    architecture-independent build files (aclocal macros, libtool's libltdl
    copy) into the chroot's /usr/share as well, where the build machine's
    autoreconf and libtoolize look: a Multi-Arch: same -dev package installs
    them there in an ordinary cross build. SHARE_ONLY: usr/share's data
    alone, and no package database entry (a build machine's package)."""
    if deb in done:
        return
    done.add(deb)
    with tempfile.TemporaryDirectory() as t:
        subprocess.run(['dpkg-deb', '-x', deb, t], check=True)
        # (and usr/share's data a pkg-config file or a CMake package points
        # at in the sysroot: xcb-proto's XML, wayland-protocols' XML,
        # xorg-sgml-doctools' stylesheets; everything but documentation)
        share = os.path.join(t, 'usr/share')
        subs = ([] if share_only else ['usr/include', 'usr/lib']) + [
            'usr/share/' + d for d in (sorted(os.listdir(share)) if os.path.isdir(share) else [])
            if d not in ('doc', 'man', 'info', 'locale', 'lintian', 'bug', 'doc-base', 'help', 'gtk-doc')]
        for sub in subs:
            s = os.path.join(t, sub)
            if os.path.isdir(s):
                os.makedirs(os.path.join(sysroot, sub), exist_ok=True)
                subprocess.run(['cp', '-a', '--remove-destination', s + '/.', os.path.join(sysroot, sub)],
                               check=True)
        # A link from the target's files to a build machine's path (the
        # -dev package's usr/lib/TRIPLET/libexec/kf6/kcmdesktopfilegenerator
        # -> ../../../../libexec/kf6/...: its -bin package, Multi-Arch:
        # foreign): absolute, so it reaches the chroot's, as in a Debian
        # cross build, where both are in one /usr
        for dirpath, dirs, files in os.walk(os.path.join(t, 'usr/lib')):
            for n in files + dirs:
                f = os.path.join(dirpath, n)
                if not os.path.islink(f):
                    continue
                to = os.readlink(f)
                if to.startswith('/'):
                    continue
                rel = os.path.normpath(os.path.join(os.path.relpath(dirpath, t), to))
                if rel.startswith('..') or rel.split('/')[:2] in (['usr', 'lib'], ['usr', 'include'], ['usr', 'share']):
                    continue
                dst = os.path.join(sysroot, os.path.relpath(f, t))
                if os.path.lexists(dst):
                    os.remove(dst)
                os.symlink('/' + rel, dst)
        # A CMake package file that names the headers by an absolute
        # /usr/include (double-conversion's, written by Debian's packaging
        # rather than CMake's export): the sysroot's, as pkg-config's
        # sysroot prefixes a .pc file's paths.
        for dirpath, _, files in os.walk(t):
            for n in files:
                if not n.endswith('.cmake'):
                    continue
                rel = os.path.relpath(os.path.join(dirpath, n), t)
                f = os.path.join(sysroot, rel)
                if not os.path.isfile(f) or os.path.islink(f):
                    continue
                text = open(f, errors='surrogateescape').read()
                fixed = re.sub(r'(?<=["; ])/usr/include(?=[/";\s])', sysroot + '/usr/include', text)
                fixed = cmake_install_prefix(fixed, sysroot)
                if fixed != text:
                    open(f, 'w', errors='surrogateescape').write(fixed)
        if share_only:
            return
        for sub in ('usr/share/aclocal', 'usr/share/libtool'):
            s = os.path.join(t, sub)
            if chroot and os.path.isdir(s):
                os.makedirs(os.path.join(chroot, sub), exist_ok=True)
                subprocess.run(['cp', '-a', '-n', s + '/.', os.path.join(chroot, sub)], check=True)
        # a -dev package's FOO-config script (gpgrt-config, which
        # libgcrypt's configure looks for on PATH): on the build machine, as
        # a Debian cross build installs the target's -dev package there.
        # Scripts only: a wasm32 program is not the build machine's. Also
        # the target's tool wrappers (qt6-base-dev's
        # wasm32-linux-musl-qtpaths6, which runs the build machine's qtpaths6
        # on the target's qt6.conf), which its CMake packages name by path.
        bindir = os.path.join(t, 'usr/bin')
        if chroot and os.path.isdir(bindir):
            for n in os.listdir(bindir):
                f = os.path.join(bindir, n)
                if (n.endswith('-config') or n.startswith('wasm32-linux-musl-')) and os.path.isfile(f) and open(f, 'rb').read(2) == b'#!' \
                        and not os.path.exists(os.path.join(chroot, 'usr/bin', n)):
                    shutil.copy2(f, os.path.join(chroot, 'usr/bin', n))
    # the target's package database: a Debian cross build has the -dev
    # package installed for the host architecture, and debian/rules ask
    # dpkg-query about it (glib2.0's libffi-dev:HOST_ARCH); the environment's
    # dpkg-query answers a HOST_ARCH query from here
    ctl = subprocess.run(['dpkg-deb', '-f', deb], capture_output=True, text=True, check=True).stdout
    name = re.search(r'^Package: (\S+)', ctl, re.M).group(1)
    db = os.path.join(sysroot, 'var/lib/dpkg')
    os.makedirs(os.path.join(db, 'info'), exist_ok=True)
    st = os.path.join(db, 'status')
    old = open(st).read().split('\n\n') if os.path.exists(st) else []
    keep = [x.strip('\n') for x in old if x.strip() and not re.match(rf'Package: {re.escape(name)}\n', x.strip('\n') + '\n')]
    lines = ctl.rstrip('\n').split('\n')
    lines.insert(1, 'Status: install ok installed')
    with open(st + '.new', 'w') as f:
        f.write('\n\n'.join(keep + ['\n'.join(lines)]) + '\n')
    os.replace(st + '.new', st)
    # and its files, so a search by path finds it (dh_qmldeps asks which
    # package holds the qmldir of each QML module a module imports)
    sysroot_list(db, deb, ctl, name)


def sysroot_list(db, deb, ctl, name):
    """dpkg's file list of `deb` in the package database `db`: info/PKG.list,
    PKG:ARCH for a Multi-Arch: same package, as dpkg names it."""
    same = re.search(r'^Multi-Arch: same$', ctl, re.M)
    arch = re.search(r'^Architecture: (\S+)', ctl, re.M).group(1)
    stem = f'{name}:{arch}' if same else name
    # the multiarch layout of info/ (PKG:ARCH names); without it dpkg looks
    # for PKG.list
    fmt = os.path.join(db, 'info', 'format')
    if not os.path.exists(fmt):
        with open(fmt, 'w') as f:
            f.write('1\n')
    out = subprocess.run(['dpkg-deb', '--fsys-tarfile', deb], capture_output=True, check=True).stdout
    names = subprocess.run(['tar', '-t'], input=out, capture_output=True, check=True).stdout.decode(errors='replace')
    paths = ['/.']
    for n in names.splitlines():
        n = n[1:] if n.startswith('.') else n
        n = n.rstrip('/')
        if n:
            paths.append(n)
    # (and each library under /usr/lib by its /lib name too, as the merged
    # /usr finds it: dpkg-shlibdeps searches /lib/TRIPLET first and asks
    # dpkg which package holds the path it found)
    paths += ['/lib/' + x[len('/usr/lib/'):] for x in paths if x.startswith('/usr/lib/wasm32-linux-musl/')]
    with open(os.path.join(db, 'info', stem + '.list.new'), 'w') as f:
        f.write('\n'.join(paths) + '\n')
    os.replace(os.path.join(db, 'info', stem + '.list.new'), os.path.join(db, 'info', stem + '.list'))
    # and its shlibs and symbols files, which dpkg-shlibdeps reads for the
    # dependency a binary linking the library gets
    with tempfile.TemporaryDirectory() as t:
        subprocess.run(['dpkg-deb', '-e', deb, t], check=True)
        for kind in ('shlibs', 'symbols'):
            f = os.path.join(db, 'info', f'{stem}.{kind}')
            if os.path.exists(os.path.join(t, kind)):
                shutil.copyfile(os.path.join(t, kind), f)
            elif os.path.exists(f):
                os.remove(f)


def target_lib(name):
    """Whether a binary package is something the target build links or
    includes (a -dev package or a library), not a tool it runs. Debian marks
    few tools Multi-Arch: foreign (make, cython3, python3-* and the like are
    'allowed' or 'same'), and a cross build cannot run a wasm32 one, so a tool
    is taken from the build machine whatever its marking."""
    if re.search(r'-(perl|python|ruby|tcl|java|ocaml|lua|php)$', name) or name.startswith(('python3-', 'ruby-', 'node-')):
        return False
    # a QML module is the target's (Multi-Arch: same, as a Debian cross build
    # resolves it): dh_qmldeps reads the target's qmldir files
    if name.startswith('qml6-module-'):
        return True
    return name.endswith(('-dev', '-dev-bin')) is False and name.startswith('lib') or name.endswith('-dev')


def leniency(log):
    """What gexcc let through in a build (its log): calls to undeclared C
    library functions (a warning, as on glibc), calls to undeclared
    functions of any other kind (implicit int), and functions linked to a
    trapping stub because they were declared with the wrong type, and the
    sources whose `.symver` aliases were left out. Each name once."""
    t = open(log, errors='replace').read()
    lib = sorted(set(re.findall(r"call to undeclared library function '([^']+)'", t)))
    other = sorted(set(re.findall(r"call to undeclared function '([^']+)'", t)))
    stub = sorted(set(re.findall(r'gexcc: warning: (\S+) is declared .* calls to it trap', t)))
    symver = sorted(set(re.findall(r'gexcc: (\S+): \d+ \.symver directive', t)))
    part = lambda what, xs: f'{what} {len(xs)}' + (f' [{" ".join(xs[:12])}{" ..." if len(xs) > 12 else ""}]' if xs else '')
    return '; '.join([part('undeclared-libc', lib), part('undeclared-other', other), part('trap-stubs', stub),
                      part('symver-dropped', symver)])


def clause_names(field):
    """First alternatives of a Depends-style field, names only."""
    out = []
    for clause in (field or '').split(','):
        alt = clause.split('|')[0].strip()
        m = re.match(r'([a-z0-9][a-z0-9+.-]*)', alt)
        if m:
            out.append(m.group(1))
    return out


def toolchain(prefix):
    """What PREFIX's gexcc was installed from (install.sh's installed-from):
    {'gex': commit, 'gex-repo': path, 'musl': commit}."""
    try:
        return dict(l.split(None, 1) for l in open(os.path.join(prefix, 'lib/gexcc/installed-from')).read().split('\n') if ' ' in l)
    except FileNotFoundError:
        return {}


def rebuild_forcing(path=os.path.join(HERE, 'rebuild-after.txt')):
    """rebuild-after.txt: [(commit, log pattern or None)], the gexcc fixes a
    package built before must be built again after (a fix that changes what
    a successful build makes), each optionally only for builds whose log
    shows the fix's case."""
    out = []
    for line in open(path):
        line = line.split('|')[0].strip()
        if line and not line.startswith('#'):
            w = line.split(None, 1)
            out.append((w[0], re.compile(w[1]) if len(w) > 1 else None))
    return out


def stale(built_with, log, fixes, repo):
    """The first of FIXES that applies to a build with the toolchain commit
    BUILT_WITH (a build that recorded none predates them all) and its LOG,
    and that the commit does not contain; or None."""
    text = None
    for f, pattern in fixes:
        if pattern:
            if text is None:
                try:
                    text = open(log, errors='replace').read()
                except FileNotFoundError:
                    text = ''
            if not pattern.search(text):
                continue
        if not built_with or built_with == 'unknown':
            return f
        c = built_with.rstrip('+')
        if subprocess.run(['git', '-C', repo, 'merge-base', '--is-ancestor', f, c],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            return f
    return None


class Builder:
    def __init__(self, a):
        self.a = a
        self.work = os.path.abspath(a.work)
        self.cache = a.cache or os.path.join(self.work, 'deb')
        for d in ('src', 'debs', 'logs'):
            os.makedirs(os.path.join(self.work, d), exist_ok=True)
        self.sysroot = os.path.join(a.prefix, 'sysroot')
        self.debian, _ = debfetch.packages(self.cache, 'trixie', 'amd64')
        self.chroot_has = installed(a.chroot)
        self.unpacked = set()
        self.ours = built_debs(self.work)
        self.toolchain = toolchain(a.prefix)

    def source_of(self, binary):
        p = self.debian.get(binary)
        return (p.get('Source') or p['Package']).split()[0] if p else None

    def fetch(self, name):
        r = subprocess.run([sys.executable, '-I', os.path.join(HERE, '..', 'debsrc.py'), '--cache', self.cache,
                            '--suite', suite_of(name),
                            '--into', os.path.join(self.work, 'src'), name], capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError(f'fetch: {r.stderr.strip()[-300:]}')
        _, ver, srcdir = r.stdout.split()[:3]
        return ver, srcdir

    def libs_of_source(self, src):
        """Our shared library packages (libNAME<soversion>) built from SRC."""
        if getattr(self, '_src_libs_for', None) is not self.ours:
            m = {}
            for name, deb in set(self.ours.items()):
                if not re.fullmatch(r'lib.*\d(t64)?', name):
                    continue
                f = subprocess.run(['dpkg-deb', '-f', deb, 'Package', 'Source'], capture_output=True, text=True).stdout
                d = dict(l.split(': ', 1) for l in f.splitlines() if ': ' in l)
                if d.get('Package') == name:
                    m.setdefault((d.get('Source') or name).split(' ')[0], []).append(name)
            self._src_libs, self._src_libs_for = m, self.ours
        return self._src_libs.get(src, [])

    def target_closure(self, deps):
        """What the target side of DEPS needs in the sysroot: (debs to unpack,
        binaries not built yet, build-machine tools the chroot lacks)."""
        debs, needs, lacks, seen = [], [], [], set()
        todo = list(deps)
        while todo:
            dep, q = todo.pop()
            # DEP and DEP:native are two packages (the target's and the build machine's)
            if (dep, q == 'native') in seen or dep in TOOLCHAIN:
                continue
            seen.add((dep, q == 'native'))
            p = self.debian.get(dep)
            # a package of our own Debian has no such name for (gex-gl, the
            # GL provider's libraries) is the target's
            ours_only = p is None and dep in self.ours
            # Multi-Arch: same is the target's, as a cross build resolves it
            # (qt6-base-dev -> qmake6, whose mkspecs/linux-* the next Qt
            # module's configure reads)
            same = p is not None and p.get('Multi-Arch') == 'same' and dep in self.ours
            build_side = q in ('native', 'any') or not (target_lib(dep) or ours_only or same) or (
                p is not None and (p.get('Architecture') == 'all' or p.get('Multi-Arch') == 'foreign'))
            # a tool is the build machine's even when we built a wasm32 one
            if dep in self.ours and not build_side:
                deb = self.ours[dep]
                debs.append(deb)
                f = dict(l.split(': ', 1) for l in subprocess.run(['dpkg-deb', '-f', deb, 'Package', 'Source', 'Depends'],
                                                                  capture_output=True, text=True).stdout.splitlines() if ': ' in l)
                # a dependency its source cut (cuts.txt) was never built
                # against, or a sibling it dropped: the -dev package still
                # names them (dpkg-buildpackage -d leaves debian/control as
                # it is)
                src = (f.get('Source') or f.get('Package', '')).split(' ')[0]
                c = CUTS.get(src, {})
                cut = c.get('cut', set()) | c.get('drop', set())
                todo += [(n, None) for n in clause_names(f.get('Depends', '')) if n not in cut]
                # and its source's shared libraries: a -dev package's CMake
                # export names every library of the source, and the
                # dependencies dh_shlibdeps would add between them (a QML
                # module on libKirigamiPrimitives) are not computed for wasm
                # side modules, so a -dev package's Depends can miss one
                if f.get('Package', '').endswith('-dev'):
                    todo += [(n, None) for n in self.libs_of_source(src) if n not in cut]
                continue
            if build_side and q is None and dep in self.ours and not (
                    p is not None and (p.get('Architecture') == 'all' or p.get('Multi-Arch') == 'foreign')):
                # a tool a target package depends on (hfst-ospell-dev on
                # hfst-ospell): the tool is not unpacked, but the libraries
                # it depends on are the target's (libhfstospell11, which the
                # -dev package's .so link points at)
                # (one field asked for, dpkg-deb -f prints only its value)
                d = subprocess.run(['dpkg-deb', '-f', self.ours[dep], 'Depends'], capture_output=True, text=True).stdout
                # shared libraries only (a soname's package: libfoo11,
                # libbar2t64), not what a tool runs on (libpython3.13-stdlib)
                todo += [(n, None) for n in clause_names(d.strip()) if re.fullmatch(r'lib.*\d(t64)?', n)]
            if build_side or (p is None and dep in self.chroot_has):
                # an Arch: all -dev (headers, or a transitional name) goes
                # to the sysroot only; anything else build-side runs there
                sysroot_only = p is not None and p.get('Architecture') == 'all' and q != 'native' and target_lib(dep)
                if dep not in self.chroot_has and q is not None and not sysroot_only:
                    lacks.append(dep)
                if p is not None and p.get('Architecture') == 'all' and q != 'native':
                    debs.append(debfetch.fetch(self.cache, p))
                    todo += [(n, None) for n in clause_names(p.get('Depends'))]
                elif p is not None and p.get('Multi-Arch') == 'foreign' and q in (None, '') and dep in self.chroot_has:
                    # a tool the build or a target package depends on
                    # (libkf6doctools-dev on kdoctools6, packagekit-qt on
                    # packagekit): its data is in the one /usr/share of a
                    # Debian cross build, where the target's CMake package
                    # (KDOCTOOLS_CUSTOMIZATION_DIR) or a find_path rerooted
                    # in the sysroot (PackageKit's D-Bus XML) looks; in the
                    # sysroot too, its programs not
                    debs.append((debfetch.fetch(self.cache, p), 'share'))
                continue
            needs.append(dep)
        return debs, needs, lacks

    def headers_of(self, binary):
        """The headers-only source (cuts.txt `headers`) BINARY comes from,
        when it is one of that source's packages that were not repacked: a
        compiled library there is none of for wasm32."""
        s = self.source_of(binary)
        h = CUTS.get(s, {}).get('headers', set()) if s else set()
        return s if h and binary not in h else None

    def repack_headers(self, name):
        """A `headers` source: its named binary packages are Debian's own
        build-machine debs, repacked for the target. Only headers and text
        (CMake package files) may be in them: anything compiled (an ELF
        file, a static or shared library) stops the repack."""
        made, ver = [], None
        for binary in sorted(CUTS[name]['headers']):
            p = self.debian.get(binary)
            if p is None:
                return f'headers: no package {binary} in the archive'
            ver = p['Version']
            deb = debfetch.fetch(self.cache, p)
            with tempfile.TemporaryDirectory() as t:
                subprocess.run(['dpkg-deb', '-R', deb, t], check=True)
                for root, _, files in os.walk(t):
                    if os.path.relpath(root, t).split(os.sep)[0] == 'DEBIAN':
                        continue
                    for f in files:
                        path = os.path.join(root, f)
                        if os.path.islink(path):
                            continue
                        with open(path, 'rb') as fh:
                            magic = fh.read(8)
                        if magic.startswith(b'\x7fELF') or magic == b'!<arch>\n' or re.search(r'\.(a|o|so)(\.[0-9.]+)?$', f):
                            return f'headers: {binary} holds a compiled file ({os.path.relpath(path, t)})'
                # the build machine's multiarch directory is the target's
                lib = os.path.join(t, 'usr/lib')
                if os.path.isdir(lib):
                    for d in os.listdir(lib):
                        if re.match(r'[a-z0-9_]+-linux-gnu[a-z]*$', d):
                            os.rename(os.path.join(lib, d), os.path.join(lib, 'wasm32-linux-musl'))
                ctl = os.path.join(t, 'DEBIAN', 'control')
                text = re.sub(r'(?m)^Architecture: .*$', f'Architecture: {ARCH}', open(ctl).read())
                open(ctl, 'w').write(text)
                for x in ('md5sums',):
                    if os.path.exists(os.path.join(t, 'DEBIAN', x)):
                        os.unlink(os.path.join(t, 'DEBIAN', x))
                out = os.path.join(self.work, 'debs', f'{binary}_{ver.split(":")[-1]}_{ARCH}.deb')
                subprocess.run(['dpkg-deb', '--root-owner-group', '-Zxz', '-b', t, out], check=True,
                               stdout=subprocess.DEVNULL)
                made.append(os.path.basename(out))
        self.ours = built_debs(self.work)
        with open(os.path.join(self.work, 'built.txt'), 'a') as f:
            f.write(f'{name} {ver} gexcc={self.toolchain.get("gex", "unknown")}\n')
        print(f'ok {name} {ver} (headers only, repacked): {" ".join(made)}', flush=True)
        return 'ok'

    def plan(self, name, index=False):
        """INDEX: read Build-Depends from the archive's Sources index rather
        than fetching the source (the same fields, for ordering only)."""
        if CUTS.get(name, {}).get('headers'):
            # repacked, not built: nothing of its own Build-Depends is needed
            return None, None, [], [], []
        if index:
            if not hasattr(self, 'sources'):
                self.sources = {}
            suite = suite_of(name)
            if suite not in self.sources:
                self.sources[suite] = debsrc.sources(self.cache, suite)
            st = self.sources[suite].get(name)
            if st is None:
                raise RuntimeError(f'no source package {name}')
            ver, srcdir = st['Version'], None
            control = f'Source: {name}\n' + ''.join(f'{k}: {st[k]}\n' for k in ('Build-Depends', 'Build-Depends-Arch')
                                                    if k in st)
        else:
            ver, srcdir = self.fetch(name)
            control = open(os.path.join(srcdir, 'debian/control')).read()
        cut = CUTS.get(name, {}).get('cut', set())
        deps = [(d, q) for d, q in deps_of(control, profiles_of(name)) if d not in cut]
        debs, needs, lacks = self.target_closure([(d, q if q else '') for d, q in deps])
        return ver, srcdir, debs, needs, lacks

    def build(self, name):
        """One source package: 'ok', or the reason it was not built."""
        if CUTS.get(name, {}).get('headers'):
            return self.repack_headers(name)
        ver, srcdir, debs, needs, lacks = self.plan(name)
        if CUTS.get(name, {}).get('arch'):
            add_arch(os.path.join(srcdir, 'debian', 'control'), CUTS[name]['arch'])
        compiled = [f'{n} (a compiled library of {self.headers_of(n)}, which is headers only for wasm32: cuts.txt)'
                    for n in needs if self.headers_of(n)]
        if compiled:
            return 'needs ' + ' '.join(compiled)
        if needs or lacks:
            return f'needs {" ".join(needs) or "-"}; chroot lacks {" ".join(lacks) or "-"}'
        for deb in debs:
            if isinstance(deb, tuple):
                into_sysroot(deb[0], self.sysroot, self.unpacked, share_only=True)
            else:
                into_sysroot(deb, self.sysroot, self.unpacked, self.a.chroot)
        log = os.path.join(self.work, 'logs', f'{name}.log')
        env = (f'GEXCC_SHARED={os.environ.get("GEXCC_SHARED", "1")} DEB_BUILD_PROFILES="{" ".join(sorted(profiles_of(name)))}" '
               f'DEB_BUILD_OPTIONS="nocheck nodoc noautodbgsym parallel={self.a.jobs}" '
               'DPKG_GENSYMBOLS_CHECK_LEVEL=0')
        c = CUTS.get(name)
        # make variables over what debian/rules sets (a command-line variable
        # beats the makefile's, `export` or not): symbols files are checked
        # at level 0 even where the rules export a stricter level, since a
        # wasm module has no symbol versions and every versioned list differs
        sysroot = os.path.join(os.path.realpath(self.a.prefix), 'sysroot')
        makevars = ['DPKG_GENSYMBOLS_CHECK_LEVEL=0'] + (c['make'] if c else [])
        env += " MAKEFLAGS='" + ' '.join(v.replace(' ', '\\ ') for v in makevars) + "'"
        if c and (c['drop'] or c['exclude']):
            env += ' DH_OPTIONS="' + ' '.join([f'-N{b}' for b in sorted(c['drop'])] +
                                             [f'-X{x}' for x in sorted(c['exclude'])]) + '"'
        if c:
            # @CROSS@: this directory (in-chroot.sh binds it read-only);
            # @SYSROOT@: the target's
            env += ''.join(f' {e.replace("@CROSS@", HERE).replace("@SYSROOT@", sysroot)}' for e in c['env'])
        # ECM leaves KDevelop's app templates out of a cross build, and a
        # KDE -dev package's .install lists them (Debian's own content).
        # plasma-wayland-protocols is Multi-Arch: foreign (protocol XML for
        # the build machine's wayland-scanner), so only the chroot has it,
        # in the build machine's multiarch directory, which a sysroot
        # search does not reach, and its version file refuses a 32-bit
        # target: cmake/PlasmaWaylandProtocols here is that package without
        # the 32/64-bit check
        cmake_vars = [('KDE_INSTALL_APP_TEMPLATES', 'ON'),
                      ('PlasmaWaylandProtocols_DIR', '@CROSS@/cmake/PlasmaWaylandProtocols')] + (c['cmake'] if c else [])
        if cmake_vars:
            init = os.path.join(self.work, 'cmake-init', f'{name}.cmake')
            os.makedirs(os.path.dirname(init), exist_ok=True)
            with open(init, 'w') as f:
                for var, val in cmake_vars:
                    kind = 'BOOL' if val.upper() in ('ON', 'OFF', 'TRUE', 'FALSE') else 'STRING'
                    val = val.replace('@SYSROOT@', sysroot).replace('@CROSS@', HERE)
                    f.write(f'set({var} {val} CACHE {kind} "cuts.txt" FORCE)\n')
            env += f' GEXCC_CMAKE_INIT={init}'
        if c and c['meson']:
            init = os.path.join(self.work, 'meson-init', f'{name}.txt')
            os.makedirs(os.path.dirname(init), exist_ok=True)
            with open(init, 'w') as f:
                f.write(''.join(f'-D{o}\n' for o in c['meson']))
            env += f' GEXCC_MESON_INIT={init}'
        if c and c['autoconf']:
            # a configure script reads CONFIG_SITE after its options, so a
            # site file's with_X=no beats the rules' --with-X; this one
            # reads gexcc's own first (a configure from autoconf 2.69 takes
            # CONFIG_SITE as a single file)
            site = os.path.join(self.work, 'autoconf-site', f'{name}.site')
            os.makedirs(os.path.dirname(site), exist_ok=True)
            with open(site, 'w') as f:
                f.write(f'. {os.path.join(self.a.prefix, "share/gexcc/config.site")}\n' +
                        ''.join(f'{v.replace("@SYSROOT@", sysroot)}\n' for v in c['autoconf']))
            env += f' CONFIG_SITE={site}'
        # a tree kept from an earlier attempt: debhelper's stamp says it is
        # built, and a clean target that does not run dh_clean (db5.3's)
        # leaves the stamp and removes the build
        stamp = os.path.join(srcdir, 'debian', 'debhelper-build-stamp')
        if os.path.exists(stamp):
            os.unlink(stamp)
        # fakeroot for the targets that need root (pam's chgrp shadow): uid 0
        # in the chroot's user namespace has no other group to give a file,
        # so fakeroot only records the owner (EINVAL from the real chown is
        # not the EPERM it would forgive)
        cmd = f'cd {srcdir} && {env} FAKEROOTDONTTRYCHOWN=1 dpkg-buildpackage -a {ARCH} -d -B -uc -us -rfakeroot'
        with open(log, 'w') as f:
            r = subprocess.run([os.path.join(HERE, 'in-chroot.sh'), self.a.chroot, self.a.prefix, self.a.env,
                                '--bind', self.work, '--', 'bash', '-c', cmd], stdout=f, stderr=subprocess.STDOUT)
        if r.returncode:
            tail = open(log, errors='replace').read().strip().split('\n')[-3:]
            return f'build (log {log}): ' + ' | '.join(tail)
        parent = os.path.dirname(srcdir)
        made = []
        # the .changes names every .deb the build made, a binary package
        # with a version of its own too (e2fsprogs' comerr-dev 2.1-1.47.2-3)
        debs = set(glob.glob(os.path.join(parent, f'*_{ver.split(":")[-1]}_*.deb')))
        for ch in glob.glob(os.path.join(parent, f'{name}_*.changes')):
            debs |= {os.path.join(parent, m) for m in re.findall(r'(?m)^ [0-9a-f]{64} \d+ (\S+\.deb)$', open(ch).read())
                     if os.path.exists(os.path.join(parent, m))}
        for f in sorted(debs):
            shutil.move(f, os.path.join(self.work, 'debs', os.path.basename(f)))
            made.append(os.path.basename(f))
        for f in glob.glob(os.path.join(parent, f'{name}_*.buildinfo')) + glob.glob(os.path.join(parent, f'{name}_*.changes')):
            os.unlink(f)
        self.ours = built_debs(self.work)
        if not made:
            return 'build made no .deb'
        with open(os.path.join(self.work, 'built.txt'), 'a') as f:
            f.write(f'{name} {ver} gexcc={self.toolchain.get("gex", "unknown")}\n')
        lenient = leniency(log)
        with open(os.path.join(self.work, 'lenient.txt'), 'a') as f:
            f.write(f'{name} {ver}: {lenient}\n')
        print(f'ok {name} {ver} ({lenient}): {" ".join(sorted(made))}', flush=True)
        return 'ok'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--chroot', required=True)
    ap.add_argument('--prefix', required=True)
    ap.add_argument('--env', required=True)
    ap.add_argument('--work', required=True)
    ap.add_argument('--cache', default=os.environ.get('DEB_CACHE'))
    ap.add_argument('--jobs', default=os.environ.get('JOBS', '8'))
    ap.add_argument('--auto', action='store_true',
                    help='build what each package needs first, in dependency order')
    ap.add_argument('--plan', action='store_true', help='with --auto: print the order, build nothing')
    ap.add_argument('pkgs', nargs='+')
    a = ap.parse_args()
    b = Builder(a)
    bt = os.path.join(b.work, 'built.txt')
    # a source's last line says what it was last built with
    last = {}
    for l in (open(bt) if os.path.exists(bt) else []):
        w = l.split()
        if w:
            last[w[0]] = next((x.split('=', 1)[1] for x in w[2:] if x.startswith('gexcc=')), None)
    fixes = rebuild_forcing()
    repo = b.toolchain.get('gex-repo')
    built, stale_srcs = set(), set()
    for src, tc in last.items():
        f = stale(tc, os.path.join(b.work, 'logs', f'{src}.log'), fixes, repo) if fixes and repo else None
        if f:
            stale_srcs.add(src)
            print(f'stale {src}: built with gexcc {tc or "(not recorded)"}, before {f}', file=sys.stderr, flush=True)
        else:
            built.add(src)
    state = {}   # source -> 'ok' | reason | 'visiting'
    order = []

    def visit(src, chain):
        if src in built and src not in a.pkgs:
            return
        if src in state:
            if state[src] == 'visiting':
                print(f'cycle: {" -> ".join(chain + [src])}', flush=True)
            return
        state[src] = 'visiting'
        try:
            _, _, debs, needs, _ = b.plan(src, index=True)
        except RuntimeError as e:
            state[src] = str(e)
            return
        # what the sysroot has from a build a rebuild-forcing fix postdates
        needs = list(needs) + [n for n in (os.path.basename(d).split('_')[0] for d in debs if not isinstance(d, tuple))
                               if b.source_of(n) in stale_srcs]
        for bin_ in needs:
            s = b.source_of(bin_)
            if s and s != src:
                visit(s, chain + [src])
        state[src] = 'planned'
        order.append(src)
        print(f'  {len(order)}: {src} (needs {len(needs)}) via {" <- ".join(reversed(chain[-6:]))}', file=sys.stderr, flush=True)

    if not a.auto:
        order = list(a.pkgs)
    else:
        for p in a.pkgs:
            visit(p, [])
        print('order: ' + ' '.join(order), flush=True)
        if a.plan:
            return
    failed = 0
    for src in order:
        try:
            r = b.build(src)
        except RuntimeError as e:
            r = str(e)
        if r != 'ok':
            print(f'FAIL {src}: {r}', flush=True)
            failed += 1
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
