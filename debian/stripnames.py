#!/usr/bin/env python3
"""Drop the `name` section (function names, for backtraces) from every wasm
module in a tree, and keep dpkg's md5sums of the files in step.

    stripnames.py TREE

A library or plugin is a wasm module as it is: the section is cut out. A
program is its module inside gexcc's ELF executable, whose segments are
placed by file offset: there the section is kept at its size, renamed and
zeroed, which costs nothing compressed. Every other section stays
(gex.forkreach, dylink.0, target_features are read at run time).

Only a module that names shared libraries it needs (dylink.0's
WASM_DYLINK_NEEDED) loses it: gex finds the entries of a program that
needs none in its table by their names.
"""
import hashlib, os, sys


def leb(b, i):
    r = s = 0
    while True:
        x = b[i]
        i += 1
        r |= (x & 0x7f) << s
        s += 7
        if x < 0x80:
            return r, i


def sections(b, at):
    """(start, end, id, name) of each section of the module at AT, up to the
    first byte that is no section (the end of an ELF's wasm)."""
    i, out = at + 8, []
    while i < len(b):
        sid = b[i]
        if sid > 13:
            break
        n, j = leb(b, i + 1)
        if j + n > len(b):
            break
        name = None
        if sid == 0:
            ln, k = leb(b, j)
            name = b[k:k + ln]
        out.append((i, j + n, sid, name, j))
        i = j + n
    return out


def needs_libs(b, secs):
    """Whether the module's dylink.0 names a library it needs."""
    for _, e, sid, name, j in secs:
        if sid != 0 or name != b'dylink.0':
            continue
        ln, i = leb(b, j)
        i += ln
        while i < e:
            kind = b[i]
            n, i = leb(b, i + 1)
            if kind == 2:
                count, _ = leb(b, i)
                return count > 0
            i += n
    return False


def strip(b):
    """B without its name section, or None when it has none."""
    if b[:4] == b'\0asm':
        secs = sections(b, 0)
        if not needs_libs(b, secs):
            return None
        drop = [(s, e) for s, e, sid, name, _ in secs if sid == 0 and name == b'name']
        if not drop:
            return None
        out, last = bytearray(), 0
        for s, e in drop:
            out += b[last:s]
            last = e
        return bytes(out + b[last:])
    # (gexcc's executables only: 32-bit, i386 by e_machine, the module
    # right after the headers; a native program is left as it is)
    if b[:4] == b'\x7fELF' and b[4] == 1 and b[18:20] == b'\x03\x00':
        at = b.find(b'\0asm\x01\0\0\0', 0, 4096)
        if at < 0:
            return None
        secs = sections(b, at)
        if not needs_libs(b, secs):
            return None
        out, hit = bytearray(b), False
        for s, e, sid, name, j in secs:
            if sid == 0 and name == b'name':
                ln, k = leb(b, j)
                out[k:k + ln] = b'gexz'[:ln].ljust(ln, b'z')
                out[k + ln:e] = bytes(e - k - ln)
                hit = True
        return bytes(out) if hit else None
    return None


def main():
    tree = sys.argv[1]
    changed, saved = {}, 0
    for top in ('usr', 'lib', 'bin', 'sbin'):
        base = os.path.join(tree, top)
        if os.path.islink(base) or not os.path.isdir(base):
            continue
        for d, _, fs in os.walk(base):
            for f in fs:
                p = os.path.join(d, f)
                if os.path.islink(p) or not os.path.isfile(p) or os.path.getsize(p) < 8:
                    continue
                with open(p, 'rb') as fh:
                    head = fh.read(4)
                if head not in (b'\0asm', b'\x7fELF'):
                    continue
                b = open(p, 'rb').read()
                s = strip(b)
                if s is None:
                    continue
                st = os.stat(p)
                with open(p, 'wb') as fh:
                    fh.write(s)
                os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
                saved += len(b) - len(s)
                changed['/' + os.path.relpath(p, tree)] = hashlib.md5(s).hexdigest()
    # dpkg's record of each file's sum (md5sums names paths without the
    # leading slash)
    info = os.path.join(tree, 'var/lib/dpkg/info')
    for f in sorted(os.listdir(info)) if os.path.isdir(info) else []:
        if not f.endswith('.md5sums'):
            continue
        p = os.path.join(info, f)
        lines, dirty = [], False
        for line in open(p, encoding='utf-8', errors='surrogateescape'):
            h, _, path = line.rstrip('\n').partition('  ')
            new = changed.get('/' + path)
            if new and new != h:
                line, dirty = f'{new}  {path}\n', True
            lines.append(line)
        if dirty:
            open(p, 'w', encoding='utf-8', errors='surrogateescape').write(''.join(lines))
    print(f'stripnames: {len(changed)} modules, {saved / 1048576:.1f} MiB of name sections cut', file=sys.stderr)


if __name__ == '__main__':
    main()
