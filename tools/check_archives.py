# -*- coding: utf-8 -*-
"""扫描目录下所有压缩包，判断哪些能正常解压。

用法:
    python tools/check_archives.py <目录> [输出报告.txt]

判断依据（按可靠性排序）:
    1. 全零块扫描 —— 百度网盘下载不完整时会把文件大小填对，但内容是大片全零，
       这是最常见也最隐蔽的损坏方式，普通"能否打开"检查发现不了。
    2. zip 逐条 CRC；rar 用 UnRAR.exe t；7z 用 py7zr；tar 遍历条目。
    3. >300MB 的文件跳过全量 CRC（太慢），依赖全零块扫描 + 结构检查。

退出码: 有损坏文件返回 1，全部正常返回 0。
"""
import os
import io
import sys
import zipfile
import tarfile
import subprocess

UNRAR = r'C:\Program Files\WinRAR\UnRAR.exe'
BIG = 300 * 1024 * 1024
CHUNK = 1024 * 1024
EXTS = ('.zip', '.rar', '.7z', '.tar', '.tar.gz', '.tgz')


def zero_ranges(path):
    """返回全零块字节区间列表，以及总零字节数。"""
    ranges = []
    pos = 0
    with open(path, 'rb') as f:
        while True:
            data = f.read(CHUNK)
            if not data:
                break
            if data == b'\x00' * len(data):
                ranges.append((pos, pos + len(data)))
            pos += len(data)
    merged = []
    for a, b in ranges:
        if merged and merged[-1][1] == a:
            merged[-1] = (merged[-1][0], b)
        else:
            merged.append((a, b))
    return merged, sum(b - a for a, b in merged)


def test_zip(path):
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        if not infos:
            return 'WARN', '包内为空'
        comp = sum(i.compress_size for i in infos)
        if os.path.getsize(path) < comp:
            return 'FAIL', '文件小于压缩数据总量，截断'
        if os.path.getsize(path) <= BIG:
            bad = z.testzip()
            if bad:
                return 'FAIL', 'CRC 校验失败: %s' % bad
            return 'OK', '%d 个条目，CRC 全通过' % len(infos)
        return 'OK', '%d 个条目（大文件仅结构检查）' % len(infos)


def test_rar(path):
    r = subprocess.run([UNRAR, 't', '-p-', '-idq', '--', path], capture_output=True)
    if r.returncode == 0:
        return 'OK', ''
    msg = (r.stdout + r.stderr).decode('gbk', errors='replace').strip()
    tail = [l for l in msg.splitlines() if l.strip()]
    return 'FAIL', tail[-1] if tail else 'unrar rc=%d' % r.returncode


def test_7z(path):
    import py7zr
    with py7zr.SevenZipFile(path, mode='r') as z:
        names = z.getnames()
    if os.path.getsize(path) <= BIG:
        with py7zr.SevenZipFile(path, mode='r') as z:
            z.test()
        return 'OK', '%d 个条目，CRC 全通过' % len(names)
    return 'OK', '%d 个条目' % len(names)


def test_tar(path):
    t = tarfile.open(path, 'r:*')
    try:
        if os.path.getsize(path) <= BIG:
            n = sum(1 for _ in t)
            return 'OK', '%d 个条目（遍历通过）' % n
        m = t.next()
        return 'OK', '大文件仅检查头部，首项: %s' % (m.name if m else '?')
    finally:
        t.close()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    root = sys.argv[1]
    report = sys.argv[2] if len(sys.argv) > 2 else None
    out = io.open(report, 'w', encoding='utf-8') if report else sys.stdout

    targets = []
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if name.lower().endswith(EXTS):
                targets.append(os.path.join(dirpath, name))
    targets.sort()

    rows = []
    for path in targets:
        size = os.path.getsize(path)
        low = path.lower()
        try:
            if low.endswith('.zip'):
                status, note = test_zip(path)
            elif low.endswith('.rar'):
                status, note = test_rar(path)
            elif low.endswith('.7z'):
                status, note = test_7z(path)
            else:
                status, note = test_tar(path)
        except Exception as exc:
            status, note = 'FAIL', str(exc)

        zeros, zbytes = zero_ranges(path)
        if zbytes:
            pct = 100.0 * zbytes / size
            detail = '全零区 %.1f MB (%.1f%%)' % (zbytes / 1048576.0, pct)
            if status == 'OK' and pct > 1:
                status = 'FAIL'
                note = detail + '；' + (note or '')
            else:
                note = (note + '；' if note else '') + detail
        rows.append((status, os.path.relpath(path, root), size, note))
        print('%s  %s' % (status, os.path.relpath(path, root)[:100]), flush=True)

    rows.sort(key=lambda r: (r[0] != 'FAIL', r[1]))
    out.write('待测压缩包: %d\n\n' % len(rows))
    for status, rel, size, note in rows:
        out.write('[%s] %9.1f MB  %s\n' % (status, size / 1048576.0, rel))
        if note:
            out.write('        %s\n' % note)

    bad = [r for r in rows if r[0] == 'FAIL']
    out.write('\n===== 汇总 =====\n')
    out.write('完好 : %d\n损坏 : %d\n' % (len(rows) - len(bad), len(bad)))
    if bad:
        out.write('\n--- 需要重新下载 ---\n')
        for status, rel, size, note in bad:
            out.write('  %9.1f MB  %s\n' % (size / 1048576.0, rel))
    if report:
        out.close()
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
