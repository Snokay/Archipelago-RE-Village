"""
Script Blender (sans fenêtre) : convertit un modèle FBX en .mesh RE Village pour l'objet porteur
Archipelago, par GREFFE sur le maillage du flacon (it04_000_AntisepticSolution_Medium).

Lancé par tools/re_engine/make_ap_model.py :
  blender.exe --background --python blender_make_ap_mesh.py -- MODELE.fbx DONNEUR.mesh SORTIE.mesh MATERIAU

Historique (tests en jeu du 2026-09-26) : un .mesh construit de zéro (collection neuve, un seul
jeu d'UV, puis avec squelette) s'affichait en damier, même avec le matériau d'origine, alors que
le flacon importé puis réexporté par RE Mesh Editor s'affichait parfaitement. On part donc du
flacon : on ne garde que le morceau qui porte MATERIAU (le bouchon, Cap_Mat) avec son nom, son
matériau, son squelette et ses poids, et on remplace seulement sa géométrie par le modèle.
Taille : 0,08 (plus grande dimension), réglée en jeu par le joueur.
"""

import os
import sys

import addon_utils
import bpy
import mathutils

args = sys.argv[sys.argv.index("--") + 1:]
fbx_path, donor_mesh, out_mesh, material_name = args[:4]
TARGET_SIZE = 0.08

# Addon installé dans <blender>/4.3/scripts/addons/RE_Mesh_Editor : Blender 4.3 portable ne lit plus
# ce dossier tout seul, on l'ajoute au chemin Python avant de l'activer.
ADDONS_DIR = os.path.join(os.path.dirname(bpy.app.binary_path), "4.3", "scripts", "addons")
if ADDONS_DIR not in sys.path:
    sys.path.append(ADDONS_DIR)
addon_utils.enable("RE_Mesh_Editor", default_set=True)
# Sans fenêtre, l'addon planterait Blender en ouvrant la console Windows (wm.console_toggle).
bpy.context.preferences.addons["RE_Mesh_Editor"].preferences.showConsole = False


def mesh_objects():
    return [o for o in bpy.context.scene.objects if o.type == "MESH"]


# 1. Flacon : on ne garde que le morceau au matériau voulu.
d, f = os.path.split(donor_mesh)
bpy.ops.re_mesh.importfile(filepath=donor_mesh, files=[{"name": f}], directory=d + "/", loadMDFData=False)
mesh_collection = next(c for c in bpy.data.collections if c.name.endswith(".mesh"))
# Les autres morceaux sont gardés (liste de matériaux identique au flacon, dans le même ordre)
# mais réduits à un point, donc invisibles.
keep = None
for obj in mesh_collection.all_objects:
    if obj.type == "MESH" and obj.name.endswith("__" + material_name) and keep is None:
        keep = obj
# Centre du flacon entier (monde) : la boutique cadre la vue sur l'objet complet. Le modèle y est
# placé (au centre du bouchon, il était décentré, 2026-09-26) et les autres morceaux y sont
# réduits, pour ne pas décaler le cadrage.
# Centre des VRAIS morceaux du flacon (collection .mesh) : la scène Blender par défaut contient un
# cube de 2 x 2 x 2 qui faussait la taille ("2,0") et le centre. Le flacon va de z = 0 à 0,126 :
# à l'origine, le modèle était au pied du flacon, décalé dans la boutique (2026-09-26).
donor_parts = [o for o in mesh_collection.all_objects if o.type == "MESH"]
corners = [o.matrix_world @ mathutils.Vector(c) for o in donor_parts for c in o.bound_box]
center_world = mathutils.Vector([(min(p[i] for p in corners) + max(p[i] for p in corners)) / 2 for i in range(3)])
print(f"GREFFE centre du flacon : {[round(x, 4) for x in center_world]}")
for obj in donor_parts:
    if obj is not keep:
        local_center = obj.matrix_world.inverted() @ center_world
        for v in obj.data.vertices:
            v.co = local_center
print(f"GREFFE morceau gardé : {keep.name}, groupes de sommets {[g.name for g in keep.vertex_groups]}")
bone = keep.vertex_groups[0].name if keep.vertex_groups else "_00"

# 2. Modèle : fusion, échelle, centré sur le morceau d'origine, second jeu d'UV.
before = set(bpy.data.objects)
bpy.ops.import_scene.fbx(filepath=fbx_path)
imported = [o for o in set(bpy.data.objects) - before if o.type == "MESH"]
bpy.ops.object.select_all(action="DESELECT")
for obj in imported:
    obj.select_set(True)
bpy.context.view_layer.objects.active = imported[0]
if len(imported) > 1:
    bpy.ops.object.join()
model = bpy.context.view_layer.objects.active
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
points = [mathutils.Vector(v.co) for v in model.data.vertices]
lo = mathutils.Vector([min(p[i] for p in points) for i in range(3)])
hi = mathutils.Vector([max(p[i] for p in points) for i in range(3)])
factor = TARGET_SIZE / max(hi - lo)
middle = (lo + hi) / 2
# Coordonnées monde voulues -> repère local du morceau gardé.
to_local = keep.matrix_world.inverted()
for v in model.data.vertices:
    v.co = to_local @ (center_world + (mathutils.Vector(v.co) - middle) * factor)
if len(model.data.uv_layers) == 1:
    first = model.data.uv_layers[0]
    second = model.data.uv_layers.new(name="UVMap1")
    for i, loop in enumerate(first.data):
        second.data[i].uv = loop.uv
print(f"GREFFE modèle : x{factor:.4f}, {len(model.data.vertices)} sommets, UV {[u.name for u in model.data.uv_layers]}")

# 3. Greffe : la géométrie du modèle remplace celle du morceau (nom, matériau, parent, poids gardés).
old_data = keep.data
new_data = model.data.copy()
new_data.materials.clear()
for mat in old_data.materials:
    new_data.materials.append(mat)
for poly in new_data.polygons:
    poly.material_index = 0
keep.data = new_data
keep.vertex_groups.clear()
group = keep.vertex_groups.new(name=bone)
group.add(list(range(len(new_data.vertices))), 1.0, "REPLACE")
bpy.data.objects.remove(model, do_unlink=True)
print(f"GREFFE résultat : {keep.name}, {len(keep.data.vertices)} sommets, os {bone}, "
      f"matériaux {[m.name for m in keep.data.materials]}")

# 4. Export.
result = bpy.ops.re_mesh.exportfile(filepath=out_mesh, filename_ext=".2101050001", targetCollection=mesh_collection.name,
                                    exportAllLODs=True, exportBlendShapes=False, rotate90=True,
                                    autoSolveRepeatedUVs=True, preserveSharpEdges=True,
                                    useBlenderMaterialName=False)
print("GREFFE export :", result, out_mesh)
