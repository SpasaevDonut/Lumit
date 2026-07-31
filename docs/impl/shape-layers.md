# Shape layers — the plan before the code

**Status: a plan, not a spec.** Nothing here is built. It exists so the branch
that builds it (`claude/shape-layers-engine`, off the toolbar work) starts from a
decided shape rather than from a blank file, and so the reasoning survives if the
branch is picked up by someone else. When it lands, the durable parts move into
[../03-DATA-MODEL.md](../03-DATA-MODEL.md), [../06-RENDER-PIPELINE.md](../06-RENDER-PIPELINE.md)
and [../07-UI-SPEC.md](../07-UI-SPEC.md), and this note is archived.

## In plain terms

A **shape layer** is a layer whose content is vector art rather than pixels: you
draw a rectangle or a path, and the layer *is* that shape — filled, stroked, and
resolution-independent, so it stays crisp at any scale. After Effects makes one
whenever you drag a shape tool with nothing selected. Lumit cannot: `LayerKind`
has footage, solid, precomp, text, camera, sequence, adjustment and null in it,
and no shape. That is the gap.

A mask (K-220, shipped) is a *path on another layer* that decides which pixels
show. A shape layer is a path that **is** the picture. The geometry is the same
`BezierPath`; everything else differs.

## What has to be built, in order

1. **The model** (`lumit-core`). `LayerKind::Shape { contents: Vec<ShapeItem> }`,
   where a `ShapeItem` is a path plus its paint — fill colour, stroke colour,
   stroke width — each animatable (`Property`) like every other value in the
   document. Start with one item per layer and a flat list; AE's nested groups
   and its shape *modifiers* (repeater, trim paths, wiggle) are later work and
   must not shape the first cut.
   The path itself is `mask::BezierPath`, unchanged — one path type in the
   document, drawn by two things.
2. **The renderer** (`lumit-render`, `lumit-gpu`). A shape layer has no source
   pixels, so `build.rs` needs a draw kind that rasterises a path at the size the
   frame is being rendered at: fill by non-zero winding, stroke as a widened
   path. The natural size (K-215's wireframe reads it) is the path's bounding box.
   Decide early whether rasterising happens on the CPU into a texture (simple,
   costs an upload per change) or on the GPU by tessellating (fast, and the only
   honest answer for a shape being animated). The second is right; the first is
   a legitimate first commit if it keeps the seam identical.
3. **The bridge.** `add_shape_layer(contents)`, the contents in the read model
   beside `masks`, and edits through the same whole-list op the masks use.
4. **The frontend.** The shape tools' "nothing selected" branch stops posting its
   notice and makes one of these instead (`viewer_shape_layer.dart`,
   `_sayNoLayer`). The Timeline's twirl-down grows a Contents heading beside
   Masks and Effects. The layer-kind icon and the Project panel's kind column
   need the new kind.

## Decisions taken already, so they are not re-taken

- **The path type is shared with masks.** One `BezierPath` in the document, one
  set of maths, one bridge vertex type (`BridgeVertex`, K-220). A shape layer's
  path and a mask's path differ in what they *do*, not in what they are.
- **Layer space, as everything else.** A shape's coordinates are the layer's own,
  so the layer's transform moves the shape exactly as it moves a mask.
- **Nothing is dressed up as a shape layer until there is one.** Until the kind
  exists the tools say so (K-220). A solid with a mask would be a lie in the
  layer list.

## The trap to expect

The wireframe and hit-testing (K-215) read a layer's *content size* to draw its
box. A shape layer's size is its path's bounding box, which **changes as the path
is edited** — unlike every kind built so far, whose size is fixed by its source.
`LayerBoundsCache` caches by document revision, so it will follow, but the cache
was written when "a layer's size" was a constant and its comments say so; they
want revisiting rather than trusting.
