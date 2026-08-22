"""Fusion 360 script: drill true cylindrical holes from an obj2step
hole-schedule sidecar (<part>-holes.json, schema obj2step-hole-schedule/1).

The obj2step STEP deliberately keeps bores as faceted planes — rebuilding
analytic cylinders inside the solid is what used to reintroduce orientation
conflicts. This script instead boolean-cuts true cylinders at the scheduled
positions, which removes the facet slivers (the faceted polygon is inscribed
in the fitted circle, so a cut at the fitted diameter consumes it entirely)
and leaves native, filletable cylindrical faces.

Install (one time):
  Fusion -> UTILITIES -> ADD-INS (Scripts and Add-Ins, Shift+S)
  -> Scripts tab -> "+" next to "My Scripts" -> pick this file.

Run:
  Run the script, click the body to drill, pick the -holes.json.
  Every hole is cut as one Combine feature at the end of the timeline,
  so a single Undo removes them all.

Coordinate caveat: the sidecar is in the STEP's own model frame. Run this
BEFORE moving/rotating the inserted component (Insert CAD places it at the
model frame by default). One level of occurrence transform is compensated;
if you already repositioned a nested assembly, undo the move, drill, redo.
"""

import json
import traceback

import adsk.core
import adsk.fusion

ENTRY_OVERCUT_MM = 1.0    # start each cut this far above the entry face
THROUGH_OVERCUT_MM = 1.0  # extend a through hole this far past the exit face
# The fitted circle passes exactly through the facet vertices and segment
# floors land exactly on the faceted cap planes — exact coincidence makes
# the boolean kernel fail (ASM_EDGECOIN_PROBLEM). A little slop guarantees
# clear overlap; 0.05 mm is far below resin-print tolerance.
RADIAL_SLOP_MM = 0.05     # enlarge every radius by this much
END_SLOP_MM = 0.05        # cut this far past each segment floor

MM = 0.1  # Fusion API length unit is cm


def run(context):
    ui = None
    try:
        app = adsk.core.Application.get()
        ui = app.userInterface
        design = adsk.fusion.Design.cast(app.activeProduct)
        if not design:
            ui.messageBox('Open a design first.')
            return

        # body to drill: pre-selected > the only visible solid > prompt
        body = None
        for i in range(ui.activeSelections.count):
            body = adsk.fusion.BRepBody.cast(
                ui.activeSelections.item(i).entity)
            if body:
                break
        if not body:
            candidates = []
            root = design.rootComponent
            for b in root.bRepBodies:
                if b.isSolid and b.isVisible:
                    candidates.append(b)
            for o in root.allOccurrences:
                for b in o.bRepBodies:
                    if b.isSolid and b.isVisible:
                        candidates.append(b)
            if len(candidates) == 1:
                body = candidates[0]
            elif not candidates:
                ui.messageBox('No visible solid body found in this design.')
                return
        if not body:
            try:
                sel = ui.selectEntity('Select the body to drill', 'Bodies')
                body = adsk.fusion.BRepBody.cast(sel.entity)
            except Exception:
                ui.messageBox('Body selection was cancelled — nothing done.\n'
                              '(Tip: select the body first, then run the '
                              'script.)')
                return
        if not body:
            ui.messageBox('Selected entity is not a body — nothing done.')
            return

        dlg = ui.createFileDialog()
        dlg.title = 'Select the hole schedule (…-holes.json)'
        dlg.filter = 'Hole schedule (*.json);;All files (*.*)'
        if dlg.showOpen() != adsk.core.DialogResults.DialogOK:
            return
        with open(dlg.filename, 'rb') as f:
            raw = f.read()
        if raw[:2] in (b'\xff\xfe', b'\xfe\xff'):
            text = raw.decode('utf-16')
        else:
            text = raw.decode('utf-8-sig', errors='replace')
        try:
            sched = json.loads(text)
        except ValueError as e:
            ui.messageBox(
                'That file is not valid JSON.\n\n'
                'File: {}\nSize: {} bytes\nStarts with: {!r}\n\nError: {}\n\n'
                'Expected the -holes.json sidecar written next to the STEP '
                'by obj2step.'.format(
                    dlg.filename, len(raw), raw[:60], e))
            return
        if sched.get('schema') != 'obj2step-hole-schedule/1':
            if ui.messageBox(
                    'File does not declare schema obj2step-hole-schedule/1.'
                    '\nTry anyway?', 'Hole schedule',
                    adsk.core.MessageBoxButtonTypes.YesNoButtonType) != \
                    adsk.core.DialogResults.DialogYes:
                return
        holes = sched.get('holes', [])
        if not holes:
            ui.messageBox('Schedule contains no drillable holes.')
            return

        ids_txt, cancelled = ui.inputBox(
            'Hole ids to drill (e.g. "7" or "1,2,3"), or "all":',
            'fusion_drill_holes', 'all')
        if cancelled:
            return
        if ids_txt.strip().lower() not in ('', 'all'):
            try:
                want = {int(x) for x in ids_txt.replace(',', ' ').split()}
            except ValueError:
                ui.messageBox('Could not parse ids: {!r}'.format(ids_txt))
                return
            holes = [h for h in holes if h['id'] in want]
            if not holes:
                ui.messageBox('No schedule holes match ids {}.'.format(
                    sorted(want)))
                return

        # If the body lives in an occurrence, cut on the native body and
        # map the schedule (model-frame) coordinates into component space.
        occ = body.assemblyContext
        native = body.nativeObject if occ else body
        comp = native.parentComponent
        inv = None
        if occ:
            inv = occ.transform2.copy()
            inv.invert()

        tmp = adsk.fusion.TemporaryBRepManager.get()
        parametric = (design.designType ==
                      adsk.fusion.DesignTypes.ParametricDesignType)
        combines = comp.features.combineFeatures
        def cut_hole(h, radial_slop):
            """Build this hole's tool cylinders and cut them. Raises on
            kernel failure after cleaning up its own base feature."""
            dx, dy, dz = h['direction']

            # each segment is cut from just above the entry face down to its
            # cumulative depth: the smaller lower segment passes harmlessly
            # through the void of the larger one above it. Segments carry
            # their own fitted axis position when the schedule provides it
            # (counterbores are not always coaxial with their bore).
            cyls = []
            cum = 0.0
            for i, seg in enumerate(h['segments']):
                ex, ey, ez = seg.get('entry', h['entry'])

                def pt(t_mm, ex=ex, ey=ey, ez=ez):
                    return adsk.core.Point3D.create(
                        (ex + dx * t_mm) * MM,
                        (ey + dy * t_mm) * MM,
                        (ez + dz * t_mm) * MM)

                r = (seg['diameter'] / 2.0 + radial_slop) * MM
                if h['type'] == 'through' and i == len(h['segments']) - 1:
                    end = cum + seg['depth'] + THROUGH_OVERCUT_MM
                else:
                    end = cum + seg['depth'] + END_SLOP_MM
                cyl = tmp.createCylinderOrCone(
                    pt(-ENTRY_OVERCUT_MM), r, pt(end), r)
                if inv:
                    tmp.transform(cyl, inv)
                cyls.append(cyl)
                cum += seg['depth']

            base = None
            try:
                tool_bodies = adsk.core.ObjectCollection.create()
                if parametric:
                    base = comp.features.baseFeatures.add()
                    base.startEdit()
                    for c in cyls:
                        comp.bRepBodies.add(c, base)
                    base.finishEdit()
                    # bodies returned during the edit go stale after
                    # finishEdit(); re-fetch the persisted ones
                    for i in range(base.bodies.count):
                        tool_bodies.add(base.bodies.item(i))
                else:
                    for c in cyls:
                        tool_bodies.add(comp.bRepBodies.add(c))
                ci = combines.createInput(native, tool_bodies)
                ci.operation = \
                    adsk.fusion.FeatureOperations.CutFeatureOperation
                ci.isKeepToolBodies = False
                combines.add(ci)
            except Exception:
                if base:
                    try:
                        base.deleteMe()
                    except Exception:
                        pass
                raise

        def add_manual_sketch(h):
            """Fallback for a hole the kernel refuses to cut: a sketch on
            the entry plane with a circle per segment at the exact fitted
            center and diameter — finishing the hole manually is then just
            select circle -> Extrude -> Cut to the reported depth."""
            iax = max(range(3), key=lambda i: abs(h['direction'][i]))
            basep = [comp.yZConstructionPlane, comp.xZConstructionPlane,
                     comp.xYConstructionPlane][iax]
            p0 = adsk.core.Point3D.create(*[c * MM for c in h['entry']])
            if inv:
                p0.transformBy(inv)
            off = (p0.x, p0.y, p0.z)[iax]
            pin = comp.constructionPlanes.createInput()
            pin.setByOffset(basep, adsk.core.ValueInput.createByReal(off))
            plane = comp.constructionPlanes.add(pin)
            sk = comp.sketches.add(plane)
            sk.name = 'manual drill: hole {}'.format(h['id'])
            specs = []
            cum = 0.0
            for i, seg in enumerate(h['segments']):
                sx, sy, sz = seg.get('entry', h['entry'])
                p = adsk.core.Point3D.create(sx * MM, sy * MM, sz * MM)
                if inv:
                    p.transformBy(inv)
                sp = sk.modelToSketchSpace(p)
                sp.z = 0
                r = (seg['diameter'] / 2.0 + RADIAL_SLOP_MM) * MM
                sk.sketchCurves.sketchCircles.addByCenterRadius(sp, r)
                if h['type'] == 'through' and i == len(h['segments']) - 1:
                    depth = cum + seg['depth'] + THROUGH_OVERCUT_MM
                else:
                    depth = cum + seg['depth'] + END_SLOP_MM
                specs.append('D{:.2f} circle -> cut {:.2f} mm'.format(
                    seg['diameter'] + 2 * RADIAL_SLOP_MM, depth))
                cum += seg['depth']
            return specs

        # per-hole slop escalation: facet vertices can scatter past the
        # fitted radius (near-coincident with the cut wall), which fails the
        # boolean — retry just that hole a hair larger until the kernel is
        # happy, leaving well-behaved holes at the base slop
        drilled, failed = [], []
        for h in holes:
            for slop in (RADIAL_SLOP_MM, 0.10, 0.15, 0.20):
                try:
                    cut_hole(h, slop)
                    drilled.append((h['id'], slop))
                    break
                except Exception:
                    continue
            else:
                failed.append(h)

        note = ''
        enlarged = [(i, s) for i, s in drilled if s > RADIAL_SLOP_MM]
        if enlarged:
            note = '\n\nNeeded extra radial slop: ' + ', '.join(
                'id {} (+{:.2f} mm)'.format(i, s) for i, s in enlarged)
        if failed:
            flines = []
            for h in failed:
                try:
                    specs = add_manual_sketch(h)
                    flines.append(
                        '  id {}: sketch "manual drill: hole {}" added on '
                        'the entry face — {}'.format(
                            h['id'], h['id'], '; '.join(specs)))
                except Exception:
                    flines.append(
                        '  id {}  {}  at ({:.2f}, {:.2f}, {:.2f}) — sketch '
                        'fallback also failed, cut manually'.format(
                            h['id'], h['type'], *h['entry']))
            ui.messageBox(
                'Drilled {} of {} hole(s).{}\n\nCould not cut (kernel '
                'refused even at +0.20 mm slop) — manual-drill sketch '
                'fallback:\n{}\n\nFor each circle: select its profile, '
                'Extrude, Cut, to the stated depth (into the part).'.format(
                    len(drilled), len(holes), note, '\n'.join(flines)))
        else:
            ui.messageBox(
                'Drilled all {} hole(s) from:\n{}\n\nFaceted bore walls are '
                'now true cylinders.{}'.format(
                    len(drilled), dlg.filename, note))
    except Exception:
        if ui:
            ui.messageBox('Drill failed:\n' + traceback.format_exc())
