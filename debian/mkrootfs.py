#!/usr/bin/env python3
"""Assemble the native Debian rootfs (docs/gexcc.md §6): Debian's arm64
system pieces (dpkg, apt, perl-base, libc6, ...), Debian's architecture-
independent data, and our musl-linux-wasm32 packages in place of Debian's
tools, with a dpkg database that says so and apt set up for both.

    mkrootfs.py --pool POOL --out DIR [--tar FILE] [--roots PKG,...]

No root and no maintainer scripts: every .deb is unpacked (dpkg-deb
--fsys-tarfile) into DIR with /bin, /sbin and /lib as /usr's (merged /usr);
/var/lib/dpkg/status, info/*.list, *.md5sums and *.conffiles are written
from the packages; what the scripts would have done for this closure
(accounts, /etc/shells, alternatives, the CA bundle, /root's dot files) is
done here. Debian's packages are verified (debfetch.py: InRelease ->
Packages -> .deb) and cached.

Our packages (POOL, from mkdebs.py) stand in for Debian's by name: a
dependency an arm64 package has on `coreutils` or `awk` is met by ours
(Multi-Arch: foreign), and Debian's copy is not unpacked. apt: Debian's
repository for arm64 only, ours (Origin gex) as a file: repository at
/var/lib/gex-apt for musl-linux-wasm32, pinned so that apt never replaces
one of ours with Debian's (docs/gexcc.md §6.1a).
"""
import argparse, glob, gzip, hashlib, io, lzma, os, re, shlex, shutil, subprocess, sys, tarfile, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import debfetch  # noqa: E402

a_minimal = True
a_native_ours = False
# where apt finds our repository (--repo-url), the image's own by default
a_repo_uri = 'file:/var/lib/gex-apt'

OURS_ARCH = 'musl-linux-wasm32'
NATIVE = 'arm64'
SUITE = 'trixie'
# The arm64 roots: what apt and dpkg need to run, and what the image needs
# to be a Debian system (the rest of Essential comes from our pool).
ROOTS = ['apt', 'dpkg', 'base-files', 'base-passwd', 'debian-archive-keyring', 'ncurses-base',
         'libc-bin', 'perl-base', 'debconf', 'ca-certificates', 'usr-is-merged', 'sensible-utils',
         'netbase', 'init-system-helpers', 'login.defs']
MIRROR_URI = 'http://deb.debian.org/debian'
SECURITY_URI = 'http://security.debian.org/debian-security'


def control(deb):
    out = subprocess.run(['dpkg-deb', '-f', deb], check=True, capture_output=True, text=True).stdout
    return next(debfetch.stanzas(out))


def control_member(deb, name):
    """A file of the control archive (md5sums, conffiles), or None."""
    with tempfile.TemporaryDirectory() as t:
        subprocess.run(['dpkg-deb', '-e', deb, t], check=True)
        p = os.path.join(t, name)
        return open(p, encoding='utf-8', errors='replace').read() if os.path.exists(p) else None


def data_md5sums(deb):
    """md5sums as dpkg-deb's builders write them, from the data archive's
    files: for a package built without one (gex-gl), so dpkg --audit has
    nothing to say of it in the image."""
    data = subprocess.run(['dpkg-deb', '--fsys-tarfile', deb], check=True, capture_output=True).stdout
    out = []
    with tarfile.open(fileobj=io.BytesIO(data)) as tf:
        for m in tf.getmembers():
            if m.isfile():
                out.append(f'{hashlib.md5(tf.extractfile(m).read()).hexdigest()}  {os.path.normpath(m.name)}')
    return ''.join(l + '\n' for l in out)


# As Debian's minimized images (and dpkg's path-exclude, which the image
# carries so apt installs behave the same): no documentation or
# translations; copyright files stay.
EXCLUDE = ['/usr/share/doc/*', '/usr/share/man/*', '/usr/share/info/*', '/usr/share/locale/*',
           '/usr/share/lintian/*', '/usr/share/linda/*', '/usr/share/groff/*',
           # glibc's iconv modules (20 MB): the Unicode and Western ones stay
           # (UTF-8 and ISO-8859-1 are built into libc)
           '/usr/lib/*/gconv/*.so']
INCLUDE = ['/usr/share/doc/*/copyright', '/usr/lib/*/gconv/UTF-*.so', '/usr/lib/*/gconv/UNICODE.so',
           '/usr/lib/*/gconv/ISO8859-15.so', '/usr/lib/*/gconv/CP1252.so', '/usr/lib/*/gconv/libGB.so',
           '/usr/lib/*/gconv/libJIS.so', '/usr/lib/*/gconv/EUC-JP.so', '/usr/lib/*/gconv/SJIS.so']


def alternatives(postinst, alts):
    """The `update-alternatives --install` calls of a maintainer script, which
    is not run: {name: (priority, link, path, [(link, name, path)...])},
    the highest priority's kept. Calls built from shell variables are skipped."""
    if not postinst:
        return
    text = re.sub(r'\\\n', ' ', postinst)
    # plain assignments (`ver=1.17`, `prio=1170`) the calls use
    for k, v in re.findall(r'^\s*([A-Za-z_][A-Za-z0-9_]*)=["\']?([^\s"\'$`;]+)["\']?\s*$', text, re.M):
        text = re.sub(r'\$\{?' + k + r'\b\}?', v, text)
    for m in re.finditer(r'update-alternatives\b[^\n;|&]*?--install\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)([^\n;|&]*)', text):
        link, name, path, prio, rest = m.groups()
        slaves = re.findall(r'--slave\s+(\S+)\s+(\S+)\s+(\S+)', rest)
        if '$' in link + name + path + prio:
            continue
        slaves = [x for x in slaves if '$' not in ''.join(x)]
        if name not in alts or int(prio) > alts[name][0]:
            alts[name] = (int(prio), link, path, slaves)


def link_alternatives(root, alts):
    """What update-alternatives would have made: LINK -> /etc/alternatives/NAME
    -> PATH, for each name whose path is in the tree, slaves too."""
    d = os.path.join(root, 'etc/alternatives')
    os.makedirs(d, exist_ok=True)
    for name, (_, link, path, slaves) in sorted(alts.items()):
        for ln, nm, pt in [(link, name, path)] + slaves:
            if not os.path.lexists(os.path.join(root, real_rel(root, pt.lstrip('/')))):
                continue
            a = os.path.join(d, nm)
            if not os.path.lexists(a):
                os.symlink(pt, a)
            ldir = os.path.join(root, real_rel(root, os.path.dirname(ln).lstrip('/')))
            lp = os.path.join(ldir, os.path.basename(ln))
            if os.path.isdir(ldir) and not os.path.lexists(lp):
                os.symlink('/etc/alternatives/' + nm, lp)


def excluded(path):
    import fnmatch
    return any(fnmatch.fnmatch(path, g) for g in EXCLUDE) and not any(fnmatch.fnmatch(path, g) for g in INCLUDE)


def unpack(deb, root):
    """Unpack the data archive; returns the paths it holds (dpkg's .list)."""
    data = subprocess.run(['dpkg-deb', '--fsys-tarfile', deb], check=True, capture_output=True).stdout
    paths = []
    with tarfile.open(fileobj=io.BytesIO(data)) as tf:
        for m in tf.getmembers():
            rel = os.path.normpath(m.name)
            if rel == '.':
                paths.append('/.')
                continue
            if a_minimal and excluded('/' + rel) and not m.isdir():
                continue
            paths.append('/' + rel)
            dest = os.path.join(root, real_rel(root, rel))
            if m.isdir():
                if not os.path.isdir(dest):
                    os.makedirs(dest, exist_ok=True)
                os.chmod(dest, m.mode | 0o700)
                continue
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            if m.issym() and os.path.islink(dest) and os.readlink(dest) == m.linkname:
                continue  # base-files' /bin -> usr/bin, made already
            if os.path.islink(dest) or (os.path.lexists(dest) and not os.path.isdir(dest)):
                os.unlink(dest)
            if m.issym():
                os.symlink(m.linkname, dest)
            elif m.islnk():
                os.link(os.path.join(root, real_rel(root, os.path.normpath(m.linkname))), dest)
            elif m.isfile():
                with tf.extractfile(m) as src, open(dest, 'wb') as f:
                    shutil.copyfileobj(src, f)
                os.chmod(dest, m.mode & 0o7777 | 0o600)
    return paths


def real_rel(root, rel):
    """`rel` with merged-/usr aliases followed (bin -> usr/bin ...)."""
    top, _, rest = rel.partition('/')
    if rest and top in ('bin', 'sbin', 'lib') and os.path.islink(os.path.join(root, top)):
        return os.path.join('usr', top, rest)
    return rel


def md5(path):
    return hashlib.md5(open(path, 'rb').read()).hexdigest()


def without(ctl, gone):
    """ctl with the Depends, Pre-Depends and Recommends clauses that only
    `gone` packages meet left out."""
    out = dict(ctl)
    for k in ('Depends', 'Pre-Depends', 'Recommends'):
        if k not in ctl:
            continue
        keep = [c.strip() for c in ctl[k].split(',')
                if not all(x.strip().split(' ')[0].split(':')[0] in gone for x in c.split('|'))]
        if keep:
            out[k] = ', '.join(keep)
        else:
            del out[k]
    return out


def any_arch(ctl):
    """CTL as apt and dpkg see one of ours in the image: a package of ours
    that is not a Multi-Arch: same library says Multi-Arch: foreign (also
    for Debian's `allowed`, perl and python3, and for packages Debian marks
    nothing, perl-base). Ours is what runs for every architecture's program,
    so an arm64 package's dependency on perl, systemd or kio6 is met by ours
    and installs; without it apt would need Debian's arm64 build of that
    name, which cannot go in beside ours (one architecture per name), and
    the install is refused. all-foreign.sh keeps it so after dpkg runs."""
    if ctl.get('Architecture') == OURS_ARCH and ctl.get('Multi-Arch') != 'same':
        ctl = dict(ctl)
        ctl['Multi-Arch'] = 'foreign'
        # a build of ours with a version of its own (+gex1) is Debian's
        # version too for what depends on that exactly (python3.13-venv on
        # python3.13 (= 3.13.5-2+deb13u5)): it Provides its name at it
        m = re.fullmatch(r'(.+?)\+gex\d+', ctl.get('Version', ''))
        if m:
            own = f'{ctl["Package"]} (= {m.group(1)})'
            ctl['Provides'] = f'{ctl["Provides"]}, {own}' if ctl.get('Provides') else own
    # and NAME:any on one of ours (python3:any) is a plain NAME: :any is
    # met only by Multi-Arch: allowed, which ours no longer say
    for f in ('Pre-Depends', 'Depends', 'Recommends'):
        if ':any' in ctl.get(f, ''):
            ctl = dict(ctl)
            ctl[f] = re.sub(r'([a-z0-9][a-z0-9.+-]*):any\b',
                            lambda m: m.group(1) if m.group(1) in ANY_ARCH_NAMES else m.group(0), ctl[f])
    return ctl


ANY_ARCH_NAMES = set()  # ours, and what they provide (main fills it)


def status_stanza(ctl, conffiles_md5, hold=False):
    ctl = any_arch(ctl)
    keys = list(ctl)
    out = [f'Package: {ctl["Package"]}', f'Status: {"hold" if hold else "install"} ok installed']
    for k in keys:
        if k in ('Package', 'Filename', 'Size', 'MD5sum', 'SHA256', 'SHA1', 'Description-md5'):
            continue
        out.append(f'{k}: {ctl[k]}')
    if conffiles_md5:
        out.append('Conffiles:')
        out += [f' {p} {h}' for p, h in conffiles_md5]
    return '\n'.join(out) + '\n'


def info_name(ctl):
    """dpkg's info file stem: `pkg:arch` for a Multi-Arch: same package."""
    if ctl.get('Multi-Arch') == 'same':
        return f'{ctl["Package"]}:{ctl["Architecture"]}'
    return ctl['Package']


def write_repo(root, debs, repo=None):
    """Our packages as an apt repository at /var/lib/gex-apt (Packages,
    Release; the .debs themselves are installed already and not copied,
    but for --repo-debs and a twin from another suite), or at REPO outside
    the image (--repo-out), every .deb in it."""
    repo = repo or os.path.join(root, 'var/lib/gex-apt')
    rel_sums = []
    # wasm32 tools, and dpkg/apt labelled arm64 (one index per architecture)
    for arch in (OURS_ARCH, NATIVE):
        bindir = os.path.join(repo, f'dists/{SUITE}/main/binary-{arch}')
        os.makedirs(bindir, exist_ok=True)
        stanzas = []
        for deb, ctl in debs:
            if ctl['Architecture'] != arch:
                continue
            name = ctl['Package']
            fn = f'pool/main/{name[0]}/{name}/{os.path.basename(deb)}'
            data = open(deb, 'rb').read()
            if ctl.get('_copy'):
                os.makedirs(os.path.dirname(os.path.join(repo, fn)), exist_ok=True)
                if os.path.exists(os.path.join(repo, fn)):
                    os.unlink(os.path.join(repo, fn))
                try:
                    os.link(os.path.realpath(deb), os.path.join(repo, fn))
                except OSError:
                    shutil.copy(deb, os.path.join(repo, fn))
            st = [f'{k}: {v}' for k, v in any_arch(ctl).items() if not k.startswith('_')]
            st += [f'Filename: {fn}', f'Size: {len(data)}', f'MD5sum: {hashlib.md5(data).hexdigest()}',
                   f'SHA256: {hashlib.sha256(data).hexdigest()}']
            stanzas.append('\n'.join(st) + '\n')
        text = '\n'.join(stanzas).encode()
        open(os.path.join(bindir, 'Packages'), 'wb').write(text)
        open(os.path.join(bindir, 'Packages.xz'), 'wb').write(lzma.compress(text))
        for leaf in ('Packages', 'Packages.xz'):
            p = os.path.join(bindir, leaf)
            rel_sums.append(f' {hashlib.sha256(open(p, "rb").read()).hexdigest()} {os.path.getsize(p)} '
                            f'main/binary-{arch}/{leaf}')
    import email.utils
    rel = [f'Origin: gex', 'Label: gex native', f'Suite: {SUITE}', f'Codename: {SUITE}',
           f'Date: {email.utils.formatdate(usegmt=True)}',
           f'Architectures: {OURS_ARCH} {NATIVE}', 'Components: main',
           'Description: Debian tools built from source with gexcc as native wasm32', 'SHA256:'] + rel_sums
    open(os.path.join(repo, f'dists/{SUITE}/Release'), 'w').write('\n'.join(rel) + '\n')
    return repo


def apt_notes(root, notes):
    """apt's hooks (/etc/apt/apt.conf.d/99gex-notes, after 99gex, which clears
    debconf's Pre-Install-Pkgs hook; debian/apt-note.sh) for
    NOTES, what the image knows of a package an install brings in: one
    known not to run here is said so once dpkg is done. apt and apt-get are
    Debian's own."""
    os.makedirs(os.path.join(root, 'usr/share/gex'), exist_ok=True)
    shutil.copy(notes, os.path.join(root, 'usr/share/gex/apt-notes'))
    hook = '/usr/lib/gex/apt-note'
    os.makedirs(os.path.join(root, 'usr/lib/gex'), exist_ok=True)
    shutil.copy(os.path.join(HERE, 'apt-note.sh'), root + hook)
    os.chmod(root + hook, 0o755)
    open(os.path.join(root, 'etc/apt/apt.conf.d/99gex-notes'), 'w').write(
        '// What the image knows of a package an install brings in (/usr/share/gex/apt-notes):\n'
        '// the packages being installed, seen before dpkg runs, and their notes said after\n'
        f'DPkg::Pre-Install-Pkgs {{ "{hook} --record"; }};\n'
        f'DPkg::Tools::Options::{hook}::Version "3";\n'
        f'DPkg::Post-Invoke {{ "{hook} --say"; }};\n')


def installable_ours(ours, pkgs, provides):
    """ours whose every dependency ours (their architecture's, or
    Multi-Arch: foreign) or Debian's architecture-independent packages
    meet, to a fixed point"""
    def names(c):
        return {c['Package']} | {i.strip().split(' ')[0] for i in c.get('Provides', '').split(',') if i.strip()}
    debian_any = {n for n, p in pkgs.items() if p.get('Architecture') == 'all' or p.get('Multi-Arch') == 'foreign'}
    debian_any |= {v for v, n in provides.items() if n in debian_any}
    left = list(ours)
    while True:
        have = set(debian_any)
        for _, c in left:
            have |= names(c)
        keep = [(d, c) for d, c in left
                if all(any(x in have for x in alts) for alts in debfetch.clauses(c))]
        if len(keep) == len(left):
            return keep
        left = keep


def twins(cache, ours):
    """Debian's arm64 build of every Multi-Arch: same library of ours, at
    our version, for the image's repository. apt installs a Multi-Arch:
    same package for two architectures only at one version, so an arm64
    program apt installs that needs one of our libraries needs Debian's
    arm64 build of exactly our version beside ours. Debian's archive drops
    a version once a point or security update replaces it, so the repository
    carries the twin itself: found in trixie's and trixie-security's
    indexes (and those of a cuts.txt `suite`), in the cache's pool, where the build fetched it
    verified, or on snapshot.debian.org. A library Debian builds for arm64 whose twin is in neither
    stops the build: an image with it would refuse arm64 installs."""
    suites = {SUITE, f'{SUITE}-security'}
    later = {}  # a cuts.txt `suite`: SOURCE -> the later suite ours is from
    for line in open(os.path.join(HERE, 'cross', 'cuts.txt')):
        f = line.split('|')[0].split()
        if len(f) == 3 and f[1] == 'suite':
            suites.add(f[2])
            later[f[0]] = f[2]
    indexes = [debfetch.packages(cache, suite, NATIVE)[0] for suite in sorted(suites)]
    out, missing = [], []
    # A source of ours from a later suite (systemd 262): trixie's arm64
    # builds of its other binaries are of trixie's version, and want
    # exactly that version of ours (systemd-container on systemd (= 257)).
    # The repository carries the later suite's arm64 build of each of them
    # that we do not build, at our version.
    names = {c['Package'] for _, c in ours}
    for src, suite in sorted(later.items()):
        ver = next((c['Version'] for _, c in ours if c.get('Source', c['Package']).split(' ')[0] == src), None)
        if not ver:
            continue
        pkgs = debfetch.packages(cache, suite, NATIVE)[0]
        for p in pkgs.values():
            if (p.get('Source', p['Package']).split(' ')[0] != src or p['Architecture'] != NATIVE
                    or p['Package'] in names):
                continue
            # the suite moves on: an older version is on snapshot.debian.org
            deb = debfetch.fetch(cache, p) if p['Version'] == ver else debfetch.fetch_snapshot(cache, p['Package'], ver, NATIVE)
            if deb:
                out.append((deb, dict(control(deb), _copy=True)))
                names.add(p['Package'])
    for _, c in ours:
        if c['Architecture'] != OURS_ARCH or c.get('Multi-Arch') != 'same':
            continue
        name, ver = c['Package'], c['Version']
        found = [p for p in (i.get(name) for i in indexes) if p and p['Architecture'] == NATIVE]
        if not found:
            continue  # no arm64 build in Debian: nothing installs beside it
        p = next((p for p in found if p['Version'] == ver), None)
        if p:
            deb = debfetch.fetch(cache, p)
        else:
            deb = os.path.join(cache, 'pool', f'{name}_{ver.split(":")[-1]}_{NATIVE}.deb')
            if not os.path.exists(deb):
                deb = debfetch.fetch_snapshot(cache, name, ver, NATIVE)
            if not deb:
                missing.append(f'{name} {ver} (Debian has {found[0]["Version"]})')
                continue
        out.append((deb, dict(control(deb), _copy=True)))
    if missing:
        sys.exit('no Debian arm64 build at our version of these Multi-Arch: same libraries '
                 '(arm64 programs needing them would not install):\n  ' + '\n  '.join(missing))
    return out


def sysusers(root):
    """The system users and groups packages declare in sysusers.d (their
    postinsts make them with systemd-sysusers or adduser): u, g and m lines,
    a free id from 999 down where none is given, as systemd-sysusers does."""
    pw_path, gr_path = os.path.join(root, 'etc/passwd'), os.path.join(root, 'etc/group')
    pw = [l.rstrip('\n').split(':') for l in open(pw_path) if l.strip()]
    gr = [l.rstrip('\n').split(':') for l in open(gr_path) if l.strip()]
    used_u = {int(p[2]) for p in pw}
    used_g = {int(g[2]) for g in gr}

    def free(used):
        i = 999
        while i in used:
            i -= 1
        return i

    def group(name, gid=None):
        for g in gr:
            if g[0] == name:
                return int(g[2])
        if gid is None or gid in used_g:
            gid = free(used_g | used_u)
        used_g.add(gid)
        gr.append([name, 'x', str(gid), ''])
        return gid

    lines = []
    for f in sorted(glob.glob(os.path.join(root, 'usr/lib/sysusers.d/*.conf'))):
        lines += [shlex.split(l) for l in open(f) if l.strip() and not l.lstrip().startswith('#')]
    # groups first, so a user's own group takes the gid a g line names
    for t in lines:
        if t[0] == 'g' and len(t) >= 2:
            group(t[1], int(t[2]) if len(t) > 2 and t[2].isdigit() else None)
    for t in lines:
        if t[0] != 'u' or len(t) < 2 or any(p[0] == t[1] for p in pw):
            continue
        idf = t[2] if len(t) > 2 else '-'
        uid, _, gname = idf.partition(':')
        uid = int(uid) if uid.isdigit() and int(uid) not in used_u else None
        if uid is None:
            uid = free(used_u | used_g)
        gid = int(gname) if gname.isdigit() else group(gname or t[1], uid)
        used_u.add(uid)
        gecos = t[3] if len(t) > 3 and t[3] != '-' else ''
        home = t[4] if len(t) > 4 and t[4] != '-' else '/nonexistent'
        shell = t[5] if len(t) > 5 and t[5] != '-' else '/usr/sbin/nologin'
        pw.append([t[1], 'x', str(uid), str(gid), gecos, home, shell])
    for t in lines:
        if t[0] == 'm' and len(t) >= 3:
            group(t[2])
            for g in gr:
                if g[0] == t[2] and t[1] not in g[3].split(','):
                    g[3] = ','.join(filter(None, g[3].split(',') + [t[1]]))
    open(pw_path, 'w').write(''.join(':'.join(p) + '\n' for p in pw))
    open(gr_path, 'w').write(''.join(':'.join(g) + '\n' for g in gr))


def configure(root, ours, native_pkgs, debian=None):
    """What maintainer scripts and debootstrap would have done."""
    def w(rel, text, mode=0o644):
        p = os.path.join(root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, 'w').write(text)
        os.chmod(p, mode)

    # base-passwd
    pw = os.path.join(root, 'usr/share/base-passwd')
    shutil.copy(os.path.join(pw, 'passwd.master'), os.path.join(root, 'etc/passwd'))
    shutil.copy(os.path.join(pw, 'group.master'), os.path.join(root, 'etc/group'))
    sysusers(root)
    users = [l.split(':')[0] for l in open(os.path.join(root, 'etc/passwd'))]
    groups = [l.split(':')[0] for l in open(os.path.join(root, 'etc/group'))]
    w('etc/shadow', ''.join(f'{u}:*:20000:0:99999:7:::\n' for u in users), 0o640)
    w('etc/gshadow', ''.join(f'{g}:*::\n' for g in groups), 0o640)
    # /etc/shells: debianutils' list plus every shells.d file (add-shell)
    shells = open(os.path.join(root, 'usr/share/debianutils/shells')).read() \
        if os.path.exists(os.path.join(root, 'usr/share/debianutils/shells')) else '# /etc/shells: valid login shells\n/bin/sh\n'
    for f in sorted(glob.glob(os.path.join(root, 'usr/share/debianutils/shells.d/*'))):
        shells += open(f).read()
    seen = []
    for l in shells.splitlines():
        if l not in seen:
            seen.append(l)
    w('etc/shells', '\n'.join(seen) + '\n')
    # getent, where glibc's (libc-bin) is not in the tree: maintainer
    # scripts ask it whether a user or group exists before making one
    # (passwd's postinst fails without it), and it reads the files
    if not os.path.lexists(os.path.join(root, 'usr/bin/getent')):
        w('usr/bin/getent', open(os.path.join(HERE, 'getent.sh')).read(), 0o755)
    # base-files' postinst: /root's dot files, /etc/os-release is shipped
    for n in ('profile', 'bashrc'):
        src = os.path.join(root, f'usr/share/base-files/dot.{n}')
        if os.path.exists(src):
            os.makedirs(os.path.join(root, 'root'), exist_ok=True)
            shutil.copy(src, os.path.join(root, f'root/.{n}'))
    os.chmod(os.path.join(root, 'root'), 0o700)
    # and its install_from_default: /etc/profile (PS1, PATH), /etc/motd
    for n in ('profile', 'motd'):
        src = os.path.join(root, f'usr/share/base-files/{n}')
        if os.path.exists(src) and not os.path.lexists(os.path.join(root, f'etc/{n}')):
            shutil.copy(src, os.path.join(root, f'etc/{n}'))
    for d in ('tmp', 'var/tmp'):
        os.makedirs(os.path.join(root, d), exist_ok=True)
        os.chmod(os.path.join(root, d), 0o1777)
    # ca-certificates: the configuration and the bundle update-ca-certificates writes
    crts = sorted(glob.glob(os.path.join(root, 'usr/share/ca-certificates/mozilla/*.crt')))
    w('etc/ca-certificates.conf', ''.join(f'mozilla/{os.path.basename(c)}\n' for c in crts))
    os.makedirs(os.path.join(root, 'etc/ssl/certs'), exist_ok=True)
    w('etc/ssl/certs/ca-certificates.crt', ''.join(open(c).read().rstrip('\n') + '\n' for c in crts))
    # alternatives the postinsts register (the highest priority of what is here)
    alts = {
        'awk': [('/usr/bin/mawk', 5), ('/usr/bin/gawk', 10)],
        'editor': [('/usr/bin/nano', 40), ('/usr/bin/vim.basic', 30)],
        'vi': [('/usr/bin/vim.basic', 30)], 'vim': [('/usr/bin/vim.basic', 30)],
        'view': [('/usr/bin/vim.basic', 30)], 'ex': [('/usr/bin/vim.basic', 30)],
        'pager': [('/usr/bin/less', 77), ('/usr/bin/more', 50)],
    }
    links = {'awk': '/usr/bin/awk', 'editor': '/usr/bin/editor', 'vi': '/usr/bin/vi', 'vim': '/usr/bin/vim',
             'view': '/usr/bin/view', 'ex': '/usr/bin/ex', 'pager': '/usr/bin/pager'}
    os.makedirs(os.path.join(root, 'etc/alternatives'), exist_ok=True)
    os.makedirs(os.path.join(root, 'var/lib/dpkg/alternatives'), exist_ok=True)
    for name, choices in alts.items():
        have = [(p, pr) for p, pr in choices if os.path.lexists(os.path.join(root, p.lstrip('/')))]
        if not have:
            continue
        best = max(have, key=lambda c: c[1])[0]
        alt = os.path.join(root, 'etc/alternatives', name)
        link = os.path.join(root, links[name].lstrip('/'))
        for p in (alt, link):
            if os.path.lexists(p):
                os.unlink(p)
        os.symlink(best, alt)
        os.symlink(f'/etc/alternatives/{name}', link)
        state = ['auto', links[name], '']
        for p, pr in have:
            state += [p, str(pr)]
        w(f'var/lib/dpkg/alternatives/{name}', '\n'.join(state) + '\n\n')
    # the system's identity and name service
    w('etc/hostname', 'gex\n')
    w('etc/hosts', '127.0.0.1\tlocalhost\n127.0.1.1\tgex\n::1\t\tlocalhost ip6-localhost ip6-loopback\n')
    w('etc/resolv.conf', 'nameserver 1.1.1.1\n')
    w('etc/fstab', '# gex: no block devices\n')
    if not os.path.exists(os.path.join(root, 'etc/nsswitch.conf')):
        w('etc/nsswitch.conf', 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\n'
          'networks: files\nprotocols: files\nservices: files\nethers: files\nrpc: files\n')
    # apt and dpkg's own architecture first: Debian's (ours labelled
    # arm64 where they stand in), or ours (--native-ours: dpkg itself is
    # musl-linux-wasm32's, and an Architecture: all package is ours' then;
    # Debian's arm64 is the foreign one, which apt still installs a name
    # from when ours has none)
    first, second = (OURS_ARCH, NATIVE) if a_native_ours else (NATIVE, OURS_ARCH)
    # apt: Debian for arm64, ours for musl-linux-wasm32, the pins
    w('etc/apt/sources.list.d/debian.sources',
      f'Types: deb\nURIs: {MIRROR_URI}\nSuites: {SUITE} {SUITE}-updates\nComponents: main\n'
      f'Architectures: {NATIVE}\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\n'
      f'Types: deb\nURIs: {SECURITY_URI}\nSuites: {SUITE}-security\nComponents: main\n'
      f'Architectures: {NATIVE}\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n')
    w('etc/apt/sources.list.d/gex.sources',
      f'Types: deb\nURIs: {a_repo_uri}\nSuites: {SUITE}\nComponents: main\n'
      f'Architectures: {OURS_ARCH} {NATIVE}\nTrusted: yes\n')
    # (dpkg and apt of ours are labelled arm64: o=gex's 1001 keeps them)
    names = {c['Package'] for _, c in ours if c['Architecture'] == OURS_ARCH}
    # and what they stand in for (python3.13 provides python3 and
    # python3-minimal): Debian's packages of those names would overwrite
    # ours' files, so a request for one gets ours
    for _, c in ours:
        if c['Architecture'] == OURS_ARCH:
            for item in c.get('Provides', '').split(','):
                if item.strip():
                    names.add(item.strip().split(' ')[0])
    # and Debian's packages that Provide one of our package names (vim-nox,
    # vim-gtk3 and vim-motif provide vim): Multi-Arch: foreign makes ours a
    # provider of vim:arm64 too, and with more than one provider holding a
    # candidate `apt-get install vim` gives up ("no installation candidate")
    ours_pkgs = {c['Package'] for _, c in ours if c['Architecture'] == OURS_ARCH}
    for n, p in (debian or {}).items():
        if n in ours_pkgs:
            continue
        for item in p.get('Provides', '').split(','):
            if item.strip() and item.strip().split(' ')[0] in ours_pkgs:
                names.add(n)
    # A library (Multi-Arch: same) is not one of them: Debian's arm64 build
    # of it is installed beside ours for an arm64 program, at our version
    libs = set()
    for _, c in ours:
        if c['Architecture'] == OURS_ARCH and c.get('Multi-Arch') == 'same':
            libs.add(c['Package'])
            libs.update(item.strip().split(' ')[0] for item in c.get('Provides', '').split(',') if item.strip())
    # nor a name whose Debian package is a Multi-Arch: same library (gex-gl
    # provides libegl1 for ours; Debian's arm64 libegl1 goes beside it)
    libs |= {n for n in names if (debian or {}).get(n, {}).get('Multi-Arch') == 'same'}
    names = sorted(names - libs)
    w('etc/apt/preferences.d/gex-twins',
      '# Debian\'s arm64 build of a library of ours at our version: the two\n'
      '# builds of a Multi-Arch: same library must have one version\n' +
      ''.join(f'\nPackage: {c["Package"]}:{NATIVE}\nPin: version {c["Version"]}\nPin-Priority: 1001\n'
              for _, c in ours if c['Architecture'] == OURS_ARCH and c.get('Multi-Arch') == 'same'))
    # dpkg: a file in two packages is the later one's (Debian's arm64 build
    # of a tool beside ours, two providers of one path): an install never
    # stops on it
    w('etc/dpkg/dpkg.cfg.d/gex-overwrite', '# an install never stops on a file another package has\nforce-overwrite\n')
    # Debian's architecture-independent packages are any architecture's
    # here, and what they need is Debian's arm64 build where ours have none
    # (all-foreign.sh says how), in apt's indexes after each update and in
    # dpkg's database after each run, and in the image's database now;
    # between dpkg's unpack and the hook, dpkg configures what it would
    # otherwise stop on (the .deb's own control does not say it)
    hook = 'usr/lib/gex/all-foreign'
    w(hook, open(os.path.join(HERE, 'all-foreign.sh')).read(), 0o755)
    w('etc/apt/apt.conf.d/50gex-all-foreign',
      '// Debian\'s Architecture: all packages are any architecture\'s here (mkrootfs.py)\n'
      f'APT::Update::Post-Invoke-Success {{ "/{hook}"; }};\n'
      f'DPkg::Post-Invoke {{ "/{hook} --status"; }};\n')
    w('etc/dpkg/dpkg.cfg.d/gex-all-foreign',
      '# an arm64 package\'s dependency on Debian\'s architecture-independent data\n'
      '# is met by it here (usr/lib/gex/all-foreign)\nforce-depends\n')
    subprocess.run(['sh', os.path.join(root, hook), root], check=True)
    w('etc/apt/preferences.d/gex-native',
      '# Our native tools (musl-linux-wasm32) are never replaced by Debian\'s\n'
      '# arm64 builds; libraries are not pinned (docs/gexcc.md §6.1a).\n'
      f'Package: {" ".join(n + ":" + NATIVE for n in names)}\nPin: release *\nPin-Priority: -1\n\n'
      'Package: *\nPin: release o=gex\nPin-Priority: 1001\n')
    w('etc/apt/apt.conf.d/99gex',
      '// gex: one user, no sandbox user to drop to\n'
      'APT::Sandbox::User "root";\n'
      '// no translations: apt-get update fetches the Packages indexes only\n'
      'Acquire::Languages "none";\n'
      '// the trixie arm64 index and ours, in one mapping (fork copies it: no\n'
      '// copy-on-write in the guest, so no bigger than needed)\n'
      'APT::Cache-Start "100663296";\n'
      '// no source package cache: the image builds no sources, and it was a\n'
      '// second 46 MB copy of the package cache in the guest\'s memory\n'
      'Dir::Cache::srcpkgcache "";\n'
      'Dpkg::Use-Pty "false";\n'
      'APT::Install-Recommends "false";\n'
      '// said here so apt does not fork dpkg to ask (two dpkg runs, 3 s of\n'
      '// every apt-cache in the page)\n'
      f'APT::Architecture "{first}";\n'
      f'APT::Architectures {{ "{first}"; "{second}"; }};\n'
      '// debconf\'s dpkg-preconfigure (perl, about 19 s per apt install in the\n'
      '// page) only asks questions early; postinst asks them anyway, and the\n'
      '// demo is noninteractive\n'
      '#clear DPkg::Pre-Install-Pkgs;\n')
    for d in ('var/lib/apt/lists/partial', 'var/cache/apt/archives/partial', 'var/lib/dpkg/updates',
              'var/lib/dpkg/triggers', 'var/log/apt', 'etc/apt/trusted.gpg.d', 'etc/apt/keyrings',
              'etc/dpkg/dpkg.cfg.d', 'var/cache/debconf', 'var/lib/apt/periodic', 'proc', 'dev', 'run', 'sys',
              'home', 'mnt', 'srv', 'opt', 'media', 'usr/local/bin'):
        os.makedirs(os.path.join(root, d), exist_ok=True)
    if a_minimal:
        w('etc/dpkg/dpkg.cfg.d/excludes', '# no documentation or translations (mkrootfs.py)\n'
          + ''.join(f'path-exclude={g}\n' for g in EXCLUDE) + ''.join(f'path-include={g}\n' for g in INCLUDE))
    w('var/lib/dpkg/arch', f'{first}\n{second}\n')
    for f in ('diversions', 'statoverride', 'available'):
        w(f'var/lib/dpkg/{f}', '')
    w('var/lib/dpkg/triggers/File', '')
    w('var/lib/dpkg/triggers/Unincorp', '')


def leb(w, p):
    r = sh = 0
    while True:
        x = w[p]; p += 1
        r |= (x & 0x7f) << sh; sh += 7
        if not x & 0x80:
            return r, p


def wasm_needed(w):
    """The libraries a wasm module (a gexcc side module, or the module in a
    gexcc program's ELF container) loads: dylink.0's NEEDED, or None for
    any other file."""
    if w[:4] == b'\x7fELF':
        i = w.find(b'\0asm\x01\0\0\0', 0, 4096)
        if i < 0:
            return None
        w = w[i:]
    if w[:4] != b'\0asm':
        return None
    p = 8
    while p + 1 < len(w):
        sid = w[p]; n, q = leb(w, p + 1)
        if sid != 0:
            return None  # dylink.0 is the first section
        ln, r = leb(w, q)
        if w[r:r + ln] != b'dylink.0':
            return None
        r += ln; end = q + n; needed = []
        while r < end:
            kind = w[r]; sl, r = leb(w, r + 1)
            if kind == 2:
                cnt, t = leb(w, r)
                for _ in range(cnt):
                    m, t = leb(w, t); needed.append(w[t:t + m].decode('utf-8', 'replace')); t += m
            r += sl
        return needed
    return None


def needs_of_ours(ours, cache_file):
    """Package dependencies of our packages from the libraries their
    programs and libraries load, by the shlibs files of ours: gexcc's
    modules are not ELF, so dh_shlibdeps wrote none into Depends. Cached by
    .deb (path, size, mtime) in CACHE_FILE."""
    import json
    try:
        cache = json.load(open(cache_file))
    except (OSError, ValueError):
        cache = {}
    soname_pkg = {}
    out, fresh = {}, {}
    for deb, c in ours:
        if c.get('Architecture') != OURS_ARCH:
            continue
        st = os.stat(deb)
        key = f'{os.path.realpath(deb)}:{st.st_size}:{int(st.st_mtime)}'
        ent = cache.get(key)
        if ent is None:
            shl = control_member(deb, 'shlibs') or ''
            sonames = []
            for line in shl.splitlines():
                f = line.split()
                if len(f) >= 3 and not line.startswith('#'):
                    sonames.append((f'{f[0]}.so.{f[1]}', f[2]))
            needed = set()
            data = subprocess.run(['dpkg-deb', '--fsys-tarfile', deb], capture_output=True, check=True).stdout
            with tarfile.open(fileobj=io.BytesIO(data)) as tf:
                for m in tf:
                    # (and a library's file name: a package built before
                    # its shlibs file was written has none)
                    base = m.name.rsplit('/', 1)[-1]
                    if '/wasm32-linux-musl/' in m.name and re.fullmatch(r'lib.+\.so\.\d+', base):
                        sonames.append((base, c['Package']))
                    if not m.isfile() or m.size < 8:
                        continue
                    fh = tf.extractfile(m)
                    head = fh.read(8)
                    if head[:4] not in (b'\0asm', b'\x7fELF'):
                        continue
                    n = wasm_needed(head + fh.read())
                    if n:
                        needed.update(n)
            ent = {'sonames': sonames, 'needed': sorted(needed)}
        fresh[key] = ent
        for so, pkg in ent['sonames']:
            soname_pkg.setdefault(so, pkg)
        out[c['Package']] = ent['needed']
    try:
        with open(cache_file + '.new', 'w') as f:
            json.dump(fresh, f)
        os.replace(cache_file + '.new', cache_file)
    except OSError:
        pass
    deps = {}
    for name, needed in out.items():
        deps[name] = sorted({soname_pkg[n] for n in needed if n in soname_pkg and soname_pkg[n] != name})
    return deps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pool', default=os.path.expanduser('~/gex-sandbox/scratch/CC/debian/pool'))
    ap.add_argument('--cache', default=os.path.expanduser('~/gex-sandbox/scratch/CC/deb'))
    ap.add_argument('--out', required=True)
    ap.add_argument('--tar', help='also write the tree as a tar (owner root)')
    ap.add_argument('--roots', default=','.join(ROOTS))
    ap.add_argument('--extra', default='', help='more arm64 packages (and their closure)')
    ap.add_argument('--exclude', default='', help='our packages to leave out of the image (still in the repo)')
    ap.add_argument('--leave-out', default='',
                    help='packages in neither form in the image, what needs them met as if they were '
                         '(dropped from the dependents\' Depends in the status file)')
    ap.add_argument('--ours', default='', help='only these of our packages in the image (still all in the repo)')
    ap.add_argument('--ours-closure', action='store_true',
                    help='only the closure of the roots among our packages in the image (still all in the repo)')
    ap.add_argument('--ours-for', default='',
                    help='these of our packages stand in for Debian\'s of the same name (a wasm32 program in an arm64 image); '
                         '"*": every one of ours (the image is ours wherever our pools have the package)')
    ap.add_argument('--list-native', action='store_true',
                    help="print the Debian packages of the tree's architecture the image would take, and stop")
    ap.add_argument('--full', action='store_true', help='keep documentation and translations')
    ap.add_argument('--path-exclude', default='',
                    help="more of what the image leaves out of its packages, in dpkg's form (path-exclude=GLOB, "
                         "path-include=GLOB lines): applied as the documentation is, and written to the image's "
                         "dpkg configuration so apt installs leave it out too")
    ap.add_argument('--repo-url', default='',
                    help="our repository is served there (a page-served host's http:// URL): every one of ours "
                         "offered, the repository written to --repo-out, not into the image")
    ap.add_argument('--repo-out', default='', help='with --repo-url: where the repository is written')
    ap.add_argument('--repo-debs', action='store_true',
                    help="offer apt every one of ours, their .debs copied into the image's repository (otherwise only the image's own)")
    ap.add_argument('--apt-notes', default='',
                    help="what apt says of a package an install brings in (apt hooks, apt-note.sh)")
    ap.add_argument('--native-ours', action='store_true',
                    help="dpkg's and apt's own architecture is ours (musl-linux-wasm32), Debian's the foreign one")
    ap.add_argument('--arch', default='arm64',
                    help="Debian's architecture for the tree (amd64: the cross build's chroot)")
    a = ap.parse_args()
    global a_minimal, a_native_ours, NATIVE, a_repo_uri
    a_minimal = not a.full
    if a.path_exclude:
        for line in open(a.path_exclude):
            k, _, g = line.strip().partition('=')
            if k == 'path-exclude':
                EXCLUDE.append(g)
            elif k == 'path-include':
                INCLUDE.append(g)
    a_native_ours = a.native_ours
    if a.repo_url:
        if not a.repo_out:
            sys.exit('--repo-url needs --repo-out')
        a_repo_uri = a.repo_url
        a.repo_debs = True
    NATIVE = a.arch

    ours = []
    for deb in sorted(glob.glob(os.path.join(a.pool, f'*_{OURS_ARCH}.deb'))
                      + glob.glob(os.path.join(a.pool, f'*_{NATIVE}.deb'))):
        ours.append((deb, control(deb)))
    excluded = set(filter(None, a.exclude.split(',')))
    image_ours = [(d, c) for d, c in ours if c['Package'] not in excluded]
    if a.ours:
        only = set(a.ours.split(','))
        image_ours = [(d, c) for d, c in image_ours if c['Package'] in only]
    # Ours stand in for Debian's by name when they are the native
    # architecture's or Multi-Arch: foreign (tools); a library of ours
    # (musl-linux-wasm32) is only for our binaries, and an arm64 binary that
    # needs it still gets Debian's.
    def provided(c):
        return [item.strip().split(' ')[0] for item in c.get('Provides', '').split(',') if item.strip()]

    ours_for = set(filter(None, a.ours_for.split(',')))
    leave_out = set(filter(None, a.leave_out.split(',')))

    def stands_in(c):
        return (c.get('Architecture') == NATIVE or c.get('Multi-Arch') in ('foreign', 'allowed')
                or c['Package'] in ours_for or '*' in ours_for)

    our_names = set()
    # "*": a library of ours (Multi-Arch: same) meets what our packages and
    # Debian's architecture-independent ones need of it, and leaves Debian's
    # own in the image for a Debian binary still there that needs it (an
    # arm64 bash, libtinfo6)
    our_libs = set()
    for _, c in ours:
        if stands_in(c):
            our_names.add(c['Package'])
            our_names.update(provided(c))
            if '*' in ours_for and c.get('Multi-Arch') == 'same' and c['Package'] not in ours_for:
                our_libs.add(c['Package'])
                our_libs.update(provided(c))
    pkgs, provides = debfetch.packages(a.cache, SUITE, NATIVE)
    for _, c in ours:
        if c['Architecture'] == OURS_ARCH and c.get('Multi-Arch') != 'same':
            ANY_ARCH_NAMES.add(c['Package'])
            ANY_ARCH_NAMES.update(provided(c))

    def shared_for_ours(n):
        """a Debian package one of ours may depend on: not tied to Debian's architecture"""
        n = n if n in pkgs else provides.get(n)
        return n and (pkgs[n].get('Architecture') == 'all' or pkgs[n].get('Multi-Arch') == 'foreign')

    user_roots = [r for r in a.roots.split(',') + a.extra.split(',') if r]
    by_name = {c['Package']: c for _, c in image_ours}
    prov = {}
    for c in by_name.values():
        for n in provided(c):
            prov.setdefault(n, c['Package'])
    # for the closure, with the libraries ours load (not in their Depends)
    by_needs = by_name
    if a.ours_closure:
        needs = needs_of_ours(image_ours, os.path.join(a.cache, 'ours-needed-2.json'))
        by_needs = {n: dict(c, Depends=', '.join(filter(None, [c.get('Depends', '')] + needs.get(n, []))))
                    for n, c in by_name.items()}
    our_roots = list(user_roots)
    candidates = image_ours
    while True:
        if a.ours_closure:
            # the roots and what they need, wherever ours have it, and those of
            # ours that Debian's packages in the image need
            want = set(debfetch.closure(by_needs, prov, our_roots, exclude=leave_out))
            image_ours = [(d, c) for d, c in candidates if c['Package'] in want and c['Package'] not in leave_out]
        # (a package of ours left out of the image does not satisfy anything)
        have_ours = set()
        for _, c in image_ours:
            have_ours.add(c['Package'])
            have_ours.update(provided(c))
        roots = list(user_roots)
        # what ours depend on from Debian (architecture-independent data and
        # tools); a library ours lack is a gap in our build, not Debian's to fill
        gaps = []
        for _, c in image_ours:
            for alts in debfetch.clauses(c):
                if any(x in have_ours or x in leave_out for x in alts):
                    continue
                pick = next((x for x in alts if shared_for_ours(x)), None)
                if pick:
                    roots.append(pick)
                else:
                    gaps.append(f'{c["Package"]} needs {" | ".join(alts)}')
        order = debfetch.closure(pkgs, provides, roots, exclude=(our_names - our_libs) | leave_out, shared=our_libs, arch=NATIVE)
        # A name ours stand in for is never Debian's in the image (but for a
        # library of ours a Debian binary needs Debian's copy of).
        order = [n for n in order if n not in our_names or n in our_libs]
        unmet, pull = [], []
        have = set(order) | (have_ours & our_names) | leave_out
        for n in order:
            have.update(provided(pkgs[n]))
        for p in [pkgs[n] for n in order]:
            for alts in debfetch.clauses(p):
                if any(x in have for x in alts):
                    continue
                ours_alt = next((x for x in alts if x in our_names and (x in by_name or x in prov)), None)
                if a.ours_closure and ours_alt:
                    pull.append(ours_alt)
                else:
                    unmet.append(f'{p["Package"]} needs {" | ".join(alts)}')
        pull = [x for x in pull if x not in our_roots]
        if not pull:
            break
        our_roots += pull
    if unmet and not a.ours_closure:
        sys.exit('the closure is not self-consistent:\n  ' + '\n  '.join(unmet))
    # (with --ours-closure, an arm64 package can need what neither has: an
    # arm64 XS module, which our perl cannot load; apt sees it as broken)
    if unmet:
        print(f'{len(unmet)} dependencies nothing in the image meets:\n  ' + '\n  '.join(unmet), file=sys.stderr)
    if gaps:
        print(f'{len(set(gaps))} dependencies of ours that only Debian\'s {NATIVE} libraries meet (left out):\n  '
              + '\n  '.join(sorted(set(gaps))), file=sys.stderr)
    if a.list_native:
        for n in order:
            if pkgs[n].get('Architecture') == NATIVE:
                print(f'{n} {pkgs[n].get("Source", n).split(" ")[0]}')
        return
    native = [(debfetch.fetch(a.cache, pkgs[n]), pkgs[n]) for n in order]
    print(f'{len(native)} Debian packages, {len(image_ours)} of ours', file=sys.stderr)

    root = a.out
    if os.path.exists(root):
        subprocess.run(['chmod', '-R', 'u+rwX', root], check=False)
        shutil.rmtree(root)
    os.makedirs(os.path.join(root, 'usr'))
    for d in ('bin', 'sbin', 'lib'):
        os.makedirs(os.path.join(root, 'usr', d), exist_ok=True)
        os.symlink(f'usr/{d}', os.path.join(root, d))
    info = os.path.join(root, 'var/lib/dpkg/info')
    os.makedirs(info)
    # the multiarch database layout (`pkg:arch.*` for Multi-Arch: same)
    open(os.path.join(info, 'format'), 'w').write('1\n')
    status = []
    alts = {}
    for deb, idx in native + image_ours:
        ctl = control(deb)
        paths = unpack(deb, root)
        alternatives(control_member(deb, 'postinst'), alts)
        stem = info_name(ctl)
        open(os.path.join(info, f'{stem}.list'), 'w').write('\n'.join(paths) + '\n')
        sums = control_member(deb, 'md5sums') or data_md5sums(deb)
        if sums:
            open(os.path.join(info, f'{stem}.md5sums'), 'w').write(sums)
        conf = control_member(deb, 'conffiles')
        cmd5 = []
        if conf:
            open(os.path.join(info, f'{stem}.conffiles'), 'w').write(conf)
            for p in conf.split():
                f = os.path.join(root, real_rel(root, p.lstrip('/')))
                if os.path.isfile(f):
                    cmd5.append((p, md5(f)))
        # ours are held: apt never removes or replaces one to meet what an
        # install asks for (it says it cannot, and the desktop stays whole)
        status.append(status_stanza(without(ctl, leave_out), cmd5, hold=(deb, idx) in image_ours))
    open(os.path.join(root, 'var/lib/dpkg/status'), 'w').write('\n'.join(status))
    link_alternatives(root, alts)
    # apt is offered only those of ours it can install: one needing a
    # package of ours that is not built (python3 without python3.13) is
    # left out, and Debian's build of it is what apt installs
    # and of ours only the image's, whose .debs need no copy (apt reinstalls
    # one from the index, and installs no other of ours: the repository has
    # no .debs, so Debian's arm64 build is what it fetches), unless
    # --repo-debs copies every one of ours into the repository
    in_image = {d for d, _ in image_ours}
    offered = installable_ours(ours if a.repo_debs else [(d, c) for d, c in ours if d in in_image], pkgs, provides)
    if a.repo_debs:
        offered = [(d, dict(c, _copy=True)) for d, c in offered]
    print(f'{len(ours) - len(offered)} of ours not offered to apt (a dependency neither ours nor Debian\'s meets)',
          file=sys.stderr)
    configure(root, offered, native, pkgs)
    if a.apt_notes:
        apt_notes(root, a.apt_notes)
    if a.repo_out and os.path.exists(a.repo_out):
        shutil.rmtree(a.repo_out)
    write_repo(root, offered + twins(a.cache, offered), repo=a.repo_out or None)

    size = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(root) for f in fs
               if not os.path.islink(os.path.join(d, f)))
    print(f'{root}: {size / (1 << 20):.1f} MiB', file=sys.stderr)
    if a.tar:
        subprocess.run(['tar', '-C', root, '--owner=0', '--group=0', '--numeric-owner', '--sort=name',
                        '-cf', a.tar, '.'], check=True)
        print(f'{a.tar}: {os.path.getsize(a.tar) / (1 << 20):.1f} MiB', file=sys.stderr)


if __name__ == '__main__':
    main()
