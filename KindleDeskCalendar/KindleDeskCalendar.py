"""Fusion 360 generator for an asymmetric Kindle 4 desk-calendar enclosure.

v0.2 — fixes after review (2026-08-25):
  * USB bay moved to the SIDE of the pocket (Kindle 4 in landscape has its
    connector edge vertical). Plug pocket + downward cable channel added.
  * Rear cover got 4 press bosses that pin the Kindle in depth (was 2.6 mm
    of rattle) and 4 M2.5 screw bosses/holes into the shell.
  * Separate flat BASE PLATE with two rails: footprint 80 mm deep instead of
    ~18 mm, kills the forward-tipping risk from the cantilevered hood.
    The shell silhouette bottom is flattened so it seats into the rail slot.
  * Light hood got 2 alignment pins (d4) + matching holes in the shell face.
  * All rectangles are now real line+arc sketches (no more wavy fitted
    splines and truncated corner arcs).
  * Fake userParameters removed: CONFIG below is the single source of truth.
    Edit CONFIG, re-run the script.

Run from Utilities > Scripts and Add-Ins. All values are millimetres.
MEASURE THE REAL DEVICE before committing to a long print — especially
kindle_*, screen_* and usb_center_y/usb_side.
"""

import adsk.core
import adsk.fusion
import math
import traceback


CONFIG = {
    # Kindle 4 (D01100) body, landscape. MEASURE YOURS.
    'kindle_width': 166.0,
    'kindle_height': 114.0,
    'kindle_depth': 8.70,
    'kindle_clearance_xy': 0.60,
    'kindle_clearance_z': 0.50,

    # Visible e-ink area. MEASURE YOURS.
    'screen_width': 121.7,
    'screen_height': 91.3,
    'screen_corner_radius': 2.0,
    'screen_center_x': 14.0,
    'screen_center_y': 4.0,

    # Main shell.
    'body_depth': 15.0,
    'front_skin': 3.2,
    'rear_cover_thickness': 2.8,
    'rear_cover_overlap': 9.0,        # was 4.0 — widened for screw rim

    # USB: which vertical side of the pocket the Kindle's connector edge
    # faces after the landscape rotation, and where along that side.
    'usb_side': 'right',              # 'right' or 'left' — check when device arrives
    'usb_center_y': 3.0,              # relative to pocket centre. MEASURE.
    'usb_bay_depth': 16.0,            # how far the bay extends past the pocket
    'usb_bay_height': 26.0,           # room for a right-angle micro-USB plug

    # Front-light hood.
    'hood_projection': 14.0,
    'diffuser_width': 132.0,
    'diffuser_height': 3.2,
    'diffuser_depth': 5.0,

    # Base plate (separate part, modelled flat at origin for printing).
    'base_length': 210.0,
    'base_depth': 80.0,
    'base_thickness': 8.0,
    'rail_height': 8.0,
    'rail_gap_extra': 0.4,            # slot = body_depth + this
}


def mm(value):
    """Fusion geometry uses centimetres internally."""
    return float(value) / 10.0


def p2(x, y):
    return adsk.core.Point3D.create(mm(x), mm(y), 0)


def bezier(p0, p1, p2v, p3, count=18):
    result = []
    for i in range(count):
        t = i / float(count)
        u = 1.0 - t
        x = u**3*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2v[0] + t**3*p3[0]
        y = u**3*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2v[1] + t**3*p3[1]
        result.append((x, y))
    return result


def outer_outline():
    """Clockwise biomorphic silhouette; bottom flattened at y=-72 between
    x=-60..70 so the shell seats into the base-plate rail slot."""
    top = bezier((-110, 58), (-84, 91), (54, 92), (122, 58), 24)
    right = bezier((122, 58), (132, 26), (130, -44), (105, -68), 18)
    entry = bezier((105, -68), (95, -71), (85, -72), (70, -72), 8)
    flat = [(x, -72.0) for x in range(60, -51, -10)]
    exit_ = bezier((-60, -72), (-80, -72), (-95, -71), (-105, -69), 8)
    left = bezier((-105, -69), (-132, -62), (-126, 34), (-110, 58), 20)
    return top + right + entry + flat + exit_ + left


def hood_outline():
    top = bezier((-111, 57), (-70, 88), (55, 91), (126, 58), 24)
    bottom = bezier((126, 58), (62, 63), (-40, 62), (-101, 52), 24)
    return top + bottom


def ellipse(cx, cy, rx, ry, segments=42):
    return [
        (cx + rx*math.cos(2*math.pi*i/segments),
         cy + ry*math.sin(2*math.pi*i/segments))
        for i in range(segments)
    ]


def make_component(parent, name):
    occ = parent.occurrences.addNewComponent(adsk.core.Matrix3D.create())
    occ.component.name = name
    return occ, occ.component


def offset_plane(component, offset_mm):
    plane_input = component.constructionPlanes.createInput()
    plane_input.setByOffset(
        component.xYConstructionPlane,
        adsk.core.ValueInput.createByString(f'{offset_mm} mm')
    )
    return component.constructionPlanes.add(plane_input)


def closed_spline_sketch(component, plane, points, name):
    sketch = component.sketches.add(plane)
    sketch.name = name
    sketch.isComputeDeferred = True
    fit_points = adsk.core.ObjectCollection.create()
    for x, y in points:
        fit_points.add(p2(x, y))
    spline = sketch.sketchCurves.sketchFittedSplines.add(fit_points)
    try:
        spline.isClosed = True
    except Exception:
        sketch.sketchCurves.sketchLines.addByTwoPoints(
            spline.endSketchPoint, spline.startSketchPoint
        )
    sketch.isComputeDeferred = False
    return sketch


def rounded_rect_sketch(component, plane, width, height, radius, cx, cy, name):
    """Rectangle from 4 lines + 4 corner fillet arcs. Straight edges stay
    straight — unlike the v0.1 fitted-spline approximation."""
    sketch = component.sketches.add(plane)
    sketch.name = name
    lines = sketch.sketchCurves.sketchLines
    rect = lines.addTwoPointRectangle(
        p2(cx - width/2.0, cy - height/2.0),
        p2(cx + width/2.0, cy + height/2.0)
    )
    radius = min(radius, width/2.0 - 0.1, height/2.0 - 0.1)
    if radius > 0.05:
        arcs = sketch.sketchCurves.sketchArcs
        segs = [rect.item(i) for i in range(rect.count)]
        for i in range(len(segs)):
            a = segs[i]
            b = segs[(i + 1) % len(segs)]
            try:
                arcs.addFillet(
                    a, a.endSketchPoint.geometry,
                    b, b.startSketchPoint.geometry,
                    mm(radius)
                )
            except Exception:
                pass
    return sketch


def circles_sketch(component, plane, holes, name):
    """holes: list of (cx, cy, diameter)."""
    sketch = component.sketches.add(plane)
    sketch.name = name
    for cx, cy, d in holes:
        sketch.sketchCurves.sketchCircles.addByCenterRadius(p2(cx, cy), mm(d/2.0))
    return sketch


def gather_profiles(sketch):
    if sketch.profiles.count < 1:
        raise RuntimeError(f'No closed profile found in sketch: {sketch.name}')
    if sketch.profiles.count == 1:
        return sketch.profiles.item(0)
    coll = adsk.core.ObjectCollection.create()
    for i in range(sketch.profiles.count):
        coll.add(sketch.profiles.item(i))
    return coll


def extrude(component, sketch, distance_expression, operation, name):
    feature_input = component.features.extrudeFeatures.createInput(
        gather_profiles(sketch), operation
    )
    feature_input.setDistanceExtent(
        False, adsk.core.ValueInput.createByString(distance_expression)
    )
    feature = component.features.extrudeFeatures.add(feature_input)
    feature.name = name
    return feature


def extrude_new(component, sketch, distance_expression, body_name):
    feature = extrude(component, sketch, distance_expression,
                      adsk.fusion.FeatureOperations.NewBodyFeatureOperation, body_name)
    feature.bodies.item(0).name = body_name
    return feature.bodies.item(0)


def extrude_cut(component, sketch, distance_expression, feature_name):
    return extrude(component, sketch, distance_expression,
                   adsk.fusion.FeatureOperations.CutFeatureOperation, feature_name)


def extrude_join(component, sketch, distance_expression, feature_name):
    return extrude(component, sketch, distance_expression,
                   adsk.fusion.FeatureOperations.JoinFeatureOperation, feature_name)


def pocket_geometry():
    c = CONFIG
    w = c['kindle_width'] + 2*c['kindle_clearance_xy']
    h = c['kindle_height'] + 2*c['kindle_clearance_xy']
    cx = c['screen_center_x'] + 2.5
    cy = c['screen_center_y'] - 1.0
    return w, h, cx, cy


def usb_bay_geometry():
    c = CONFIG
    w, h, cx, cy = pocket_geometry()
    sign = 1.0 if c['usb_side'] == 'right' else -1.0
    edge_x = cx + sign * w / 2.0
    bay_cx = edge_x + sign * c['usb_bay_depth'] / 2.0
    bay_cy = cy + c['usb_center_y']
    return sign, edge_x, bay_cx, bay_cy


def screw_positions():
    """4 screws in the rim between pocket edge and cover edge."""
    c = CONFIG
    w, h, cx, cy = pocket_geometry()
    cover_w = c['kindle_width'] + 2*c['rear_cover_overlap']
    cover_h = c['kindle_height'] + 2*c['rear_cover_overlap']
    rim_x = (w/2.0 + cover_w/2.0) / 2.0
    rim_y = (h/2.0 + cover_h/2.0) / 2.0
    sign, _, _, _ = usb_bay_geometry()
    # The screw on the USB side is shifted up so it clears the bay/notch.
    return [
        (cx, cy + rim_y),
        (cx, cy - rim_y),
        (cx - sign * rim_x, cy),
        (cx + sign * rim_x, cy + 31.0),
    ]


HOOD_PINS = [(-50.0, 75.0), (80.0, 72.0)]   # d4 pins, hood -> shell face


def build_front_shell(root):
    c = CONFIG
    _, comp = make_component(root, '01 Asymmetric Front Shell')
    base_sketch = closed_spline_sketch(
        comp, comp.xYConstructionPlane, outer_outline(), 'Outer biomorphic silhouette')
    extrude_new(comp, base_sketch, f"{c['body_depth']} mm", 'Asymmetric shell')

    screen_sketch = rounded_rect_sketch(
        comp, comp.xYConstructionPlane,
        c['screen_width'], c['screen_height'], c['screen_corner_radius'],
        c['screen_center_x'], c['screen_center_y'], 'Visible e-ink aperture')
    extrude_cut(comp, screen_sketch, f"{c['body_depth']} mm", 'Cut screen aperture')

    decor_sketch = closed_spline_sketch(
        comp, comp.xYConstructionPlane,
        ellipse(-96, -1, 16, 29), 'Asymmetric negative-space opening')
    extrude_cut(comp, decor_sketch, f"{c['body_depth']} mm", 'Cut sculptural opening')

    pw, ph, pcx, pcy = pocket_geometry()
    pocket_plane = offset_plane(comp, c['front_skin'])
    pocket_sketch = rounded_rect_sketch(
        comp, pocket_plane, pw, ph, 5.5, pcx, pcy, 'Rear-loading Kindle pocket')
    pocket_depth = c['body_depth'] - c['front_skin']
    extrude_cut(comp, pocket_sketch, f'{pocket_depth} mm', 'Cut Kindle pocket')

    # v0.2: USB plug bay on the connector side + cable channel to the bottom.
    sign, edge_x, bay_cx, bay_cy = usb_bay_geometry()
    bay_sketch = rounded_rect_sketch(
        comp, pocket_plane,
        c['usb_bay_depth'] + 2.0, c['usb_bay_height'], 3.0,
        bay_cx - sign * 1.0, bay_cy, 'USB plug bay')
    extrude_cut(comp, bay_sketch, f'{pocket_depth} mm', 'Cut USB plug bay')

    channel_cx = edge_x + sign * 7.0
    channel_sketch = rounded_rect_sketch(
        comp, pocket_plane, 10.0, 78.0, 3.0,
        channel_cx, bay_cy - 48.0, 'USB cable channel')
    extrude_cut(comp, channel_sketch, f'{pocket_depth} mm', 'Cut cable channel')

    # v0.2: pilot holes for the rear-cover screws (M2.5 into plastic, d2.2).
    pilot_plane = offset_plane(comp, c['body_depth'] + 0.25)
    pilots = [(x, y, 2.2) for x, y in screw_positions()]
    pilot_sketch = circles_sketch(comp, pilot_plane, pilots, 'Cover screw pilots')
    extrude_cut(comp, pilot_sketch, '-8 mm', 'Cut cover screw pilots')

    # v0.2: holes for the hood alignment pins (d4.4 x 6.5) in the front face.
    pin_holes = [(x, y, 4.4) for x, y in HOOD_PINS]
    pin_sketch = circles_sketch(comp, comp.xYConstructionPlane, pin_holes, 'Hood pin holes')
    extrude_cut(comp, pin_sketch, '6.5 mm', 'Cut hood pin holes')
    return comp


def build_rear_cover(root):
    c = CONFIG
    _, comp = make_component(root, '02 Rear Cover')
    z = c['body_depth'] + 0.25
    plane = offset_plane(comp, z)
    pw, ph, pcx, pcy = pocket_geometry()
    width = c['kindle_width'] + 2*c['rear_cover_overlap']
    height = c['kindle_height'] + 2*c['rear_cover_overlap']
    sketch = rounded_rect_sketch(comp, plane, width, height, 7.0, pcx, pcy, 'Rear cover outline')
    extrude_new(comp, sketch, f"{c['rear_cover_thickness']} mm", 'Rear cover')

    # v0.2: press bosses that close the depth gap and pin the Kindle.
    boss_h = z - (c['front_skin'] + c['kindle_clearance_z'] + c['kindle_depth'])
    bosses = [(pcx + dx, pcy + dy, 8.0)
              for dx in (-65.0, 65.0) for dy in (-40.0, 40.0)]
    boss_sketch = circles_sketch(comp, plane, bosses, 'Kindle press bosses')
    extrude_join(comp, boss_sketch, f'-{boss_h:.2f} mm', 'Press bosses')

    # v0.2: through holes for M2.5 screws (d2.8) into the shell pilots.
    screw_sketch = circles_sketch(
        comp, plane, [(x, y, 2.8) for x, y in screw_positions()], 'Cover screw holes')
    extrude_cut(comp, screw_sketch, f"{c['rear_cover_thickness']} mm", 'Cut screw holes')

    # v0.2: plug notch on the USB side edge (was: bottom, wrong for landscape).
    sign, edge_x, bay_cx, bay_cy = usb_bay_geometry()
    cover_edge_x = pcx + sign * width / 2.0
    notch_sketch = rounded_rect_sketch(
        comp, plane, 16.0, 18.0, 3.0, cover_edge_x, bay_cy, 'USB notch')
    extrude_cut(comp, notch_sketch, f"{c['rear_cover_thickness']} mm", 'Cut USB notch')
    return comp


def build_light_hood(root):
    c = CONFIG
    _, comp = make_component(root, '03 Front-Light Hood')
    plane = offset_plane(comp, -c['hood_projection'])
    sketch = closed_spline_sketch(comp, plane, hood_outline(), 'Cantilevered light hood')
    extrude_new(comp, sketch, f"{c['hood_projection']} mm", 'Asymmetric light hood')

    # v0.2: alignment pins (d4 x 6) on the back face, into the shell holes.
    pin_sketch = circles_sketch(
        comp, comp.xYConstructionPlane, [(x, y, 4.0) for x, y in HOOD_PINS], 'Hood pins')
    extrude_join(comp, pin_sketch, '6 mm', 'Hood pins')
    return comp


def build_diffuser(root):
    c = CONFIG
    _, comp = make_component(root, '04 Opal Diffuser')
    plane = offset_plane(comp, -c['hood_projection'] - 0.15)
    sketch = rounded_rect_sketch(
        comp, plane, c['diffuser_width'], c['diffuser_height'], 1.6,
        c['screen_center_x'],
        c['screen_center_y'] + c['screen_height']/2.0 + 7.0, 'Opal diffuser outline')
    extrude_new(comp, sketch, f"{c['diffuser_depth']} mm", 'Opal diffuser')
    return comp


def build_base_plate(root):
    """Separate part. Modelled lying flat at the origin (print orientation);
    the shell's flat bottom (130 mm wide) drops into the rail slot at assembly."""
    c = CONFIG
    _, comp = make_component(root, '06 Base Plate (print flat)')
    plate_sketch = rounded_rect_sketch(
        comp, comp.xYConstructionPlane,
        c['base_length'], c['base_depth'], 10.0, 0.0, -140.0, 'Base plate outline')
    extrude_new(comp, plate_sketch, f"{c['base_thickness']} mm", 'Base plate')

    slot = c['body_depth'] + c['rail_gap_extra']
    rail_offset = slot/2.0 + 2.5
    rail_plane = offset_plane(comp, c['base_thickness'] - 0.2)
    for i, cy in enumerate((rail_offset, -rail_offset)):
        rail_sketch = rounded_rect_sketch(
            comp, rail_plane, 170.0, 5.0, 2.0, 0.0, cy - 140.0, f'Rail {i+1}')
        extrude_join(comp, rail_sketch, f"{c['rail_height'] + 0.2} mm", f'Rail {i+1}')
    return comp


def build_kindle_fit_check(root):
    c = CONFIG
    occ, comp = make_component(root, '05 Kindle Fit Check (hidden)')
    pw, ph, pcx, pcy = pocket_geometry()
    plane = offset_plane(comp, c['front_skin'] + 0.2)
    sketch = rounded_rect_sketch(
        comp, plane, c['kindle_width'], c['kindle_height'], 5.0, pcx, pcy, 'Kindle body envelope')
    extrude_new(comp, sketch, f"{c['kindle_depth']} mm", 'Kindle envelope')
    occ.isLightBulbOn = False
    return comp


def run(context):
    ui = None
    try:
        app = adsk.core.Application.get()
        ui = app.userInterface
        app.documents.add(adsk.core.DocumentTypes.FusionDesignDocumentType)
        design = adsk.fusion.Design.cast(app.activeProduct)
        design.designType = adsk.fusion.DesignTypes.ParametricDesignType
        root = design.rootComponent
        root.name = 'Kindle 4 Desk Calendar v0.2'

        build_front_shell(root)
        build_rear_cover(root)
        build_light_hood(root)
        build_diffuser(root)
        build_kindle_fit_check(root)
        build_base_plate(root)
    except Exception:
        if ui:
            ui.messageBox('Generation failed:\n{}'.format(traceback.format_exc()))


def stop(context):
    pass
