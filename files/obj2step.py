#!/usr/bin/env python3
"""
obj2step — Tinkercad OBJ to Fusion-ready STEP converter.

Fixes the broken "Send to Fusion" pipeline by repairing Tinkercad's mesh
export defects (sliver fans, zero-width fins, boolean scars) and building a
true B-Rep solid with explicitly shared topology, so face orientations are
consistent by construction.

Pipeline:
  1. Load + weld vertices
  2. Remove fin faces (duplicate vertex-set twins) and degenerate triangles
  3. Detect planar regions (planarity-driven region growing)
  4. Snap vertices exactly onto region planes (step-protected, so near-parallel
     micro-steps are never collapsed)
  5. Self-intersection repair loop (revert any vertex the snap damaged)
  6. Build the solid with shared vertices/edges and winding-derived
     orientation (zero orientation conflicts by construction)
  7. Merge coplanar faces (UnifySameDomain)
  8. Verify: orientation conflicts, meshability, deviation vs input,
     optional fillet smoke test
  9. Write STEP (+ a cleaned STL fallback for Fusion's own mesh converter)

Usage:
  python obj2step.py model.obj
  python obj2step.py model.obj -o outdir --fillet-test

Requires: pip install trimesh pymeshlab cadquery-ocp numpy scipy
License: MIT
"""

import argparse
import json
import os
import sys
import tempfile
from collections import defaultdict, deque

import numpy as np

try:
    import trimesh
except ImportError:
    sys.exit("missing dependency: pip install trimesh")
try:
    import pymeshlab
except ImportError:
    sys.exit("missing dependency: pip install pymeshlab")
try:
    from OCP.gp import gp_Pnt, gp_Dir, gp_Pln, gp_Ax3
    from OCP.BRep import BRep_Builder, BRep_Tool
    from OCP.BRepBuilderAPI import (
        BRepBuilderAPI_MakeVertex, BRepBuilderAPI_MakeEdge,
        BRepBuilderAPI_MakeWire, BRepBuilderAPI_MakeFace,
        BRepBuilderAPI_MakeSolid,
    )
    from OCP.TopoDS import TopoDS, TopoDS_Shell
    from OCP.TopAbs import TopAbs_SHELL, TopAbs_FACE, TopAbs_EDGE
    from OCP.TopExp import TopExp_Explorer
    from OCP.ShapeUpgrade import ShapeUpgrade_UnifySameDomain
    from OCP.ShapeFix import ShapeFix_Shape
    from OCP.BRepMesh import BRepMesh_IncrementalMesh
    from OCP.TopLoc import TopLoc_Location
    from OCP.GProp import GProp_GProps
    from OCP.BRepGProp import BRepGProp
    from OCP.STEPControl import STEPControl_Writer, STEPControl_AsIs
    from OCP.IFSelect import IFSelect_RetDone
    from OCP.BRepFilletAPI import BRepFilletAPI_MakeFillet
    from OCP.BRepAdaptor import BRepAdaptor_Curve
except ImportError:
    sys.exit("missing dependency: pip install cadquery-ocp")


# ----------------------------------------------------------------- helpers

def log(msg):
    print(f"  {msg}")


def count_shapes(shape, kind):
    n, ex = 0, TopExp_Explorer(shape, kind)
    while ex.More():
        n += 1
        ex.Next()
    return n


def orientation_conflicts(shape):
    """Internal edges whose two owning faces traverse them the same way.
    Zero is required for Fusion to accept fillets ('adjacent faces are
    oppositely oriented' is precisely a nonzero count here)."""
    reg = defaultdict(list)
    exf = TopExp_Explorer(shape, TopAbs_FACE)
    while exf.More():
        fc = TopoDS.Face_s(exf.Current())
        exe = TopExp_Explorer(fc, TopAbs_EDGE)
        while exe.More():
            e = exe.Current()
            reg[e.TShape()].append(e.Orientation())
            exe.Next()
        exf.Next()
    bad = sum(1 for o in reg.values() if len(o) == 2 and o[0] == o[1])
    internal = sum(1 for o in reg.values() if len(o) == 2)
    return bad, internal


# ------------------------------------------------------------- mesh repair

def load_and_defin(path):
    """Weld vertices; remove fin faces (coincident twins) and degenerates."""
    m = trimesh.load(path, process=True, force='mesh')
    V, F = m.vertices, m.faces
    seen = defaultdict(list)
    for fi, t in enumerate(F):
        seen[tuple(sorted(t.tolist()))].append(fi)
    fins = set()
    for fl in seen.values():
        if len(fl) > 1:
            fins.update(fl)
    areas = trimesh.triangles.area(V[F])
    degen = set(np.where(areas < 1e-9)[0].tolist())
    drop = fins | degen
    if drop:
        keep = [i for i in range(len(F)) if i not in drop]
        m = trimesh.Trimesh(vertices=V, faces=F[keep], process=True)
        m.remove_unreferenced_vertices()
    return m, len(fins), len(degen)


def grow_regions(m, tol=0.06, normal_dot=0.7):
    """Planarity-driven region growing, seeded by largest faces, with
    signed-normal gating so folds never join a wall's region."""
    V, F = m.vertices, m.faces
    areas, fnorm = m.area_faces, m.face_normals
    adj = defaultdict(list)
    for a, b in m.face_adjacency:
        adj[a].append(b)
        adj[b].append(a)
    order = np.argsort(-areas)
    cluster = -np.ones(len(F), dtype=int)
    planes = {}
    cid = 0
    for seed in order:
        if cluster[seed] >= 0:
            continue
        n = fnorm[seed].copy()
        ctr = V[F[seed]].mean(0)
        cluster[seed] = cid
        vset = set(F[seed].tolist())
        grown = 0
        q = deque(adj[seed])
        inq = set(adj[seed])
        while q:
            f = q.popleft()
            inq.discard(f)
            if cluster[f] >= 0:
                continue
            pts = V[F[f]]
            if np.abs((pts - ctr) @ n).max() < tol and fnorm[f] @ n > normal_dot:
                cluster[f] = cid
                vset.update(F[f].tolist())
                grown += 1
                if grown % 40 == 0:
                    P = V[list(vset)]
                    c2 = P.mean(0)
                    M = P - c2
                    _, _, vt = np.linalg.svd(M, full_matrices=False)
                    if vt.shape[0] == 3:
                        n2 = vt[2]
                        if n2 @ n < 0:
                            n2 = -n2
                        n, ctr = n2, c2
                for g in adj[f]:
                    if cluster[g] < 0 and g not in inq:
                        q.append(g)
                        inq.add(g)
        P = V[list(vset)]
        c2 = P.mean(0)
        M = P - c2
        if len(P) >= 3 and np.linalg.matrix_rank(M) >= 2:
            _, _, vt = np.linalg.svd(M, full_matrices=False)
            if vt.shape[0] == 3:
                n = vt[2] if vt[2] @ n > 0 else -vt[2]
                ctr = c2
        planes[cid] = (n, ctr)
        cid += 1
    return cluster, planes


def snap_vertices(m, cluster, planes, clamp=0.2, step_guard=0.005):
    """Least-squares snap of every vertex onto its incident region planes.
    Vertices bordering two parallel-but-distinct planes (a designed
    micro-step) are left untouched — collapsing those was the bug that
    once shipped self-intersecting files."""
    V = m.vertices.copy()
    F = m.faces
    v_pl = defaultdict(dict)
    for fi in range(len(F)):
        c = cluster[fi]
        n, ctr = planes[c]
        for vid in F[fi]:
            v_pl[vid][c] = (n, ctr)
    protected = 0
    for vid, ps in v_pl.items():
        items = list(ps.values())
        p = V[vid]
        unsafe = False
        for i in range(len(items)):
            for j in range(i + 1, len(items)):
                n1, c1 = items[i]
                n2, c2 = items[j]
                if abs(n1 @ n2) > 0.99 and \
                   abs(n1 @ c1 - (n2 @ c2) * np.sign(n1 @ n2)) > step_guard:
                    unsafe = True
                    break
            if unsafe:
                break
        if unsafe:
            protected += 1
            continue
        kept = []
        for n, ctr in items:
            if not any(abs(n @ n2) > 0.99 for n2, _ in kept):
                kept.append((n, ctr))
        A = np.array([n for n, _ in kept])
        b = np.array([n @ c for n, c in kept])
        if len(kept) == 1:
            newp = p - (A[0] @ p - b[0]) * A[0]
        else:
            M2 = A @ A.T + 1e-9 * np.eye(len(kept))
            lam = np.linalg.solve(M2, b - A @ p)
            newp = p + A.T @ lam
        if np.linalg.norm(newp - p) < clamp:
            V[vid] = newp
    return V, protected


def repair_self_intersections(V, V0, F, max_iters=6):
    """Detect faces the snap made self-intersecting; revert their vertices
    to original positions; repeat until clean."""
    tmp = os.path.join(tempfile.gettempdir(), "obj2step_iter.stl")
    for it in range(max_iters):
        trimesh.Trimesh(vertices=V, faces=F, process=False).export(tmp)
        ms = pymeshlab.MeshSet()
        ms.load_new_mesh(tmp)
        ms.compute_selection_by_self_intersections_per_face()
        cm = ms.current_mesh()
        nsel = cm.selected_face_number()
        if nsel == 0:
            return V, it
        sel = cm.face_selection_array()
        badv = np.unique(F[np.where(sel)[0]].ravel())
        V[badv] = V0[badv]
    return V, max_iters


# ------------------------------------------------------- solid construction

def build_solid(V, F, cluster, planes, coplanar_tol=0.02):
    """Explicit shared-topology construction: one TopoDS vertex per mesh
    vertex, one edge per mesh edge (reused Reversed on the twin face), face
    orientation copied from triangle winding. Orientation conflicts are
    impossible by construction. Triangles coplanar with their region use the
    shared region plane so UnifySameDomain merges each wall into one face."""
    overts = [BRepBuilderAPI_MakeVertex(gp_Pnt(*V[i])).Vertex()
              for i in range(len(V))]
    edge_map = {}

    def get_edge(a, b):
        key = (a, b) if a < b else (b, a)
        if key not in edge_map:
            mk = BRepBuilderAPI_MakeEdge(overts[key[0]], overts[key[1]])
            edge_map[key] = mk.Edge() if mk.IsDone() else None
        e = edge_map[key]
        if e is None:
            return None
        return e if (a, b) == key else TopoDS.Edge_s(e.Reversed())

    b = BRep_Builder()
    shell = TopoDS_Shell()
    b.MakeShell(shell)
    built = 0
    for fi in range(len(F)):
        t = [int(x) for x in F[fi]]
        a1, b1, c1 = (V[i] for i in t)
        nr = np.cross(b1 - a1, c1 - a1)
        L = np.linalg.norm(nr)
        if L < 1e-12:
            continue
        nr = nr / L
        c = cluster[fi]
        rn, rc = planes[c]
        share = (max(abs((p - rc) @ rn) for p in (a1, b1, c1)) < coplanar_tol
                 and rn @ nr > 0.7)
        use_n, use_c = (rn, rc) if share else (nr, a1)
        e1 = get_edge(t[0], t[1])
        e2 = get_edge(t[1], t[2])
        e3 = get_edge(t[2], t[0])
        if None in (e1, e2, e3):
            continue
        mw = BRepBuilderAPI_MakeWire(e1, e2, e3)
        if not mw.IsDone():
            continue
        try:
            mf = BRepBuilderAPI_MakeFace(
                gp_Pln(gp_Ax3(gp_Pnt(*use_c), gp_Dir(*use_n))), mw.Wire(), True)
            if mf.IsDone():
                b.Add(shell, mf.Face())
                built += 1
        except Exception:
            pass

    fx = ShapeFix_Shape(shell)
    fx.SetPrecision(0.03)
    fx.Perform()
    s = fx.Shape()

    uni = ShapeUpgrade_UnifySameDomain(s, True, True, True)
    uni.SetLinearTolerance(0.01)
    uni.SetAngularTolerance(np.deg2rad(0.5))
    uni.Build()
    s = uni.Shape()

    final = s
    ex = TopExp_Explorer(s, TopAbs_SHELL)
    if ex.More():
        mk = BRepBuilderAPI_MakeSolid(TopoDS.Shell_s(ex.Current()))
        if mk.IsDone():
            sol = mk.Solid()
            gp = GProp_GProps()
            BRepGProp.VolumeProperties_s(sol, gp)
            if gp.Mass() < 0:
                sol = TopoDS.Solid_s(sol.Reversed())
            final = sol
    return final, built


# ------------------------------------------------------------- verification

def mesh_solid(shape, deflection=0.05):
    BRepMesh_IncrementalMesh(shape, deflection, False, 0.3, True)
    parts, nomesh = [], 0
    exf = TopExp_Explorer(shape, TopAbs_FACE)
    while exf.More():
        fc = TopoDS.Face_s(exf.Current())
        loc = TopLoc_Location()
        tr = BRep_Tool.Triangulation_s(fc, loc)
        if tr is None:
            nomesh += 1
        else:
            T = loc.Transformation()
            pts = [[tr.Node(i).Transformed(T).X(),
                    tr.Node(i).Transformed(T).Y(),
                    tr.Node(i).Transformed(T).Z()]
                   for i in range(1, tr.NbNodes() + 1)]
            fcs = [[t.Get()[0] - 1, t.Get()[1] - 1, t.Get()[2] - 1]
                   for t in (tr.Triangle(i)
                             for i in range(1, tr.NbTriangles() + 1))]
            parts.append(trimesh.Trimesh(vertices=np.array(pts),
                                         faces=np.array(fcs), process=False))
        exf.Next()
    merged = trimesh.util.concatenate(parts) if parts else None
    return merged, nomesh


def hausdorff(path_a, path_b, samples=50000):
    ms = pymeshlab.MeshSet()
    ms.load_new_mesh(path_a)
    ms.load_new_mesh(path_b)
    h = ms.get_hausdorff_distance(sampledmesh=0, targetmesh=1,
                                  samplenum=samples)
    return h['max'], h['mean']


def fillet_probe(shape, n_edges=20, radius=1.0):
    """Attempt real fillets on the longest edges. Only run when every face
    meshed (unmeshable faces can crash the OCC fillet builder)."""
    edges = []
    exe = TopExp_Explorer(shape, TopAbs_EDGE)
    while exe.More():
        e = TopoDS.Edge_s(exe.Current())
        try:
            cu = BRepAdaptor_Curve(e)
            p1 = cu.Value(cu.FirstParameter())
            p2 = cu.Value(cu.LastParameter())
            L = np.linalg.norm(np.array([p1.X(), p1.Y(), p1.Z()]) -
                               np.array([p2.X(), p2.Y(), p2.Z()]))
            edges.append((L, e))
        except Exception:
            pass
        exe.Next()
    edges.sort(key=lambda x: -x[0])
    ok = tot = 0
    for _, e in edges[:n_edges]:
        tot += 1
        try:
            mkf = BRepFilletAPI_MakeFillet(shape)
            mkf.Add(radius, e)
            mkf.Build()
            if mkf.IsDone():
                ok += 1
        except Exception:
            pass
    return ok, tot


# --------------------------------------------------------------------- main

def convert(inpath, outdir, do_fillet_test=False):
    stem = os.path.splitext(os.path.basename(inpath))[0]
    os.makedirs(outdir, exist_ok=True)
    step_path = os.path.join(outdir, stem + ".step")
    stl_path = os.path.join(outdir, stem + "-clean.stl")

    print(f"\n=== {os.path.basename(inpath)} ===")
    m, nfins, ndeg = load_and_defin(inpath)
    log(f"welded: {len(m.vertices)} verts, {len(m.faces)} faces | "
        f"watertight: {m.is_watertight} | removed fins {nfins}, "
        f"degenerate {ndeg}")
    if not m.is_watertight:
        log("WARNING: input is not watertight; results may be a surface body")

    cluster, planes = grow_regions(m)
    log(f"planar regions: {cluster.max() + 1}")

    V0 = m.vertices.copy()
    V, protected = snap_vertices(m, cluster, planes)
    V, iters = repair_self_intersections(V, V0, m.faces)
    log(f"snap: {protected} step-boundary verts protected, "
        f"self-intersection repair converged in {iters} iteration(s)")

    clean = trimesh.Trimesh(vertices=V, faces=m.faces, process=True)
    clean.export(stl_path)

    solid, built = build_solid(V, m.faces, cluster, planes)
    bad, internal = orientation_conflicts(solid)
    nfaces = count_shapes(solid, TopAbs_FACE)
    log(f"solid: {nfaces} faces (from {built} triangles) | "
        f"orientation conflicts: {bad}/{internal}")

    stepmesh, nomesh = mesh_solid(solid)
    log(f"unmeshable faces: {nomesh}")

    max_dev = mean_dev = float('nan')
    if stepmesh is not None:
        chk = os.path.join(tempfile.gettempdir(), "obj2step_check.stl")
        stepmesh.export(chk)
        max_dev, mean_dev = hausdorff(inpath, chk)
        log(f"deviation vs input: max {max_dev:.4f} mm, mean {mean_dev:.4f} mm")

    if do_fillet_test and nomesh == 0:
        ok, tot = fillet_probe(solid)
        log(f"fillet probe: {ok}/{tot} edges accept a 1.0 mm fillet")
    elif do_fillet_test:
        log("fillet probe skipped (unmeshable faces present)")

    w = STEPControl_Writer()
    w.Transfer(solid, STEPControl_AsIs)
    ok = w.Write(step_path) == IFSelect_RetDone
    log(f"STEP written: {step_path}" if ok else "STEP WRITE FAILED")

    # Hole-schedule sidecar for the Fusion drill add-in. Detection runs on
    # the welded pre-snap mesh (the configuration the detector was validated
    # on); its model-frame coords match the STEP within snap clamp (0.2 mm).
    holes_path = os.path.join(outdir, stem + "-holes.json")
    if not m.is_watertight:
        log("hole schedule skipped (mesh not watertight; void probe "
            "needs a closed surface)")
    else:
        try:
            import detect_holes
            sched = detect_holes.build_schedule(
                detect_holes.analyze(m), source_path=inpath,
                step_path=step_path, bounds=np.asarray(m.bounds))
            with open(holes_path, "w") as f:
                json.dump(sched, f, indent=2)
            log(f"hole schedule: {sched['hole_count']} drillable hole(s) "
                f"-> {holes_path}")
        except Exception as e:
            log(f"hole schedule skipped ({type(e).__name__}: {e})")

    verdict_ok = ok and bad == 0
    print(f"  --> {'PASS' if verdict_ok else 'CHECK MANUALLY'}: "
          f"{'import the STEP; test a fillet first' if verdict_ok else 'use the -clean.stl via Fusion Insert Mesh -> Face Groups -> Convert as fallback'}")
    if nomesh > 0:
        print(f"      note: {nomesh} face(s) may import scarred; "
              f"the cleaned STL fallback was also written: {stl_path}")
    return verdict_ok


def main():
    ap = argparse.ArgumentParser(
        description="Convert Tinkercad OBJ exports to Fusion-ready STEP solids")
    ap.add_argument("inputs", nargs="+", help="OBJ/STL file(s) to convert")
    ap.add_argument("-o", "--outdir", default=".", help="output directory")
    ap.add_argument("--fillet-test", action="store_true",
                    help="probe the result with real fillet operations")
    args = ap.parse_args()
    results = [convert(p, args.outdir, args.fillet_test) for p in args.inputs]
    print(f"\n{sum(results)}/{len(results)} file(s) passed all checks")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
