#!/usr/bin/env python3
"""Check a roundup extract carries what the roundup reads.

    python3 tools/inspect.py out/gb.pmtiles [more.pmtiles ...]

Pure Python (no dependencies): reads the PMTiles v3 directory, decodes each
tile's Mapbox Vector Tile layers, and reports per zoom:

- tile count and bytes;
- features per layer, and for `transportation` the classes present;
- for `transportation_name`, how many features carry a `ref`, and B-road refs
  (`B1234`) by OpenMapTiles class, which is how we learn whether GB's B-roads
  are tagged secondary or tertiary;
- `mountain_peak` features with an elevation.

Zooms checked: 5, 9 and 12 by default (the brief's three), or --zooms=5,7,9.
At high zooms it samples up to --sample tiles (default 400) evenly.

It is a check, not just a report: for every checked zoom inside the file's own
zoom range there must be tiles, and the sampled tiles must carry the
`transportation` and `water` layers the Tarmac style draws. Otherwise it
prints FAIL lines and exits 1 (extract-build.sh `verify` relies on that).
Zooms outside the file's range (z9 in the z0-6 world extract) are skipped.
"""
import gzip
import re
import struct
import sys
from collections import Counter, defaultdict


def varint(buf, i):
    shift = result = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def decompress(data, kind):
    if kind == 2:
        return gzip.decompress(data)
    if kind in (0, 1):
        return data
    raise SystemExit(f"unsupported compression {kind}")


def zxy(tile_id):
    # Hilbert tile id -> z, x, y (PMTiles v3 spec).
    acc = 0
    for z in range(32):
        n = (1 << z) * (1 << z)
        if acc + n > tile_id:
            pos = tile_id - acc
            x = y = 0
            s = 1
            t = pos
            while s < (1 << z):
                rx = 1 & (t // 2)
                ry = 1 & (t ^ rx)
                if ry == 0:
                    if rx == 1:
                        x = s - 1 - x
                        y = s - 1 - y
                    x, y = y, x
                x += s * rx
                y += s * ry
                t //= 4
                s *= 2
            return z, x, y
        acc += n
    raise ValueError(tile_id)


class PMTiles:
    def __init__(self, path):
        self.f = open(path, "rb")
        h = self.f.read(127)
        if h[:7] != b"PMTiles" or h[7] != 3:
            raise SystemExit(f"{path}: not PMTiles v3")
        (self.root_off, self.root_len, self.meta_off, self.meta_len, self.leaf_off,
         self.leaf_len, self.data_off, self.data_len, self.n_addressed, self.n_entries,
         self.n_contents) = struct.unpack_from("<11Q", h, 8)
        self.clustered, self.internal_comp, self.tile_comp, self.tile_type, self.minz, self.maxz = \
            struct.unpack_from("<6B", h, 96)

    def read(self, off, length):
        self.f.seek(off)
        return self.f.read(length)

    def directory(self, off, length):
        buf = decompress(self.read(off, length), self.internal_comp)
        n, i = varint(buf, 0)
        ids, runs, lens, offs = [], [], [], []
        last = 0
        for _ in range(n):
            d, i = varint(buf, i)
            last += d
            ids.append(last)
        for _ in range(n):
            v, i = varint(buf, i)
            runs.append(v)
        for _ in range(n):
            v, i = varint(buf, i)
            lens.append(v)
        for k in range(n):
            v, i = varint(buf, i)
            offs.append(offs[k - 1] + lens[k - 1] if v == 0 and k > 0 else v - 1)
        return list(zip(ids, runs, lens, offs))

    def entries(self):
        """Yield (tile_id, run_length, length, offset) for every tile entry."""
        stack = [(self.root_off, self.root_len)]
        while stack:
            off, ln = stack.pop()
            for tid, run, length, o in self.directory(off, ln):
                if run == 0:
                    stack.append((self.leaf_off + o, length))
                else:
                    yield tid, run, length, o

    def tile(self, length, offset):
        return decompress(self.read(self.data_off + offset, length), self.tile_comp)


def fields(buf):
    i, n = 0, len(buf)
    while i < n:
        key, i = varint(buf, i)
        f, w = key >> 3, key & 7
        if w == 0:
            v, i = varint(buf, i)
        elif w == 2:
            ln, i = varint(buf, i)
            v = buf[i:i + ln]
            i += ln
        elif w == 5:
            v = buf[i:i + 4]
            i += 4
        elif w == 1:
            v = buf[i:i + 8]
            i += 8
        else:
            raise ValueError(w)
        yield f, w, v


def value(buf):
    for f, w, v in fields(buf):
        if f == 1:
            return v.decode("utf-8", "replace")
        if f == 2:
            return struct.unpack("<f", v)[0]
        if f == 3:
            return struct.unpack("<d", v)[0]
        if f in (4, 5):
            return v
        if f == 6:
            return (v >> 1) ^ -(v & 1)
        if f == 7:
            return bool(v)
    return None


def layer_bytes(tile):
    """Uncompressed bytes per layer in one tile."""
    out = Counter()
    for f, w, v in fields(tile):
        if f == 3:
            for lf, lw, lv in fields(v):
                if lf == 1:
                    out[lv.decode()] += len(v)
                    break
    return out


def layers(tile):
    for f, w, v in fields(tile):
        if f != 3:
            continue
        name, keys, vals, feats = None, [], [], []
        for lf, lw, lv in fields(v):
            if lf == 1:
                name = lv.decode()
            elif lf == 2:
                feats.append(lv)
            elif lf == 3:
                keys.append(lv.decode())
            elif lf == 4:
                vals.append(value(lv))
        out = []
        for ft in feats:
            props = {}
            for ff, fw, fv in fields(ft):
                if ff == 2:
                    tags, j = [], 0
                    while j < len(fv):
                        t, j = varint(fv, j)
                        tags.append(t)
                    for a in range(0, len(tags) - 1, 2):
                        props[keys[tags[a]]] = vals[tags[a + 1]]
            out.append(props)
        yield name, out


REQUIRED_LAYERS = ("transportation", "water")


def problems(minz, maxz, zoom_stats):
    """zoom_stats: {zoom: (tiles_in_file, Counter of features by layer)}.

    Returns a list of failure strings; empty means the extract carries what
    the roundup reads at every checked zoom its own range covers.
    """
    out = []
    for z, (tiles, feats) in sorted(zoom_stats.items()):
        if not (minz <= z <= maxz):
            continue
        if tiles == 0:
            out.append(f"z{z}: no tiles")
            continue
        for layer in REQUIRED_LAYERS:
            if feats.get(layer, 0) == 0:
                out.append(f"z{z}: no `{layer}` features in the sampled tiles")
    return out


B_REF = re.compile(r"\bB\d{1,4}\b")
A_REF = re.compile(r"\bA\d{1,4}(\(M\))?\b")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    zooms = [int(z) for z in opts.get("zooms", "5,9,12").split(",")]
    sample = int(opts.get("sample", "400"))
    failures = []
    if not args:
        raise SystemExit("usage: inspect.py file.pmtiles [more.pmtiles ...] [--zooms=5,9,12] [--sample=400]")
    for path in args:
        zoom_stats = {}
        p = PMTiles(path)
        print(f"\n== {path}")
        print(f"zooms {p.minz}-{p.maxz}, addressed tiles {p.n_addressed}, "
              f"entries {p.n_entries}, unique contents {p.n_contents}")
        by_zoom = defaultdict(list)
        size_by_zoom = Counter()
        count_by_zoom = Counter()
        for tid, run, length, off in p.entries():
            z, _, _ = zxy(tid)
            count_by_zoom[z] += run
            size_by_zoom[z] += length * run
            by_zoom[z].append((length, off))
        print("zoom  tiles      bytes")
        for z in sorted(count_by_zoom):
            print(f"{z:>4} {count_by_zoom[z]:>6} {size_by_zoom[z]:>10}")
        for z in zooms:
            items = by_zoom.get(z, [])
            if not items:
                print(f"\nz{z}: no tiles")
                zoom_stats[z] = (0, Counter())
                continue
            step = max(1, len(items) // sample)
            picked = items[::step]
            feats = Counter()
            classes = Counter()
            name_classes = Counter()
            refs = Counter()
            bref_class = Counter()
            aref_class = Counter()
            peaks = peaks_ele = 0
            lbytes = Counter()
            for length, off in picked:
                raw = p.tile(length, off)
                lbytes.update(layer_bytes(raw))
                for name, fs in layers(raw):
                    feats[name] += len(fs)
                    for pr in fs:
                        if name == "transportation":
                            classes[pr.get("class")] += 1
                        elif name == "transportation_name":
                            name_classes[pr.get("class")] += 1
                            ref = pr.get("ref")
                            if ref:
                                refs["with ref"] += 1
                                if B_REF.search(str(ref)):
                                    bref_class[pr.get("class")] += 1
                                if A_REF.search(str(ref)):
                                    aref_class[pr.get("class")] += 1
                        elif name == "mountain_peak":
                            peaks += 1
                            if pr.get("ele") is not None:
                                peaks_ele += 1
            print(f"\nz{z}: {len(picked)} of {len(items)} tiles decoded")
            print("  features by layer:", dict(feats.most_common()))
            total = sum(lbytes.values()) or 1
            print("  share of raw bytes:", {k: f"{100 * v / total:.0f}%" for k, v in lbytes.most_common()})
            print("  transportation classes:", dict(classes.most_common()))
            print("  transportation_name classes:", dict(name_classes.most_common()),
                  "| with ref:", refs["with ref"])
            print("  B-road refs by class:", dict(bref_class.most_common()))
            print("  A-road refs by class:", dict(aref_class.most_common()))
            print(f"  mountain_peak: {peaks} ({peaks_ele} with ele)")
            zoom_stats[z] = (len(items), feats)
        for msg in problems(p.minz, p.maxz, zoom_stats):
            failures.append(f"{path}: {msg}")
    for msg in failures:
        print(f"FAIL {msg}", file=sys.stderr)
    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
