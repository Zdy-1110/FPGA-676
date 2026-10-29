import re, sys
lines = open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines()
words = []
for l in lines:
    s = l.split()
    if len(s) == 4 and all(re.fullmatch(r'[0-9a-f]{8}', x) for x in s):
        words += [int(x, 16) for x in s]
print('words', len(words))
rd = lambda off: words[off // 4]
p = rd(0x34) & 0xff
while p:
    h = rd(p); print('cap %03x id %02x' % (p, h & 0xff)); p = (h >> 8) & 0xff
p = 0x100
while 0 < p < len(words) * 4:
    h = rd(p); cid = h & 0xffff; nxt = h >> 20
    extra = ' vsec hdr %08x' % rd(p + 4) if cid == 0xb else ''
    print('ext %03x id %04x v%d next %03x%s' % (p, cid, (h >> 16) & 0xf, nxt, extra))
    if h == 0: break
    p = nxt
