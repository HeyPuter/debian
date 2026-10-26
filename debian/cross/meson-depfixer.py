"""meson's depfixer (the install step's run path rewrite), for gexcc modules.

    python3 -I meson-depfixer.py DEPFIXER OUT

meson installs a program or a shared library with its install_rpath in
place of the build tree's directories, by rewriting the ELF dynamic
section's DT_RUNPATH. A gexcc module's run path is in its dylink.0 section
(a side module, or a program's module in its ELF container), which meson's
ELF reader does not see: it would install the build tree's run path
($ORIGIN/src/shared), which names no directory there. OUT is DEPFIXER with
the same rewrite for those, through gexcc-rpath, and the same rules as
meson's for ELF (install_rpath first, then the old directories that are
neither build directories nor meson's XXX padding).
"""
import sys

src, out = sys.argv[1:3]
s = open(src).read()
old = '''        if isinstance(new_rpath, str):
            new_rpath = new_rpath.encode('utf8')
        fix_elf(fname, rpath_dirs_to_remove, new_rpath, verbose)'''
new = '''        if isinstance(new_rpath, str):
            new_rpath = new_rpath.encode('utf8')
        if gexcc_fix_rpath(fname, rpath_dirs_to_remove, new_rpath):
            return
        fix_elf(fname, rpath_dirs_to_remove, new_rpath, verbose)'''
assert s.count(old) == 1, 'depfixer.fix_rpath changed'
s = s.replace(old, new, 1)
s += '''

def gexcc_fix_rpath(fname: str, rpath_dirs_to_remove: T.Set[bytes], new_rpath: bytes) -> bool:
    """A gexcc module's run path, rewritten as fix_rpathtype_entry does an
    ELF's; False for any other file."""
    import subprocess
    try:
        with open(fname, 'rb') as f:
            head = f.read(4096)
    except OSError:
        return False
    if not (head[:4] == b'\\0asm' or (head[:4] == b'\\x7fELF' and b'\\0asm\\x01\\0\\0\\0' in head)):
        return False
    r = subprocess.run(['gexcc-rpath', fname], stdout=subprocess.PIPE)
    if r.returncode == 2:
        return False
    if r.returncode:
        sys.exit(f'gexcc-rpath failed on {fname!r}')
    old_rpath = r.stdout.strip()
    dirs: T.List[bytes] = []
    for d in (new_rpath.split(b':') if new_rpath else []) + [
            d for d in old_rpath.split(b':')
            if not (d in rpath_dirs_to_remove or d == b'X' * len(d))]:
        if d and d not in dirs:
            dirs.append(d)
    subprocess.run(['gexcc-rpath', '--set', b':'.join(dirs).decode(), fname], check=True)
    return True
'''
open(out, 'w').write(s)
