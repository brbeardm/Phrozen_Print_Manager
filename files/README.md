# obj2step

**Convert Tinkercad OBJ exports into Fusion 360-ready STEP solids.**

Tinkercad's built-in "Send to Fusion 360" feature is unreliable — for many
users it fails on every design, even trivial ones. The manual workaround
(export OBJ, insert the mesh into Fusion, convert) frequently produces
bodies that refuse fillets with errors like *"Adjacent faces are oppositely
oriented"* or *"No target body found to cut or intersect"*, because
Tinkercad's mesh exports carry hidden defects: sliver-fan triangulation,
zero-width fin faces, boolean scar tissue, and micro-folds.

This tool repairs those defects and builds a genuine B-Rep solid, producing
a STEP file that opens in Fusion (or FreeCAD, or anything that reads STEP)
as native, filletable, sketchable geometry.

## What it does

1. **Welds** the mesh and removes fin faces (coincident duplicate triangles)
   and degenerate slivers.
2. **Detects planar regions** with planarity-driven region growing, so each
   wall of your model is recognized as one surface despite the triangle
   soup describing it.
3. **Snaps vertices** exactly onto their region planes — with step
   protection, so designed micro-steps between near-parallel surfaces are
   never collapsed.
4. **Self-heals**: any face the snap damaged is detected via
   self-intersection testing and its vertices reverted, iterating until the
   mesh is provably clean.
5. **Builds the solid with explicit shared topology**: one vertex object
   per mesh vertex, one edge object per mesh edge, face orientations copied
   directly from the mesh winding. Orientation conflicts — the cause of
   Fusion's "oppositely oriented" rejection — are impossible by
   construction, and the tool verifies the count is zero anyway.
6. **Merges** coplanar faces so each wall becomes a single face
   (8,000 triangles typically become a few hundred faces).
7. **Verifies everything**: orientation conflicts, face meshability,
   geometric deviation against your original file, and (optionally) real
   fillet operations on the result.

It also always writes a cleaned `-clean.stl` alongside the STEP, as a
fallback for Fusion's own **Insert Mesh → Generate Face Groups → Convert
Mesh** route.

### Hole-schedule sidecar

Faceted cylindrical bores (screw holes, counterbores, bosses) are detected
automatically (`detect_holes.py`) and written to a `name-holes.json` sidecar
next to the STEP — schema `obj2step-hole-schedule/1`. For each drillable
hole it records the entry point, drill direction, through/blind type, total
depth, and the diameter/depth profile from the entry face inward (so a
counterbore is two segments). Coordinates are model-frame millimetres,
identical to the STEP's frame, so a downstream tool (e.g. a Fusion add-in)
can place true cylindrical holes without any transformation. Detection is
skipped — never fatal — if the mesh isn't watertight.

`detect_holes.py` also runs standalone:

```bash
python detect_holes.py my_design.obj            # report + sidecar
python detect_holes.py my_design.obj --no-json  # report only
```

### One-click drilling in Fusion (`fusion_drill_holes.py`)

Runs **inside Fusion** and turns every faceted bore into a true cylinder by
boolean-cutting the schedule's holes (the faceted polygon is inscribed in
the fitted circle, so the cut consumes the facet slivers entirely):

1. One-time install: copy the script as
   `%APPDATA%\Autodesk\Autodesk Fusion 360\API\Scripts\fusion_drill_holes\fusion_drill_holes.py`
   — Fusion's script browser only detects the `folder\same-name.py`
   structure, not loose `.py` files, and anything in this default location
   appears in **UTILITIES → Scripts and Add-Ins** automatically (restart
   the dialog after copying). The copy in this repo is the source of
   truth; re-copy after editing it.
2. Run it, click the body, pick the `-holes.json`.

All holes land as a single Combine feature at the end of the timeline, so
one Undo reverts everything. Run it **before** moving the inserted
component (the schedule is in the STEP's own frame); fillets already in
the timeline are unaffected as long as they aren't on the faceted bore
edges themselves.

## Install

**If you already have Python** (3.10–3.12):

```bash
pip install -r requirements.txt
```

**Setting up from scratch (Windows):**

1. Install **Python 3.11 or 3.12** from [python.org](https://www.python.org/downloads/).
   During installation, **check "Add python.exe to PATH"** — this matters.
   (Avoid 3.13 for now; the CAD-kernel wheel can lag the newest Python.)
2. Open PowerShell and verify: `python --version`
3. In the folder containing this repo:
   `pip install -r requirements.txt`

macOS/Linux are the same idea: install Python 3.10–3.12 via your usual
method, then the pip line.

Expect a **large one-time download (~600 MB)** — the `cadquery-ocp`
dependency contains the complete OpenCascade CAD kernel, the same class of
engine commercial CAD runs on. No compilers or build tools are needed;
everything installs as prebuilt wheels.

## Use

```bash
python obj2step.py my_design.obj
python obj2step.py part1.obj part2.obj part3.obj -o converted --fillet-test
```

Each input produces `name.step` (primary) and `name-clean.stl` (fallback),
plus a verification report on stdout. In Fusion: **Insert → Insert CAD →
the .step file**, then test a fillet on any edge before building on it.

## Tips for best results

- **Delete text/lettering in Tinkercad before exporting.** Text objects are
  the single largest source of mesh scar tissue. Re-add lettering in Fusion
  with the native Text tool afterwards — it's parametric and cleaner anyway.
- Export from Tinkercad as **OBJ** (it preserves vertex connectivity better
  than STL).
- Keep decorative micro-features made of many small boolean shapes to a
  minimum; plain walls, holes, grooves and bosses convert perfectly.

## Known limitations

- A small number of faces may be reported *unmeshable* on models with
  severely degenerate features; these import into Fusion but may look
  scarred locally. The reported max-deviation figure can be inflated by
  such faces (the mean deviation is the reliable number).
- Curved surfaces (cylindrical bores) are represented as faceted planes —
  same as any mesh conversion. The hole-schedule sidecar tells you exactly
  where and how deep to re-drill them natively in Fusion where they matter.
- Only planar-faceted geometry is reconstructed (which is what Tinkercad
  exports). This is not a general reverse-engineering tool for 3D scans.

## Origin

Built during one very long night of converting a three-part 3D-printed
product enclosure after Tinkercad's cloud transfer failed for the
umpteenth time. Every repair stage in this tool corresponds to a real
defect found in real Tinkercad exports that night.

## License

MIT
