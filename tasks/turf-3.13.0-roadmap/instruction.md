# Modular Geospatial Toolkit — Roadmap Implementation Plan

## Overview

This library is a modular JavaScript toolkit for performing geospatial operations on GeoJSON data (points, lines, polygons and their multi- and collection- variants). Each capability is packaged as its own installable module under a shared organisation-scoped namespace, and all modules share a small set of core helpers: a factory module for constructing GeoJSON features from raw coordinates, an invariant module for validating and unwrapping inputs, and a meta module for iterating features. The library is progressively hardening those core helpers, filling gaps in its geometry primitives, and moving away from external one-off dependencies in favour of first-class implementations that compose with the rest of the toolkit.

## Goals

We plan to land seven independent-but-related pieces of work in this release. The centrepiece is the mask module: today it is naïve about overlapping polygons and produces self-intersecting rings when its input polygons touch or overlap. We are re-working it so that overlapping input polygons are spatially indexed and merged before being embedded as interior rings of the mask polygon, while preserving the existing behaviour on non-overlapping inputs. In parallel we are replacing the flatten module's dependency on an external `geojson-flatten` library with a native implementation that also supports single-geometry inputs and an optional properties payload, and we are hardening the core helpers module and the invariant module so that they reject bad inputs early with clear errors and expose a general-purpose coordinate unwrapping helper that the rest of the ecosystem can reuse.

Alongside those changes we are shipping two brand-new modules. A great-circle module computes great-circle arcs between two points as a LineString, and a line-chunk module divides a LineString (or a collection of them) into fixed-length segments. Finally, the bearing module gains a small but often-requested option: computing the *final* bearing at the arrival point of a great-arc path, in addition to the *initial* bearing that it already computed.

The following capabilities are planned for this release:

- **Target 1: `flatten` — properties parameter and expanded input support** — turn any GeoJSON, including single-part geometries and geometry collections, into a flat FeatureCollection with optional property propagation.
- **Target 2: New `@turf/line-chunk` module** — divide a LineString-shaped input into fixed-length segments.
- **Target 3: `@turf/helpers` — argument validation & point-factory hardening** — make constructor factories fail fast on missing inputs and tighten `point()`'s validation.
- **Target 4: `bearing` — final-bearing option** — add a flag that switches the computation from initial bearing to final bearing.
- **Target 5: `@turf/invariant` — new `getCoords` + tighter `getCoord`** — expose a general coordinate unwrapper and reject non-Point inputs from `getCoord`.
- **Target 6: New `@turf/great-circle` module** — build a great-circle arc between two points.
- **Target 7: `@turf/mask` — overlapping polygon support** — correctly mask overlapping polygons by merging them spatially before embedding as interior rings.

---

## Target 1: `flatten` — properties parameter and expanded input support

Users of the flatten module today pass in a Feature or FeatureCollection whose multi-geometries they want exploded into individual single-part features. The current implementation delegates all of that work to an external one-off library (`geojson-flatten`), which cannot accept properties to propagate onto the exploded features and does not offer a uniform behaviour for single-part geometry inputs. As part of moving to a native implementation we want a small but consistent contract:

- The module's default export is a function `flatten(geojson, properties)` whose second argument is an optional properties object that is attached to features created from bare geometries and to features created out of a GeometryCollection's sub-geometries.
- It always returns a GeoJSON `FeatureCollection`, regardless of the shape of the input.
- It accepts every GeoJSON shape: bare geometries (`Point`, `LineString`, `Polygon`, and their `Multi-` counterparts), any `Feature<...>`, any `GeometryCollection`, and any `FeatureCollection`.
- For a single-part input (`Point`, `LineString`, `Polygon`), the input is wrapped into a one-element FeatureCollection.
- For a multi-part input (`MultiPoint`, `MultiLineString`, `MultiPolygon`), each coordinate group becomes its own single-part Feature in the returned FeatureCollection; every exploded feature carries the original feature's `properties`.
- For a `GeometryCollection` input, each sub-geometry becomes its own Feature in the returned FeatureCollection; the second `properties` argument is propagated to every produced Feature (both to multi-geometry sub-parts and to simple sub-geometries).
- The module must not require the `geojson-flatten` external package as a runtime dependency — remove it from the module's `package.json` and, if you need multi-feature iteration or geometry iteration helpers, reuse the existing helpers already provided by the ecosystem.

The set of GeoJSON fixture inputs already checked into the module's `test/in/` folder describes precisely the required output shape for each of the multi-geometry cases.

### Requirements

1. **Native flatten**: replace the current `geojson-flatten`-based one-line delegation with a native implementation that follows the contract above.
2. **`properties` parameter**: accept an optional second argument. When provided, apply it to the properties of features that this call creates from bare geometry inputs and to features derived from GeometryCollection sub-geometries. Do not overwrite `properties` on features that came in as Features already carrying their own `properties`.
3. **Reference outputs**: for every fixture in `packages/turf-flatten/test/in/`, the output of `flatten(<fixture>)` must deep-equal the corresponding file in `packages/turf-flatten/test/out/`.
4. **Package metadata**: remove `geojson-flatten` from the module's dependencies and ensure the module still works standalone.

---

## Target 2: New `@turf/line-chunk` module

The library today can measure the length of a LineString and can slice a portion of a LineString between two along-line distances, but it cannot cut a LineString into a fixed number of equal-length segments. Users want a routine that, given a LineString of length L and a segment length s, returns a FeatureCollection of `⌈L / s⌉` LineString features that together tile the original line.

We are shipping this as a brand-new module named `@turf/line-chunk` under `packages/turf-line-chunk/`. Its default export should be a function with the signature `lineChunk(featureIn, segmentLength, units, reverse)` where:

- `featureIn` may be a `Feature<LineString>`, a `Feature<MultiLineString>`, or a `FeatureCollection` of either.
- `segmentLength` is the target length of each chunk.
- `units` is a distance-units string (kilometres by default). It uses the same units convention that the rest of the library already uses.
- `reverse`, when truthy, reverses the input coordinate order so that the first produced chunk starts at the end of the original line.

Behaviour:

- Return a `FeatureCollection<LineString>`.
- For a single LineString that is shorter than or equal to `segmentLength`, return a single-feature FeatureCollection containing the original line unchanged.
- For a longer LineString, produce chunks of the requested length; the last chunk may be shorter than `segmentLength`.
- For a MultiLineString input, treat each part as an independent LineString (the module may reuse the flatten module for this).
- For a FeatureCollection input, process each contained feature and concatenate all chunks into a single output FeatureCollection.

Ship a `package.json` that names the module `@turf/line-chunk`, an `index.js` implementing it, and an `index.d.ts` that mirrors the signature (the runtime tests only require the JS implementation).

### Requirements

1. **Module exists and is importable** as `@turf/line-chunk` and its default export is a function.
2. **LineString input**: chunks the line into segments of the requested length; the first chunk starts at the line's start coordinate when `reverse` is false, and at the end coordinate when `reverse` is true.
3. **MultiLineString input**: each part is independently chunked; the aggregated output is a single `FeatureCollection<LineString>`.
4. **FeatureCollection input**: every contained LineString/MultiLineString is chunked and all produced segments are concatenated into a single output FeatureCollection.
5. **Reference outputs**: the fixtures placed under `packages/turf-line-chunk/test/in/` and the expected outputs at `packages/turf-line-chunk/test/out/{shorter,longer,reverse}` describe the exact numeric behaviour expected (a routine like the ecosystem's `truncate` is used to normalise floating-point precision when comparing against these references).

---

## Target 3: `@turf/helpers` — argument validation & point-factory hardening

The helpers module exposes the factory functions (`feature`, `point`, `lineString`, `polygon`, `featureCollection`, `multiPoint`, `multiLineString`, `multiPolygon`, `geometryCollection`, plus the units conversions `radiansToDistance`, `distanceToRadians`, `distanceToDegrees`) that the entire rest of the ecosystem builds on top of. Today several of them silently return malformed features when handed `undefined`, and `point()` defensively copies its input array (a hot-path allocation in tight loops).

We want two changes:

1. **Fail-fast validation on the constructors that don't already have it.** `feature()`, `featureCollection()`, and `geometryCollection()` currently do not check for a missing/undefined first argument and return an object with `undefined` in the shape. They should throw when called with no first argument.
2. **`point()` becomes stricter and cheaper.** Instead of the current single "must be an array" check, `point()` should perform a small pipeline of validations that make error causes distinguishable: missing input → throws; non-array-like input → throws; too-short input → throws; input whose first two positions are not numbers → throws. On the successful path, the input coordinates array should be stored on the produced feature *by reference* — no defensive copy.

The other constructors (`lineString`, `polygon`, `multiPoint`, `multiLineString`, `multiPolygon`) already throw on missing coordinates today; the only requirement for those is that they continue to work correctly on valid inputs.

### Requirements

1. **`feature(undefined)` throws** — the exact message text is up to you but the call must throw.
2. **`featureCollection(undefined)` throws** — likewise.
3. **`geometryCollection(undefined)` throws** — likewise.
4. **`point()` rejects missing / non-array-like / too-short / non-numeric coordinates**, each of which must produce a throw. Valid coordinate arrays must succeed.
5. **`point()` stores the incoming coordinates array by reference** on the resulting feature (no `.slice()` or other copy).
6. **All existing valid inputs to `feature`, `point`, `lineString`, `polygon`, `featureCollection`, `multiPoint`, `multiLineString`, `multiPolygon`, `geometryCollection` continue to produce structurally correct GeoJSON features.**

---

## Target 4: `bearing` — final-bearing option

The bearing module currently returns only the *initial* bearing between two points — the compass direction one would head to leave the start point. Users following a great-arc path want to know the *final* bearing — the compass direction of arrival at the end point, which for long paths differs materially from the initial bearing.

Extend the module's default export to accept an optional third argument. When it is truthy, the function computes and returns the final bearing at the arrival point instead of the initial bearing at the departure point. Everything else about the module — including its behaviour when the third argument is omitted or falsy — must remain identical.

Hint: the final bearing at the arrival point of a great arc from A to B is related to the initial bearing of the reverse arc B → A by a fixed rotation.

### Requirements

1. **Backwards compatibility**: calling the module with two arguments (or with a falsy third argument) returns the same value as before.
2. **Final bearing**: calling the module with a truthy third argument returns the final bearing at the arrival point.
3. **Reference values**: for the pair `start = point([-75, 45])`, `end = point([20, 60])`, the initial bearing (to two decimal places) is `37.75` and the final bearing (to two decimal places) is `120.01`.

---

## Target 5: `@turf/invariant` — new `getCoords` + tighter `getCoord`

The invariant module is the shared entry-point every other module uses to validate and unwrap its GeoJSON inputs. Today it exposes `getCoord`, but its unwrapping logic is duplicated in many downstream modules that need to unwrap coordinates from *non-Point* geometries (LineString, Polygon, …). We want to expose that generalised unwrapper as a first-class API, and at the same time we want `getCoord` to more thoroughly validate its own arguments.

**New export: `getCoords(obj)`** — unwrap the `coordinates` array from any GeoJSON Feature, Geometry, or raw coordinate value:

- If `obj` is a Feature, return `obj.geometry.coordinates`.
- If `obj` is a Geometry with a `coordinates` field, return `obj.coordinates`.
- If `obj` is already an array of numbers or an array of arrays, return `obj` unchanged.
- Reject falsy inputs (`null`, `false`, …) with a throw.
- Reject arrays whose leaf entries are not numbers (e.g. `['A','B','C']` or `[1,'foo','bar']`) with a throw.
- Reject Geometry objects whose `coordinates` field is present but null with a throw.

**Tighter `getCoord(obj)`** — internally use `getCoords()` to unwrap, then verify that the unwrapped value is a valid point (two numbers). This means:

- `getCoord()` continues to accept a Point Feature, a raw Point geometry, and a bare `[x, y]` array.
- `getCoord()` now *rejects* a LineString Feature, a raw LineString geometry, a Polygon Feature, and any Feature whose geometry is not a Point (including all the falsy and non-numeric-array cases that `getCoords()` also rejects).

The existing `geojsonType()`, `featureOf()`, and `collectionOf()` type-checkers stay as they are and must continue to work on valid inputs and continue to throw with informative messages when the input's type does not match the requested type or when required arguments (`name`, geometry) are missing.

### Requirements

1. **`getCoords` is exported** from `@turf/invariant` and is a function.
2. **`getCoords` unwraps Feature / Geometry / bare-array inputs** to their `coordinates` field (or the array itself), and throws on falsy input, on non-numeric-leaf arrays, and on Geometry objects with null coordinates.
3. **`getCoord` accepts Point-shaped inputs and rejects everything else** (LineString / Polygon / falsy / non-numeric-arrays).
4. **`getCoord([1, 2])`, `getCoord(point([1, 2]))`, and `getCoord({type: 'Point', coordinates: [1, 2]})` continue to work.**
5. **`geojsonType`, `featureOf`, `collectionOf` still throw the same categories of errors** they threw before (missing name argument, wrong geometry type, non-Feature input, non-FeatureCollection input) and still accept valid inputs.

---

## Target 6: New `@turf/great-circle` module

Given two `Point` features on the earth, the great-circle route between them is the shortest surface path between them. We are shipping a brand-new module that computes this route as a `Feature<LineString>` (or a `Feature<MultiLineString>` for routes that would cross the antimeridian and need to be split for display).

The module lives at `packages/turf-great-circle/` and its default export is a function with the signature `greatCircle(start, end, properties, npoints, offset)` where:

- `start` and `end` are `Point` features (or anything from which `getCoord` can unwrap `[lon, lat]`).
- `properties` is an optional properties object that is attached to the returned feature; defaults to an empty object.
- `npoints` is the number of vertices along the produced line; defaults to `100`.
- `offset` controls whether the produced line is split when it would cross the antimeridian; higher values mean splitting is more likely. Defaults to `10`.

Behaviour:

- Returns a `Feature` whose geometry is a `LineString` for routes that do not cross the antimeridian.
- The returned feature's `properties` deep-equals the `properties` argument (or `{}` if omitted).
- Higher `npoints` yields more coordinates along the line.
- Ship a `package.json` naming the module `@turf/great-circle`.

Hint: computing a great-circle arc from raw latitudes and longitudes is non-trivial. You do not need to reimplement it from scratch — there is a small, single-purpose npm package widely used for exactly this problem. Depend on it in your module's `package.json` and use its output to build the resulting Feature.

### Requirements

1. **Module exists and is importable** as `@turf/great-circle`; its default export is a function.
2. **Default arguments**: omitting `properties`, `npoints`, and `offset` uses `{}`, `100`, and `10` respectively.
3. **Output is a GeoJSON Feature** whose geometry is `LineString` (or `MultiLineString` for antimeridian-crossing routes).
4. **`properties` propagates** to the returned feature.
5. **`npoints` monotonically controls the number of vertices** in the produced line.
6. **Reference fixture** at `packages/turf-great-circle/test/in/basic.geojson` (a two-point FeatureCollection describing a route from `[-122, 48]` to `[-77, 39]`) produces, after normalising floating-point precision, the reference output at `packages/turf-great-circle/test/out/basic.geojson`.

---

## Target 7: `@turf/mask` — overlapping polygon support

The mask module takes an input polygon (or a FeatureCollection / MultiPolygon of them) and an optional mask polygon; it returns a Polygon Feature whose outer ring is the mask (defaulting to the whole world) and whose interior rings are the input polygons — the visual effect is to "cut" the input polygons out of the mask.

Today the implementation only works when the input polygons do not touch or overlap. When two input polygons overlap, the current code simply pushes each of their outer rings into the mask output as separate interior rings, producing a self-intersecting polygon that most consumers (renderers, GIS engines, `@turf/union`) do not accept. The current implementation also does not properly propagate interior rings of the mask polygon itself.

We are rebuilding the module so that:

- Non-overlapping input polygons still produce the same result they do today (each becomes an interior ring of the returned Polygon).
- Overlapping input polygons are detected before being embedded and are unioned into a single interior ring per connected component.
- Multi-part inputs (MultiPolygon, FeatureCollection with multiple polygons) are handled uniformly.

The exact reference outputs for the overlapping and mask-outside cases are shipped in the module's test fixtures under `packages/turf-mask/test/in/` and `packages/turf-mask/test/out/`; the results returned by the new implementation must deep-equal them.

Hint: to match the reference outputs exactly, use the ecosystem's existing polygon-union primitive to merge overlapping polygons. Naïvely calling union on every pair is O(n²); consider a spatial data structure that lets you union only polygons whose bounding boxes actually intersect.

### Requirements

1. **Non-overlapping inputs**: the module continues to produce the same result on the pre-existing non-overlapping fixtures (`test/in/basic/`, `test/in/feature-collection/`, `test/in/multipolygon/`).
2. **Overlapping inputs**: on `test/in/overlapping/polygon.geojson` and `test/in/overlapping-multipolygon/polygon.geojson`, the output deep-equals the corresponding files in `test/out/overlapping/results.geojson` and `test/out/overlapping-multipolygon/results.geojson`. Note that these reference outputs contain a single unioned interior ring (not one ring per input polygon).
3. **Custom mask polygon**: passing an explicit mask polygon (as in `test/in/mask-outside/`) produces the reference output in `test/out/mask-outside/results.geojson` — verify the outer-ring / hole layout matches.
4. **Output shape**: the module still returns a `Feature<Polygon>` regardless of how many input polygons or how much overlap was involved.

---

## Completion Criteria

- All seven Targets pass their referenced fixture-based and behavioural tests.
- The public API surface described here is present and importable from the documented module paths.
- Existing valid inputs to every module described here continue to produce the correct output — backwards compatibility is preserved for all API entry points that already existed.
- Every module's `package.json` declares its runtime dependencies correctly, including the two new modules (`@turf/great-circle`, `@turf/line-chunk`) and any external npm packages the new implementations pull in.
