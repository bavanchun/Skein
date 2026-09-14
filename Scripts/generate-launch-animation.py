#!/usr/bin/env python3
"""Build Skein's thread-to-order launch animation in Blender.

Run through Blender MCP with exec(compile(path.read_text(), str(path), 'exec')).
Or: Blender --background --python Scripts/generate-launch-animation.py
The scene is saved under Design; PNG frames render to .ci-output/launch-animation.
Render with Blender --background Design/skein-launch.blend --render-anim.
Encode the frames using Scripts/encode-launch-animation.sh.
"""

import ast
import math
from pathlib import Path

import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / ".ci-output" / "launch-animation"
DESIGN = ROOT / "Design"
OUTPUT.mkdir(parents=True, exist_ok=True)
DESIGN.mkdir(exist_ok=True)

# Load only the original geometry definitions: no Pillow or icon exports inside Blender.
geometry_names = {
    "CANVAS", "CX", "CY", "OUTER_HALF_W", "OUTER_HALF_H", "STRANDS",
    "PITCH", "TUBE", "SAMPLES", "BUNDLE_REACH", "XH", "YH", "BASE", "NORMALS",
}
source = ast.parse((ROOT / "Scripts" / "generate-icon-artwork.py").read_text())
nodes = []
for node in source.body:
    if isinstance(node, ast.FunctionDef) and node.name in {"unit", "centreline", "normals"}:
        nodes.append(node)
    elif isinstance(node, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id in geometry_names for target in node.targets
    ):
        nodes.append(node)
geometry = {"math": math}
exec(compile(ast.Module(body=nodes, type_ignores=[]), "icon-geometry", "exec"), geometry)

previous = bpy.data.scenes.get("Skein Launch")
if previous is not None:
    for obj in list(previous.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    bpy.data.scenes.remove(previous)
scene = bpy.data.scenes.new("Skein Launch")
bpy.context.window.scene = scene
scene.render.engine = "BLENDER_EEVEE"
scene.eevee.taa_render_samples = 128
scene.render.resolution_x = 720
scene.render.resolution_y = 720
scene.render.resolution_percentage = 100
scene.render.fps = 60
scene.frame_start = 1
scene.frame_end = 150
for name, frame in (("Clutter", 1), ("Gather", 24), ("Order", 44), ("Weave", 68), ("Resolve", 104), ("Menu bar handoff", 150)):
    scene.timeline_markers.new(name, frame=frame)
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGB"
scene.render.filepath = "//../.ci-output/launch-animation/frame-"
scene.view_settings.view_transform = "AgX"
scene.view_settings.look = "AgX - Medium High Contrast"
scene.view_settings.exposure = 0
scene.render.film_transparent = False
scene.world = bpy.data.worlds.new("Skein Studio")
scene.world.use_nodes = True
scene.world.node_tree.nodes["Background"].inputs[0].default_value = (0.22, 0.20, 0.18, 1)
scene.world.node_tree.nodes["Background"].inputs[1].default_value = 0.4


def material(name, color, metal=0.0, roughness=0.35):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*color, 1)
    mat.use_nodes = True
    shader = mat.node_tree.nodes["Principled BSDF"]
    shader.inputs["Base Color"].default_value = (*color, 1)
    shader.inputs["Metallic"].default_value = metal
    shader.inputs["Roughness"].default_value = roughness
    return mat


def linear_hex(value):
    channels = [int(value[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels)


# Related gold tones, from shaded honey to champagne; highlights unify the bundle.
cord_materials = [
    material(name, linear_hex(color), 0.88, roughness)
    for name, color, roughness in (
        ("Honey gold", "C69045", 0.20),
        ("Champagne satin", "E8C47F", 0.17),
        ("Ivory gold", "FFF0CB", 0.16),
        ("Warm brushed gold", "DDA956", 0.19),
    )
]
ground = material("Obsidian stage", (0.005, 0.005, 0.006), 0, 1)
nodes = ground.node_tree.nodes
nodes.clear()
position = nodes.new("ShaderNodeNewGeometry")
distance = nodes.new("ShaderNodeVectorMath")
distance.operation = "DISTANCE"
distance.inputs[1].default_value = (0, 0.5, -0.3)
mapping = nodes.new("ShaderNodeMapRange")
mapping.inputs["From Max"].default_value = 5.5
ramp = nodes.new("ShaderNodeValToRGB")
ramp.color_ramp.elements[0].color = (0.018, 0.015, 0.012, 1)
ramp.color_ramp.elements[1].color = (0.003, 0.003, 0.004, 1)
emission = nodes.new("ShaderNodeEmission")
output = nodes.new("ShaderNodeOutputMaterial")
links = ground.node_tree.links
links.new(position.outputs["Position"], distance.inputs[0])
links.new(distance.outputs["Value"], mapping.inputs["Value"])
links.new(mapping.outputs["Result"], ramp.inputs[0])
links.new(ramp.outputs["Color"], emission.inputs["Color"])
links.new(emission.outputs[0], output.inputs["Surface"])

bpy.ops.mesh.primitive_plane_add(size=200, location=(0, 0, -0.3))
bpy.context.object.name = "Matte background"
bpy.context.object.data.materials.append(ground)

rig = bpy.data.objects.new("Logo motion", None)
scene.collection.objects.link(rig)
rig.location.y = 0.6

scale = 0.0048
cords = []
for strand in range(geometry["STRANDS"]):
    curve = bpy.data.curves.new(f"Cord {strand + 1}", "CURVE")
    curve.dimensions = "3D"
    curve.resolution_u = 2
    curve.bevel_depth = geometry["TUBE"] * scale / 2 * 0.91
    curve.bevel_resolution = 6
    curve.use_fill_caps = True
    spline = curve.splines.new("POLY")
    spline.points.add(geometry["SAMPLES"])
    offset = (strand - (geometry["STRANDS"] - 1) / 2) * geometry["PITCH"]
    for i, point in enumerate(spline.points):
        direction = 1 if strand % 2 == 0 else -1
        index = (geometry["SAMPLES"] * 3 // 4 + direction * i) % geometry["SAMPLES"]
        px, py = geometry["BASE"][index]
        nx, ny = geometry["NORMALS"][index]
        t = index / geometry["SAMPLES"] * 2 * math.pi
        point.co = (
            (px + nx * offset - geometry["CX"]) * scale,
            -(py + ny * offset - geometry["CY"]) * scale,
            0.35 - 0.23 * math.sin(t), 1,
        )
    obj = bpy.data.objects.new(f"Cord {strand + 1}", curve)
    scene.collection.objects.link(obj)
    obj.parent = rig
    curve.materials.append(cord_materials[strand])
    # Ordered strands become the exact icon; the additive scatter key is relative
    # to the line so collecting and weaving can overlap without double deformation.
    basis = obj.shape_key_add(name="Infinity")
    line = obj.shape_key_add(name="Ordered strands")
    loose = obj.shape_key_add(name="Scattered strands")
    loose.relative_key = line
    for i, point in enumerate(line.data):
        progress = i / geometry["SAMPLES"]
        x = (progress * 2 - 1) * 2.30 * (1 if strand % 2 == 0 else -1)
        y = (strand - 1.5) * 0.14 - 0.15
        point.co = (x, y, 0.4)
        loose.data[i].co = (
            x, y + 0.43 * math.sin(progress * math.tau + strand * 1.8)
            + 0.13 * math.sin(progress * math.tau * 3 + strand),
            0.4 + strand * 0.045,
        )
    for frame, value in ((1, 1), (8, 1), (44, 0), (150, 0)):
        loose.value = value
        loose.keyframe_insert(data_path="value", frame=frame)
    for frame, value in ((1, 1), (46, 1), (104, 0), (150, 0)):
        line.value = value
        line.keyframe_insert(data_path="value", frame=frame)
    delay = strand * 2
    for frame, value in ((1, 0.22), (36 + delay, 1), (150, 1)):
        curve.bevel_factor_end = value
        curve.keyframe_insert(data_path="bevel_factor_end", frame=frame)
    cords.append(obj)

# Keep the camera frontal: the change from disorder to order carries the motion.
rig.location.y = 0.6

# Rounded thread ends follow the actual animated spline during the reveal.
for cord in cords:
    for at_end in (False, True):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=12, radius=1)
        tip = bpy.context.object
        tip.name = f"{cord.name} {'leading' if at_end else 'trailing'} tip"
        tip.parent = rig
        tip.data.materials.append(cord.data.materials[0])
        for polygon in tip.data.polygons:
            polygon.use_smooth = True
        basis = cord.data.shape_keys.key_blocks["Infinity"]
        line = cord.data.shape_keys.key_blocks["Ordered strands"]
        loose = cord.data.shape_keys.key_blocks["Scattered strands"]
        for frame in range(1, 151):
            scene.frame_set(frame)
            progress = cord.data.bevel_factor_end
            index = progress * geometry["SAMPLES"] if at_end else 0
            lo = min(int(index), geometry["SAMPLES"] - 1)
            frac = index - lo
            def position(index):
                base = basis.data[index].co
                ordered = line.data[index].co
                scattered = loose.data[index].co
                return base.lerp(ordered, line.value) + (scattered - ordered) * loose.value
            a, b = position(lo), position(lo + 1)
            tip.location = a.lerp(b, frac)
            tip.scale = (cord.data.bevel_depth if progress < 0.999 or line.value > 0.001 else 0.001,) * 3
            tip.keyframe_insert(data_path="location", frame=frame)
            tip.keyframe_insert(data_path="scale", frame=frame)


def stroke(parent, name, points, mat, width=0.018):
    curve = bpy.data.curves.new(name, "CURVE")
    curve.dimensions = "3D"
    curve.bevel_depth = width
    curve.bevel_resolution = 3
    curve.use_fill_caps = True
    spline = curve.splines.new("POLY")
    spline.points.add(len(points) - 1)
    for point, (x, y) in zip(spline.points, points):
        point.co = (x, y, 0, 1)
    obj = bpy.data.objects.new(name, curve)
    scene.collection.objects.link(obj)
    obj.parent = parent
    curve.materials.append(mat)
    return obj


# Four illustrative menu-bar glyphs begin crowded and uneven. A common baseline
# and measured spacing appear as the threads straighten; the glyphs then recede.
glyph_ink = material("Menu glyph ivory", linear_hex("CEC9BB"), 0, 0.8)
for index in range(4):
    glyph = bpy.data.objects.new(f"Menu glyph {index + 1}", None)
    scene.collection.objects.link(glyph)
    paths = []
    if index == 0:  # Connection
        for radius in (0.11, 0.23, 0.35):
            paths.append([(radius * math.cos(t), radius * math.sin(t) - 0.13)
                          for t in [math.pi / 4 + j / 24 * math.pi / 2 for j in range(25)]])
    elif index == 1:  # Control sliders
        for y, x in ((0.16, -0.12), (-0.16, 0.12)):
            paths.extend([[(-0.29, y), (0.29, y)], [(x, y - 0.08), (x, y + 0.08)]])
    elif index == 2:  # Focus / sun
        paths.append([(0.16 * math.cos(j / 40 * math.tau), 0.16 * math.sin(j / 40 * math.tau)) for j in range(41)])
        for j in range(8):
            t = j / 8 * math.tau
            paths.append([(r * math.cos(t), r * math.sin(t)) for r in (0.24, 0.31)])
    else:  # Power
        paths.extend([[(-0.29, -0.14), (0.22, -0.14), (0.22, 0.14), (-0.29, 0.14), (-0.29, -0.14)],
                      [(0.28, -0.055), (0.28, 0.055)], [(-0.20, 0), (0.09, 0)]])
    for part, points in enumerate(paths):
        stroke(glyph, f"Glyph {index + 1} stroke {part + 1}", points, glyph_ink)
    for frame, x, y, angle, size in (
        (1, (-0.98, -0.30, 0.34, 0.97)[index], (1.48, 1.10, 1.54, 1.12)[index], (16, -12, 13, -16)[index], 0.90),
        (8, (-0.98, -0.30, 0.34, 0.97)[index], (1.48, 1.10, 1.54, 1.12)[index], (16, -12, 13, -16)[index], 0.90),
        (42, (index - 1.5) * 1.12, 1.40, 0, 0.90),
        (52, (index - 1.5) * 1.12, 1.40, 0, 0.90),
        (77, (index - 1.5) * 0.60, 0.63, 0, 0.001),
        (150, (index - 1.5) * 0.60, 0.63, 0, 0.001),
    ):
        glyph.location = (x, y, 0.85)
        glyph.rotation_euler.z = math.radians(angle)
        glyph.scale = (size,) * 3
        glyph.keyframe_insert(data_path="location", frame=frame)
        glyph.keyframe_insert(data_path="rotation_euler", frame=frame)
        glyph.keyframe_insert(data_path="scale", frame=frame)


def text_object(name, body, y, size, mat):
    curve = bpy.data.curves.new(name, "FONT")
    curve.body = body
    curve.align_x = "CENTER"
    curve.size = size
    curve.offset = 0.005
    curve.space_character = 1.10
    curve.font = bpy.data.fonts.load("/System/Library/Fonts/SFNS.ttf")
    obj = bpy.data.objects.new(name, curve)
    scene.collection.objects.link(obj)
    obj.location = (0, y, 0)
    curve.materials.append(mat)
    # Store the wordmark as geometry so the .blend does not redistribute a system font.
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.convert(target="MESH")
    obj = bpy.context.object
    obj.select_set(False)
    return obj


ink = bpy.data.materials.new("Ivory wordmark")
ink.use_nodes = True
ink.node_tree.nodes.clear()
emission = ink.node_tree.nodes.new("ShaderNodeEmission")
output = ink.node_tree.nodes.new("ShaderNodeOutputMaterial")
ink.node_tree.links.new(emission.outputs[0], output.inputs["Surface"])
for frame, color in ((1, (0.011, 0.010, 0.009, 1)), (90, (0.011, 0.010, 0.009, 1)), (120, (0.80, 0.75, 0.65, 1)), (150, (0.80, 0.75, 0.65, 1))):
    emission.inputs["Color"].default_value = color
    emission.inputs["Color"].keyframe_insert(data_path="default_value", frame=frame)
wordmark = text_object("Skein wordmark", "Skein", -1.64, 0.62, ink)
for frame, y in ((1, -1.78), (90, -1.78), (120, -1.64), (150, -1.64)):
    wordmark.location.y = y
    wordmark.keyframe_insert(data_path="location", frame=frame)


# Small jewelry-like glints reward the moment the weave resolves. They occupy
# only the thread surface; staggered envelopes avoid a whole-screen flash.
glint_ink = bpy.data.materials.new("Champagne glint")
glint_ink.use_nodes = True
glint_ink.node_tree.nodes.clear()
shine = glint_ink.node_tree.nodes.new("ShaderNodeEmission")
shine.inputs["Color"].default_value = (1, 0.94, 0.77, 1)
shine.inputs["Strength"].default_value = 5
shine_output = glint_ink.node_tree.nodes.new("ShaderNodeOutputMaterial")
glint_ink.node_tree.links.new(shine.outputs[0], shine_output.inputs["Surface"])
for name, position, radius, envelope in (
    ("Left glint", (-1.78, 1.02, 1.1), 0.16, ((1, 0), (94, 0), (105, 0.85), (118, 0), (150, 0))),
    ("Crown glint", (1.12, 1.58, 1.1), 0.23, ((1, 0), (107, 0), (120, 1), (134, 0.18), (144, 0.72), (150, 0.48))),
    ("Lower glint", (1.75, -0.17, 1.1), 0.13, ((1, 0), (121, 0), (134, 0.80), (148, 0), (150, 0))),
):
    inset = radius * 0.10
    vertices = [(0, radius * 1.25, 0), (inset, inset, 0), (radius, 0, 0),
                (inset, -inset, 0), (0, -radius * 1.25, 0), (-inset, -inset, 0),
                (-radius, 0, 0), (-inset, inset, 0)]
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], [tuple(range(8))])
    glint = bpy.data.objects.new(name, mesh)
    scene.collection.objects.link(glint)
    glint.location = position
    mesh.materials.append(glint_ink)
    for frame, size in envelope:
        glint.scale = (size,) * 3
        glint.rotation_euler.z = math.radians(-8 + size * 14)
        glint.keyframe_insert(data_path="scale", frame=frame)
        glint.keyframe_insert(data_path="rotation_euler", frame=frame)


def area_light(name, position, energy, size, color):
    data = bpy.data.lights.new(name, "AREA")
    data.energy, data.shape, data.size, data.color = energy, "DISK", size, color
    obj = bpy.data.objects.new(name, data)
    scene.collection.objects.link(obj)
    obj.location = position
    obj.rotation_euler = (Vector((0, 0.5, 0)) - obj.location).to_track_quat("-Z", "Y").to_euler()
    return obj


key = area_light("Champagne softbox", (-3.5, 4, 6), 850, 3.5, (1, 0.94, 0.82))
area_light("Ivory rim", (3.5, 2, 4), 1000, 2.5, (0.92, 0.96, 1))
area_light("Broad front fill", (0, -3, 7), 500, 5, (1, 0.93, 0.81))
for frame, x in ((1, -3.5), (84, -3.5), (126, 1.5), (150, 1.5)):
    key.location.x = x
    key.rotation_euler = (Vector((0, 0.5, 0)) - key.location).to_track_quat("-Z", "Y").to_euler()
    key.keyframe_insert(data_path="location", frame=frame)
    key.keyframe_insert(data_path="rotation_euler", frame=frame)
camera = bpy.data.objects.new("Launch camera", bpy.data.cameras.new("Launch camera"))
scene.collection.objects.link(camera)
camera.location = (0, 0, 12)
camera.data.type = "ORTHO"
camera.data.ortho_scale = 7.4
scene.camera = camera
scene.frame_set(150)
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type == "VIEW_3D":
            area.spaces.active.region_3d.view_perspective = "CAMERA"
save_version = bpy.context.preferences.filepaths.save_version
try:
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(DESIGN / "skein-launch.blend"))
finally:
    bpy.context.preferences.filepaths.save_version = save_version
print(f"Skein launch scene saved: {DESIGN / 'skein-launch.blend'}")

# Render once with only the mark visible for the native menu-bar handoff. This
# uses the same camera and lighting as the movie, so swapping layers has no jump.
scene.render.film_transparent = True
scene.render.image_settings.color_mode = "RGBA"
scene.objects["Matte background"].hide_render = True
wordmark.hide_render = True
scene.render.filepath = str(ROOT / "Skein" / "Resources" / "skein-launch-mark.png")
bpy.ops.render.render(write_still=True)
scene.objects["Matte background"].hide_render = False
wordmark.hide_render = False
scene.render.film_transparent = False
scene.render.image_settings.color_mode = "RGB"
scene.render.filepath = "//../.ci-output/launch-animation/frame-"
