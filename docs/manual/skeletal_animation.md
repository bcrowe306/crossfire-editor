---
title: Skeletal animation
description: Animate characters with bones instead of frame-by-frame drawings, bend pictures over bones with skinned meshes, reach for targets with inverse kinematics, and import DragonBones characters.
order: 20
---

# Skeletal animation

Frame-by-frame animation (an AnimatedSprite) needs a drawing for every pose. **Skeletal
animation** draws the character once, in parts, and moves the parts with **bones**: an upper arm,
a forearm, a hand. You animate the bones' rotations in the Timeline, and the pictures follow.
Fewer drawings, smooth motion at any frame rate, and the same skeleton can play many animations.

The pieces, all nodes in the scene tree:

| Node | What it is |
|---|---|
| **Skeleton2D** | The root of a character's bones |
| **Bone2D** | A bone: it points along its x axis for its **Length**. Its children (pictures, more bones) move with it |
| **Sprite** under a bone | A rigid part: a head, a hand (a "cut-out" character) |
| **SkinnedMesh** | One picture that bends over several bones: a body, a sleeve, a tail |
| **IKChain** | Turns a chain of bones so its tip reaches a target: a hand reaching, a foot on the ground |
| **Animator** | Plays clips of keys: bones' rotations, positions, scales (see [Keyframe animation](animation.md)) |

- [Building a skeleton](#building-a-skeleton)
- [Animating it](#animating-it)
- [Pictures that bend: skinned meshes](#pictures-that-bend-skinned-meshes)
- [Reaching for targets: IK chains](#reaching-for-targets-ik-chains)
- [Importing DragonBones characters](#importing-dragonbones-characters)
- [From scripts](#from-scripts)

## Building a skeleton

1. **Add Node** (Ctrl+Shift+A) > **Skeleton2D**. Place it where the character stands (its hips,
   say).
2. In the inspector, **Add Bone**: a Bone2D under the skeleton. Turn it (Rotation) to point where
   the bone goes; set its **Length**.
3. With the bone selected, **Add Bone** again: the new bone starts at this one's tip, as its
   child. Build out the chain: spine, upper arm, forearm...
4. Put the pictures on the bones: select a bone, then drag an image from the browser into the
   viewport (the Sprite is added under the selected node), or drag a Sprite's row onto the bone in
   the scene tree. Move and turn it so it lies along the bone.

The viewport draws every bone as a wedge from its origin to its tip; the selected one is brighter.
Select bones by their rows in the scene tree.

**The pose the scene has is the rest pose.** Build the character in a neutral pose; animations move
the bones from there.

## Animating it

Bones are ordinary nodes, so the **Timeline** animates them:

1. Add an **Animator** under the Skeleton2D and open the bottom panel's **Timeline** tab.
2. Make a clip ("walk"), select a bone, turn it, and press **Key** on its Rotation. Move the
   playhead, turn it again, Key again.
3. Press Play in the Timeline to see it; the viewport shows the pose at the playhead.

Rotation keys are what most skeletal animation is; position keys move a bone (the hips bobbing),
scale keys squash and stretch.

## Pictures that bend: skinned meshes

A Sprite on a bone is rigid. A **SkinnedMesh** is one picture spread over several bones: where
two bones meet, the picture bends smoothly instead of showing a seam.

1. Add a **SkinnedMesh** under the Skeleton2D and choose its **Texture** (an image, or an atlas
   and its Region).
2. **Mesh columns** and **Mesh rows** set a grid over the picture; **Make Mesh** covers the picture
   with that grid of triangles, leaving out cells with nothing visible. More cells bend more
   smoothly.
3. Place the mesh over the bones it should follow (move the SkinnedMesh node).
4. **Bind to Bones**: every point of the mesh is tied to its nearest bones, most to the closest
   (up to four, their weights adding up to one).

The selected mesh's triangles are drawn in the viewport as they bend now. Moving a bone in the
editor changes the rest pose, so the mesh doesn't bend then; playing the Timeline and IK bend it.
After moving bones or the mesh, press **Bind to Bones** again.

In the scene file, the mesh is a `<mesh>` element: its points, where they are in the picture,
its triangles, its bones (paths from the mesh) and each point's weights.

## Reaching for targets: IK chains

**Inverse kinematics** turns bones so that the end of a chain reaches a point: you move the hand,
the elbow and shoulder follow. Use it for feet staying on the ground, hands holding things, a head
looking at something.

1. Add an **IKChain** (anywhere; under the Skeleton2D is tidy) and a node to be its target (a
   Node2D: "HandTarget").
2. **Tip bone**: the chain's last bone (the forearm). **IK target**: the target node.
3. **Bones**: how many bones up from the tip move (2 for an arm or leg). **Bend**: which way the
   middle joint bends (an elbow and a knee bend opposite ways).
4. Drag the target in the viewport: the chain follows at once.

Chains of two bones are solved exactly; longer chains (a tail, a tentacle) by turning each bone in
turn toward the target. A target out of reach makes the chain point straight at it. IK runs after
the Animator each frame, so you can animate the target (a foot's path) and let IK place the leg.
Turn **Solve** off to let the animation have the bones.

## Importing DragonBones characters

[DragonBones](https://github.com/DragonBones) is a free skeletal animation tool. Export a character
from it as JSON (Data version 5.5, texture atlas as a picture); you get three files:
`Name_ske.json` (the skeleton and animations), `Name_tex.json` and `Name_tex.png` (the atlas).

1. **Import** (Ctrl+I) the `_ske.json` file; the other two must be beside it.
2. The editor makes:
   - a **component** (`components/name.component.xml`): a Skeleton2D with the bones, a Sprite per
     image slot and a SkinnedMesh per mesh slot (drawn in the slots' order), and an **Animator**
     with every animation as a clip (it starts with DragonBones' default animation);
   - an **atlas** (`atlases/name.atlas.xml` and its picture) the sprites and meshes draw from.
3. Drag the component into a scene (or use **Add to Scene** in its preview), and play.

The Console lists what didn't convert. Not converted: slots switching pictures or colors during an
animation, mesh vertex (FFD) animations, extra skins, nested armatures, DragonBones' IK constraints
(add IKChain nodes instead), skewed bones (only their rotation is used), rotated atlas regions
(export without rotation), and curved easings (they play straight).

The component is yours to change afterwards: it's ordinary nodes.

## From scripts

```odin
// Turn a bone (degrees, clockwise)
arm := cast(^e.Bone2D)e.Scene_FindNode(scene, "Hero/root/body/arm")
arm.rotation = 45

// Where a bone's tip is in the world (to spawn a bullet at the gun's muzzle)
muzzle := e.Bone2D_Tip(arm)

// Move an IK target: the arm reaches for it next frame
target := e.Scene_FindNode(scene, "Hero/HandTarget")
e.Node_SetWorldPosition(target, mousePosition)

// Bones moved for a new rest pose: bind the mesh again
body := cast(^e.SkinnedMesh)e.Scene_FindNode(scene, "Hero/Body")
e.SkinnedMesh_Bind(body)

// Play an animation
e.Animator_Play(cast(^e.Animator)e.Scene_FindNode(scene, "Hero/Animations"), "walk")
```

## Questions

**My mesh doesn't bend.** It needs bones: put it under a Skeleton2D with Bone2D nodes, then Bind to
Bones. The inspector says "Not bound" until it is.

**The mesh bends in the wrong places.** Bind to Bones weights by distance: place the mesh over the
bones first, and use more grid cells near joints.

**My IK chain doesn't move.** Check Tip bone is a Bone2D and the target exists (the inspector warns),
and that Solve is on. With Bones 1, only the tip turns.

**An imported character draws parts in the wrong order.** Parts are layered by DragonBones' slot
order (their Z index); change a part's Z index to move it.
