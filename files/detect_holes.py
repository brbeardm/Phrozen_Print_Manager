#!/usr/bin/env python3
"""
detect_holes — faceted-bore detector + hole-schedule sidecar writer.

Finds faceted cylindrical bores in a Tinkercad OBJ, reports each one's
axis, entry center, diameter, depth, and through/blind/counterbore type,
and writes a JSON "hole schedule" sidecar for the Fusion drill add-in.
It does NOT modify the solid or the STEP — the sidecar tells downstream
tooling where to place true cylindrical holes. Reuses obj2step's welding.
Sidecar coordinates are raw model coordinates, the same frame obj2step
writes the STEP in, so they can be used in Fusion without transformation.

Robust method (axis-aligned parts):
  1. Weld mesh.
  2. "Wall facets" = faces on a facet-transition edge (dihedral 1..50 deg);
     this excludes flat walls (~0) and sharp corners (~90).
  3. For each candidate axis (the part's dominant flat-face normals):
     a. Keep wall facets whose normal is perpendicular to the axis.
     b. Cluster them by location in the plane perpendicular to the axis
        (single-linkage) -> one cluster per bore location.
     c. Split each cluster by radial distance -> concentric rings
        (this separates a counterbore's two diameters).
     d. Circle-fit each ring; measure extent along the axis (depth) and
        where it sits in the material (through vs blind, entry face).
  4. Group rings that share an axis line -> counterbore/countersink.

Usage:
  python detect_holes.py model.obj                 # report + sidecar next to the OBJ
  python detect_holes.py model.obj -j out.json     # sidecar at an explicit path
  python detect_holes.py model.obj --no-json       # report only
"""

import argparse
import json
import os
from collections import defaultdict
import numpy as np
from scipy.cluster.hierarchy import fcluster, linkage

from obj2step import load_and_defin

SCHEMA = "obj2step-hole-schedule/1"


def circle_fit(xy):
    x, y = xy[:, 0], xy[:, 1]
    A = np.c_[2 * x, 2 * y, np.ones(len(x))]
    b = x ** 2 + y ** 2
    sol, *_ = np.linalg.lstsq(A, b, rcond=None)
    cx, cy, c = sol
    r = np.sqrt(max(c + cx ** 2 + cy ** 2, 0.0))
    resid = np.sqrt(np.mean((np.hypot(x - cx, y - cy) - r) ** 2))
    return np.array([cx, cy]), r, resid


def basis_perp(axis):
    a = axis / np.linalg.norm(axis)
    ref = np.array([1.0, 0, 0]) if abs(a[0]) < 0.9 else np.array([0, 1.0, 0])
    u = np.cross(a, ref); u /= np.linalg.norm(u)
    v = np.cross(a, u)
    return u, v


def split_by_radius(rad, gap=0.6):
    """Split radial distances into concentric rings at large gaps."""
    order = np.argsort(rad)
    groups, cur = [], [order[0]]
    for k in range(1, len(order)):
        if rad[order[k]] - rad[order[k - 1]] > gap:
            groups.append(cur); cur = []
        cur.append(order[k])
    groups.append(cur)
    return groups


def dominant_axes(m, min_area_frac=0.02):
    FN, A = m.face_normals, m.area_faces
    tot = A.sum()
    from collections import defaultdict
    d = defaultdict(float)
    for n, a in zip(FN, A):
        d[tuple(np.round(n, 1))] += a
    axes = []
    for k, a in sorted(d.items(), key=lambda x: -x[1]):
        if a < min_area_frac * tot:
            break
        v = np.array(k, float)
        if np.linalg.norm(v) < 0.5:
            continue
        v /= np.linalg.norm(v)
        if not any(abs(v @ e) > 0.98 for e in axes):
            axes.append(v)
    return axes


def detect(m, min_faces=20, max_dia=60.0, min_depth=0.4):
    V, F, FN = np.asarray(m.vertices), m.faces, np.asarray(m.face_normals)
    cent = np.asarray(V[F].mean(1))
    adj, ang = m.face_adjacency, np.degrees(m.face_adjacency_angles)
    trans = (ang > 1.0) & (ang < 50.0)

    axes = dominant_axes(m)
    # Route each wall facet to the axis it rotates about (cross of the
    # transition edge's normals), and estimate its local radius from the
    # curvature: adjacent facets rotate by delta over arc-length ds, so
    # r = ds / (2 sin(delta/2)). center = facet + r * inward-normal.
    axis_faces = [set() for _ in axes]
    face_r = defaultdict(list)
    for (a, b), t in zip(adj, trans):
        if not t:
            continue
        na, nb = FN[a], FN[b]
        cr = np.cross(na, nb); n = np.linalg.norm(cr)
        if n < 0.02:
            continue
        cr /= n
        dots = [abs(cr @ e) for e in axes]
        j = int(np.argmax(dots))
        if dots[j] <= 0.94:
            continue
        e = axes[j]
        delta = np.arccos(np.clip(na @ nb, -1, 1))
        chord = cent[a] - cent[b]
        chord = chord - (chord @ e) * e          # perpendicular to axis
        ds = np.linalg.norm(chord)
        if delta < 1e-4:
            continue
        r = ds / (2 * np.sin(delta / 2))
        axis_faces[j].add(a); axis_faces[j].add(b)
        face_r[a].append(r); face_r[b].append(r)

    zmin, zmax = V[:, 2].min(), V[:, 2].max()
    rings = []
    for axis, faceset in zip(axes, axis_faces):
        u, v = basis_perp(axis)
        sel = np.array(sorted(faceset), dtype=int)
        if len(sel) < min_faces:
            continue
        pf = np.c_[cent[sel] @ u, cent[sel] @ v]
        nfc = np.c_[FN[sel] @ u, FN[sel] @ v]
        nfc /= np.clip(np.linalg.norm(nfc, axis=1, keepdims=True), 1e-9, None)
        rest = np.array([np.median(face_r[i]) for i in sel])
        # per-facet centre estimate (inward normal points at the axis)
        cest = pf + rest[:, None] * nfc

        lab = fcluster(linkage(cest, 'single'), t=1.5, criterion='distance')
        for L in set(lab):
            grp0 = np.where(lab == L)[0]
            if len(grp0) < min_faces:
                continue
            cxy = cest[grp0].mean(0)
            fidx = sel[grp0]
            fv = np.unique(F[fidx].ravel())
            P = np.asarray(V[fv])
            xy = np.c_[P @ u, P @ v]
            rad = np.hypot(xy[:, 0] - cxy[0], xy[:, 1] - cxy[1])
            t_ax = P @ axis
            for grp in split_by_radius(rad, gap=0.8):
                g = np.array(grp)
                if len(g) < 6:
                    continue
                c, r, res = circle_fit(xy[g])
                if r < 0.4 or r > max_dia / 2:
                    continue
                # Concavity gate: a bore's facet normals point toward its
                # axis. A convex ring at the same radius (e.g. the outer
                # wall of the boss the bore lives in) fits a circle just as
                # well — reject it via facets fully inside this ring group.
                gset = set(fv[g].tolist())
                fin = [fi for fi in fidx
                       if all(int(vv) in gset for vv in F[fi])]
                if fin:
                    fc2 = np.c_[cent[fin] @ u, cent[fin] @ v]
                    nf2 = np.c_[FN[fin] @ u, FN[fin] @ v]
                    inward = np.einsum('ij,ij->i', c - fc2, nf2)
                    if np.median(inward) < 0:
                        continue
                t0, t1 = t_ax[g].min(), t_ax[g].max()
                depth = t1 - t0
                if depth < min_depth:
                    continue
                center3 = cxy[0] * u + cxy[1] * v
                mid = center3 + 0.5 * (t0 + t1) * axis
                if np.any(mid < m.bounds[0] - 1.0) or \
                   np.any(mid > m.bounds[1] + 1.0):
                    continue
                rings.append(dict(axis=axis, u=u, v=v, c=cxy, r=r, res=res,
                                  fit_c=c, t0=t0, t1=t1, depth=depth,
                                  center_line=center3, nf=len(g)))
    return rings, (zmin, zmax)


class VoidProbe:
    """Solid/void oracle: cast a ray along a cardinal axis and count surface
    crossings (odd = inside solid). This is how we tell a through hole from a
    blind one and measure true depth -- independent of how the wall was
    faceted. Watertight mesh required."""

    def __init__(self, m):
        self.T = np.asarray(m.vertices)[m.faces]        # (n,3,3)

    def _crossings(self, px, py, i0, i1, iax):
        T = self.T
        a0, a1, aa = T[:, 0, i0], T[:, 0, i1], T[:, 0, iax]
        b0, b1, ba = T[:, 1, i0], T[:, 1, i1], T[:, 1, iax]
        c0, c1, ca = T[:, 2, i0], T[:, 2, i1], T[:, 2, iax]
        d1 = (b0 - a0) * (py - a1) - (b1 - a1) * (px - a0)
        d2 = (c0 - b0) * (py - b1) - (c1 - b1) * (px - b0)
        d3 = (a0 - c0) * (py - c1) - (a1 - c1) * (px - c0)
        area = np.abs((b0 - a0) * (c1 - a1) - (b1 - a1) * (c0 - a0))
        ins = (((d1 >= 0) & (d2 >= 0) & (d3 >= 0)) |
               ((d1 <= 0) & (d2 <= 0) & (d3 <= 0))) & (area > 1e-9)
        w1, w2, w3 = d2, d3, d1
        tot = w1 + w2 + w3
        with np.errstate(all='ignore'):
            val = (w1 * aa + w2 * ba + w3 * ca) / tot
        return np.sort(val[ins])

    def solid_at(self, ctr, others, iax, s):
        """Majority vote over small in-plane nudges (dodges vertex hits)."""
        yes = 0
        for dx, dy in [(.05, .03), (-.04, .06), (.07, -.05), (-.06, -.04)]:
            zc = self._crossings(ctr[others[0]] + dx, ctr[others[1]] + dy,
                                 others[0], others[1], iax)
            if (np.sum(zc > s) % 2) == 1:
                yes += 1
        return yes >= 3

    def material_span(self, ctr, others, iax, ring_r):
        """Local face-to-face extent along the axis, sampled just outside the
        hole so we read the plate, not the void."""
        lo, hi = [], []
        R = ring_r + 0.6
        for a in range(0, 360, 30):
            px = ctr[others[0]] + R * np.cos(np.deg2rad(a))
            py = ctr[others[1]] + R * np.sin(np.deg2rad(a))
            zc = self._crossings(px, py, others[0], others[1], iax)
            if len(zc) >= 2:
                lo.append(zc[0]); hi.append(zc[-1])
        if not lo:
            return None
        return float(np.median(lo)), float(np.median(hi))


def merge_holes(rings, off_tol=0.6):
    """Union coaxial rings at the same centre into one hole (a counterbore is
    two rings; a plain hole is one)."""
    holes = []
    for r in rings:
        placed = False
        for h in holes:
            if abs(h['axis'] @ r['axis']) > 0.99:
                d = h['center_line'] - r['center_line']
                d = d - (d @ h['axis']) * h['axis']
                if np.linalg.norm(d) < off_tol:
                    h['rings'].append(r); placed = True; break
        if not placed:
            holes.append(dict(axis=r['axis'], center_line=r['center_line'],
                              rings=[r]))
    return holes


def classify_holes(probe, holes):
    for h in holes:
        ax = h['axis']
        iax = int(np.argmax(np.abs(ax)))
        s_ax = 1.0 if ax[iax] >= 0 else -1.0
        others = [i for i in range(3) if i != iax]
        ctr = h['center_line']
        # ring extents in world coordinates along +iax (ax's own sign is
        # arbitrary — whichever flat-face normal seeded it — so t0/t1 flip)
        for r in h['rings']:
            w = sorted((s_ax * r['t0'], s_ax * r['t1']))
            r['w0'], r['w1'] = float(w[0]), float(w[1])
        Rmax = max(r['r'] for r in h['rings'])
        span = probe.material_span(ctr, others, iax, Rmax)
        if span is None:
            h['type'] = 'unknown'; h['depth'] = 0.0; h['entry'] = ctr
            h['span'] = None; continue
        slo, shi = span
        # the entry face can sit beyond the probed span when the hole lives
        # in a raised boss narrower than the probe ring (the probe then reads
        # the surrounding floor) — extend to the rings' own extents
        face_lo = min(slo, min(r['w0'] for r in h['rings']))
        face_hi = max(shi, max(r['w1'] for r in h['rings']))
        scan = np.linspace(slo + 0.1, shi - 0.1, 50)
        void = np.array([not probe.solid_at(ctr, others, iax, s) for s in scan])
        open_lo, open_hi = bool(void[0]), bool(void[-1])
        if void.all() or (open_lo and open_hi):
            # through: enter on the face nearer the largest-diameter ring —
            # a counterbore recess is drilled from its own face
            big = max(h['rings'], key=lambda r: r['r'])
            mid = 0.5 * (big['w0'] + big['w1'])
            if abs(mid - face_lo) < abs(mid - face_hi):
                entry_s, sign = (face_lo, +1.0)
            else:
                entry_s, sign = (face_hi, -1.0)
            h['type'] = 'through'; h['depth'] = face_hi - face_lo
        elif open_lo:
            i = int(np.argmax(~void)) if (~void).any() else len(scan)
            cap = scan[i] if i < len(scan) else shi
            h['type'] = 'blind'; h['depth'] = cap - face_lo
            entry_s, sign = (face_lo, +1.0)
        elif open_hi:
            i = len(scan) - 1 - int(np.argmax(~void[::-1]))
            cap = scan[i]
            h['type'] = 'blind'; h['depth'] = face_hi - cap
            entry_s, sign = (face_hi, -1.0)
        else:
            h['type'] = 'false?'; h['depth'] = 0.0
            entry_s, sign = (face_hi, -1.0)
        entry = ctr.copy(); entry[iax] = entry_s
        h['entry'] = entry
        # sign encodes "into the material from the entry face"
        h['dir'] = sign * np.eye(3)[iax]
        h['span'] = (slo, shi)
        # ring profile ordered from the entry face inward (world frame)
        for r in h['rings']:
            r['from_entry'] = abs(0.5 * (r['w0'] + r['w1']) - entry_s)
        h['rings'].sort(key=lambda r: r['from_entry'])
    return holes


def analyze(m):
    """Full pipeline on a welded mesh: detect rings, merge coaxial rings into
    holes, classify through/blind via the void probe. Returns holes sorted by
    location (stable ids across runs of the same part)."""
    rings, _ = detect(m)
    holes = classify_holes(VoidProbe(m), merge_holes(rings))
    holes.sort(key=lambda h: (round(h['center_line'][0], 1),
                              round(h['center_line'][1], 1)))
    return holes


def build_schedule(holes, source_path=None, step_path=None, bounds=None):
    """JSON-serializable hole schedule for the Fusion drill add-in.
    Coordinates are model-frame mm (identical to the STEP's frame).
    Each hole's segments run from the entry face inward, so a counterbore is
    [large D x cb-depth, small D x remaining]."""
    real = [h for h in holes if h['type'] in ('through', 'blind')]
    rejected = sorted(set(h['type'] for h in holes) - {'through', 'blind'})
    sched = {
        "schema": SCHEMA,
        "units": "mm",
        "frame": "model",
        "source": os.path.basename(source_path) if source_path else None,
        "step": os.path.basename(step_path) if step_path else None,
        "bounds": ([[round(float(x), 4) for x in b] for b in bounds]
                   if bounds is not None else None),
        "hole_count": len(real),
        "holes": [],
    }
    if rejected:
        sched["rejected_feature_types"] = rejected
    for i, h in enumerate(real, 1):
        e_i = int(np.argmax(np.abs(h['axis'])))
        segments = []
        for r in h['rings']:
            # each segment gets its OWN fitted axis position: Tinkercad
            # counterbores are not always coaxial with their bore (seen
            # 0.2 mm offset), and the merged hole center fits neither
            p = (r['fit_c'][0] * r['u'] + r['fit_c'][1] * r['v']).copy()
            p[e_i] = h['entry'][e_i]
            segments.append({
                "diameter": round(2 * float(r['r']), 3),
                "depth": round(float(r['depth']), 3),
                "entry": [round(float(x), 4) for x in p],
                "fit_rms": round(float(r['res']), 4),
                "facets": int(r['nf'])})
        sched["holes"].append({
            "id": i,
            "type": h['type'],
            "style": "counterbore" if len(segments) > 1 else "simple",
            "entry": [round(float(x), 4) for x in h['entry']],
            "direction": [round(float(x), 4) for x in h['dir']],
            "depth": round(float(h['depth']), 3),
            "segments": segments,
        })
    return sched


def main():
    ap = argparse.ArgumentParser(
        description="Detect faceted bores; write a hole-schedule sidecar")
    ap.add_argument("input", help="OBJ file to analyze")
    ap.add_argument("-j", "--json", default=None,
                    help="sidecar path (default: <input>-holes.json)")
    ap.add_argument("--no-json", action="store_true",
                    help="print the report only, write nothing")
    args = ap.parse_args()
    path = args.input
    m, nf, nd = load_and_defin(path)
    ox, oy = m.bounds[0][0], m.bounds[0][1]           # bottom-left origin
    print(f"\n=== {path} ===")
    print(f"welded {len(m.vertices)} verts / {len(m.faces)} faces | "
          f"bbox {np.round(m.bounds[1]-m.bounds[0],1)} | origin=bottom-left")

    holes = analyze(m)

    real = [h for h in holes if h['type'] in ('through', 'blind')]
    print(f"\n{len(real)} hole(s):  (coords from bottom-left origin)\n")
    hdr = (f"{'x':>7}{'y':>7}  {'axis':>5}  {'type':<7}{'depth':>7}   profile"
           f" (from entry face inward)")
    print(hdr); print('-' * (len(hdr) + 8))
    axname = {0: 'X', 1: 'Y', 2: 'Z'}
    for h in real:
        c = h['center_line']
        iax = int(np.argmax(np.abs(h['axis'])))
        prof = " -> ".join(
            f"D{2*r['r']:.1f}x{r['depth']:.1f}" for r in h['rings'])
        print(f"{c[0]-ox:7.2f}{c[1]-oy:7.2f}  {axname[iax]:>5}  "
              f"{h['type']:<7}{h['depth']:>7.2f}   {prof}")
    other = [h for h in holes if h['type'] not in ('through', 'blind')]
    if other:
        print(f"\n({len(other)} feature(s) flagged non-drillable: "
              f"{', '.join(sorted(set(h['type'] for h in other)))})")

    if not args.no_json:
        out = args.json or os.path.splitext(path)[0] + "-holes.json"
        sched = build_schedule(holes, source_path=path,
                               bounds=np.asarray(m.bounds))
        with open(out, "w") as f:
            json.dump(sched, f, indent=2)
        print(f"\nsidecar written: {out}")
    print()


if __name__ == "__main__":
    main()
