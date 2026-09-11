# Rewrites the numbers in INDEX.md from the files themselves: sizes, line
# counts, modified dates, the folder counts and the SHA256 prefixes. The prose
# is left alone. Run it after a change, so the index cannot drift:
#
#     python .github/update-index.py
#
# The project is found from this file's own location.
import datetime
import hashlib
import io
import os
import re

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
path = os.path.join(root, 'INDEX.md')
s = io.open(path, encoding='utf-8').read()
orig = s
changes = []


def size_text(n):
    if n < 1024:
        return '%d B' % n
    if n < 1024 * 1024:
        kb = n / 1024.0
        # Half up is the rule that reproduced the index as first written: 10 of
        # its 11 rows for files that had not changed. Rounding to even gave 8,
        # truncating 4.
        return ('%.1f KB' % kb) if kb < 10 else ('%d KB' % int(kb + 0.5))
    return '%.1f MB' % (n / 1048576.0)


def fix_row(m):
    # | `name` | <size>[, <n> lines] | [date |] ...
    name = m.group(1)
    p = os.path.join(root, name)
    if not os.path.isfile(p):
        return m.group(0)
    new_size = size_text(os.path.getsize(p))
    if m.group(3) is not None:
        with open(p, 'rb') as f:
            data = f.read()
        new_size += ', %d lines' % (data.count(b'\n') + (0 if data.endswith(b'\n') else 1))
    if m.group(5):
        new_date = datetime.date.fromtimestamp(os.path.getmtime(p)).isoformat()
        out = '| `%s` | %s | %s |' % (name, new_size, new_date)
    else:
        out = '| `%s` | %s |' % (name, new_size)
    if out != m.group(0):
        changes.append('%s: %s  ->  %s' % (name, m.group(0), out))
    return out


s = re.sub(r'^\| `([^`\\]+)` \| ([0-9.]+ (?:B|KB|MB))(, ([0-9]+) lines)? \|(?: ([0-9]{4}-[0-9]{2}-[0-9]{2}) \|)?',
           fix_row, s, flags=re.M)


def files_in(folder, recursive=False):
    base = os.path.join(root, folder)
    if not os.path.isdir(base):
        return 0
    if recursive:
        return sum(len(files) for _, _, files in os.walk(base))
    return len([f for f in os.listdir(base) if os.path.isfile(os.path.join(base, f))])


docs_count = len([f for f in os.listdir(os.path.join(root, 'docs')) if f.endswith('.md')])
s = re.sub(r'(\| `docs\\?` \| )[0-9]+ pages', lambda m: '%s%d pages' % (m.group(1), docs_count), s)
for folder, recursive in (('assets', False), ('.github', True), ('tests', False)):
    count = files_in(folder, recursive)
    s = re.sub(r'(\| `' + re.escape(folder) + r'\\?` \| )[0-9]+ files', lambda m: '%s%d files' % (m.group(1), count), s)

top_files = [f for f in os.listdir(root) if os.path.isfile(os.path.join(root, f)) and not f.startswith('.')]
s = re.sub(r'^[0-9]+ files at the top level', '%d files at the top level' % len(top_files), s, flags=re.M)


def fix_sha(m):
    out = []
    for line in m.group(2).strip('\n').split('\n'):
        parts = line.split(None, 1)
        if len(parts) != 2:
            out.append(line)
            continue
        name = parts[1].strip()
        p = os.path.join(root, name)
        if os.path.isfile(p):
            h = hashlib.sha256(open(p, 'rb').read()).hexdigest()[:16]
            if h != parts[0]:
                changes.append('sha %s: %s -> %s' % (name, parts[0], h))
            out.append('%s  %s' % (h, name))
        else:
            changes.append('sha %s: file is gone, row dropped' % name)
    return m.group(1) + '\n'.join(out) + '\n' + m.group(3)


s = re.sub(r'(## SHA256 \(first 16 hex characters\)\n\n```\n)(.*?)(```)', fix_sha, s, flags=re.S)
s = re.sub(r'Index written [0-9]{4}-[0-9]{2}-[0-9]{2}\.', 'Index written %s.' % datetime.date.today().isoformat(), s)

io.open(path, 'w', encoding='utf-8', newline='').write(s)
for c in changes:
    print(c)
print('files at the top level: %d, docs: %d' % (len(top_files), docs_count))
print('changed' if s != orig else 'already current')
