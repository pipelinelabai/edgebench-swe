# JSON Serialization Library — Streaming, Adapter & Type Support Roadmap

## Overview

This library is a Java JSON serialization / deserialization framework that maps between arbitrary
Java object graphs and their JSON representation. It offers a low-level streaming API
(`JsonReader` / `JsonWriter`), a tree-model API (`JsonElement` and friends), and a high-level
binding API (`Gson`, `GsonBuilder`) that composes user-defined and default `TypeAdapter`s.
The library is progressively aligning its streaming layer with the modern JSON specification and
its binding layer with the richer set of value/collection types found in modern JDKs.

---

## Goals

Our plan for this iteration centers on two roughly independent main threads.

The first thread modernises the **streaming and configuration surface**. We will align the
`JsonReader` and `JsonWriter` with RFC 7159 (which permits top-level scalars — strings,
numbers, booleans, `null` — as complete JSON documents even in strict mode), extend
`JsonWriter` with a nullable-boxed-`Boolean` overload, and expose a leniency switch on
`Gson`/`GsonBuilder` together with a `Gson.newJsonReader(Reader)` factory that returns a
`JsonReader` already configured with the same leniency setting. These changes are ordered:
the writer/reader RFC-7159 work must land first so that the leniency configuration flows
consistently through the streaming layer.

The second thread modernises the **binding and annotation surface**. We will register default
type adapters for the `java.util.concurrent.atomic` value and array types
(`AtomicInteger`, `AtomicBoolean`, `AtomicLong`, `AtomicIntegerArray`, `AtomicLongArray`),
add default support for `java.util.Currency` and for `java.util.concurrent`'s
`ConcurrentMap` / `ConcurrentNavigableMap` interfaces so that user-declared fields typed to
these interfaces "just work", accept unquoted integer/long map keys during deserialization, and
overhaul the `@JsonAdapter` annotation so that it (a) accepts `JsonSerializer` and/or
`JsonDeserializer` values in addition to `TypeAdapter`/`TypeAdapterFactory`, (b) exposes a
`nullSafe` attribute so users can opt out of the (now-default) null-safe wrapping, (c) lets a
field-level annotation take precedence over a class-level default, and (d) participates
correctly in the `Gson.getDelegateAdapter(TypeAdapterFactory, TypeToken)` recursion pattern.

Alongside these two threads we are also introducing a small set of type-token construction
helpers and instance introspection accessors so that users writing custom adapters can build
parameterized/array `TypeToken`s without an anonymous subclass and can query a live `Gson`
instance for its effective configuration; and we are tightening the `registerTypeHierarchyAdapter`
runtime contract so that a hierarchy adapter can no longer silently return an object whose
runtime type disagrees with the type the caller asked for.

The following capabilities are planned for this release:

- **Target 1: Streaming JSON per RFC 7159 (top-level values + boxed-Boolean writer)** —
  align the strict-mode reader and writer with RFC 7159, add a nullable-Boolean overload.
- **Target 2: Lenient configuration on `Gson`/`GsonBuilder`** — a builder switch plus a
  new-reader factory that wires the leniency flag through the streaming layer.
- **Target 3: Default adapters for `java.util.concurrent.atomic`** — Atomic scalars and arrays
  become first-class serializable values.
- **Target 4: Broader `java.util` / concurrent-map support + unquoted numeric map keys** —
  `Currency`, `Properties`, `ConcurrentMap`, `ConcurrentNavigableMap`, plus streaming reader
  tolerance for unquoted integer/long map keys.
- **Target 5: `@JsonAdapter` annotation overhaul** — accept `JsonSerializer`/`JsonDeserializer`,
  add an opt-out `nullSafe` attribute, respect field-level precedence, and integrate with
  `getDelegateAdapter` recursion.
- **Target 6: Type-token factories and instance introspection API** — static factories for
  parameterized / array `TypeToken`s, live-instance configuration accessors on `Gson`, and a
  `size()` accessor on `JsonObject`.
- **Target 7: Type-hierarchy factory runtime type check** — a hierarchy adapter must throw a
  descriptive exception when the deserialized value's runtime type is not compatible with the
  type actually requested from the type token.

Solvers should study existing adapter implementations, existing streaming state machines, and
existing annotation-driven factories inside the library before choosing an implementation
strategy for each Target — many of the design decisions become obvious after skimming a
handful of neighbouring files.

---

## Target 1: Streaming JSON per RFC 7159 (top-level values + boxed-Boolean writer)

### Background

`JsonReader` and `JsonWriter` were originally written against RFC 4627, which required the
top-level value of a JSON document to be an object or an array. RFC 7159 relaxes that
restriction: a bare string, number, boolean, or `null` is a valid complete JSON document.
Callers who deserialize (e.g.) a single boolean value via a small HTTP response, or serialize
one, currently have to enable lenient mode purely to get RFC 7159 semantics, which forces
them to also tolerate a host of unrelated syntax deviations they do not actually want.
Separately, `JsonWriter` currently accepts only a primitive `boolean` — callers holding a
possibly-`null` `Boolean` cannot write it in one call.

### What we need

Update the streaming layer so that, even in the default (non-lenient) configuration, a
complete JSON document can be a bare string, number, boolean, or null token — for both
reading and writing. Any structural rule that is not about "top-level must be array/object"
should keep behaving the same: for example, calling `name(...)` on a writer that has no
enclosing object and then trying to write a value must still fail, because that is a mismatched
state error, not a top-level-scalar decision.

Additionally, add a nullable-`Boolean` overload on `JsonWriter` alongside the existing
primitive-`boolean` `value(boolean)` method. Passing `null` to the boxed overload must produce
the same output as an explicit `nullValue()` call at that position.

### Requirements

1. **Reader top-level scalars in strict mode** — a `JsonReader` constructed with default
   settings must successfully read a document consisting solely of a boolean, a null, an
   integer, a floating-point number, or a string, in each case leaving the stream in
   `END_DOCUMENT`. `skipValue()` on such a document must also succeed and advance the reader
   to `END_DOCUMENT`.
2. **Writer top-level scalars in strict mode** — a `JsonWriter` constructed with default
   settings must accept `value(true)`, `nullValue()`, `value(123)`, `value(123.4)`, and
   `value("a")` as standalone top-level values and produce the corresponding JSON
   representation. All other structural rules (mismatched `name` without an open object,
   multiple top-level values without lenient mode, etc.) must still be enforced.
3. **Nullable-Boolean writer overload** — `JsonWriter` must accept `Boolean` (the boxed type)
   as a value. A non-null `Boolean` produces the same output as the primitive overload for
   the same underlying value; a null `Boolean` produces the same output as `nullValue()`.

---

## Target 2: Lenient configuration on `Gson` / `GsonBuilder`

### Background

Callers who want to consume JSON with common relaxations (comments, unquoted names,
trailing commas, and so on) currently have to obtain a `JsonReader` themselves, call
`setLenient(true)` on it, and route their `Gson` calls through the raw stream. There is no
way to say "any reader this Gson instance creates should be lenient". Similarly, `Gson` has no
public factory that returns a properly-configured `JsonReader`; callers wrap `Reader` in
`new JsonReader(reader)` by hand.

### What we need

Add a leniency switch on `GsonBuilder` and a matching reader-factory method on `Gson` so that
the leniency setting travels with the `Gson` instance and is applied to every reader the
library constructs internally on the caller's behalf (i.e. every `fromJson(Reader, ...)` /
`fromJson(String, ...)` code path).

### Requirements

1. **Builder switch** — `GsonBuilder` must expose a fluent method that turns on leniency and
   returns the builder. `Gson` instances built after calling this method must parse JSON
   fragments that the strict-mode reader would reject (JavaScript-style `//` and `#`
   comments inside arrays / objects, `,` before a closing bracket, etc.). Existing lenient
   parsing rules of `JsonReader` define what "lenient" means; do not invent new rules.
2. **Reader-factory method** — `Gson` must expose a public factory that constructs a
   `JsonReader` from a `Reader` and returns it already configured to match the `Gson`
   instance's leniency setting. Every `Gson.fromJson(Reader, …)` path (both `Class` and
   `Type` overloads) must go through this factory so that user data is parsed with the
   Gson-level leniency, not the `JsonReader` default.
3. **Default behavior unchanged** — a `Gson` built by `new GsonBuilder().create()` without
   invoking the new switch must still reject the same JSON that the strict reader rejects.

---

## Target 3: Default adapters for `java.util.concurrent.atomic`

### Background

Users frequently declare fields typed as `AtomicInteger`, `AtomicBoolean`, `AtomicLong`,
`AtomicIntegerArray`, or `AtomicLongArray` — usually as thread-safe alternatives to plain
`int` / `boolean` / `long` in mutable domain objects. The library currently falls back to
reflective serialization for these types, which produces awkward or unusable JSON (or fails
outright) and cannot round-trip.

### What we need

Register default type adapters that make each atomic wrapper behave, on the wire, exactly
like its underlying primitive would. In particular the atomic long / long-array adapters
must honour the library's `LongSerializationPolicy` in the same way the plain long adapter
does — a `Gson` configured with `LongSerializationPolicy.STRING` must emit an `AtomicLong`
as a JSON string and accept a JSON string as input, just as it already does for a bare
`long`. Deserialising a JSON boolean into `AtomicBoolean`, or a JSON number into any of
the atomic integer / long types, must always yield the correct value; serialising an atomic
must produce the same lexical representation the equivalent primitive would.

### Requirements

1. **Round-trip parity with primitives** — for `AtomicInteger`, `AtomicLong`, and
   `AtomicBoolean`, `toJson` and `fromJson` must produce and accept the same JSON tokens as
   the corresponding primitive/wrapper adapters do today. Deserializing `"10"` (as a JSON
   number) into `AtomicInteger` must produce a wrapper whose `get()` returns 10; similarly
   for `AtomicLong`. Deserializing the JSON literal `true` into `AtomicBoolean` must produce
   a wrapper whose `get()` returns `true`. Serialising each atomic must produce the naked
   token (`10`, `10`, `true`), not a JSON object.
2. **Array round-tripping** — `AtomicIntegerArray` and `AtomicLongArray` must serialize to
   a JSON array of the underlying values (in order) and deserialize a JSON array of numbers
   into an atomic array of the corresponding length and values.
3. **`LongSerializationPolicy` interaction** — a `Gson` built with
   `LongSerializationPolicy.STRING` must serialize any `AtomicLong` and any element of an
   `AtomicLongArray` as a JSON string, and must accept the corresponding JSON string on
   read. The plain `AtomicInteger` / `AtomicIntegerArray` adapters are not affected by the
   long serialization policy (they always use numeric form).
4. **Null tolerance** — a JSON `null` at any of these atomic positions must deserialize to a
   `null` reference, and a `null` reference in the object graph must serialize as JSON
   `null` (both matching the default null-handling behaviour of other wrapper adapters in
   the library).

---

## Target 4: Broader `java.util` / concurrent-map support + unquoted numeric map keys

### Background

Modern application domain models frequently declare fields typed as `Currency`,
`Properties`, `ConcurrentMap`, or `ConcurrentNavigableMap`. Today Gson has no default
adapter for `Currency`, no default constructor for the two concurrent-map interfaces, and
its streaming reader — when parsing a JSON map into a Java map with a numeric key type —
will refuse to accept unquoted integer/long map keys even in strict mode, forcing users to
quote every numeric map key.

### What we need

Register a default adapter for `java.util.Currency`; make `Properties` round-trip cleanly
using the existing map machinery; ensure that a user field typed as `ConcurrentMap<K,V>`
or `ConcurrentNavigableMap<K,V>` deserializes into an instance of an appropriate default
implementation from `java.util.concurrent`; and relax the `nextLong()` code path in
`JsonReader` so that it accepts an unquoted numeric token that would otherwise be treated
as an unquoted string. Serialization output for these map types must remain identical to
the existing map serialization behaviour (quoted keys).

### Requirements

1. **`Currency` adapter** — `Currency` fields must serialize as their ISO 4217 currency
   code string and deserialize from that same string. Null-tolerance rules match Target 3's.
2. **`Properties` round-trip** — `fromJson` on a JSON object into `Properties` must
   populate keys/values as strings; `toJson` on a `Properties` must produce a normal JSON
   object with the string entries. (Serialization order need not be specified.)
3. **`ConcurrentMap` / `ConcurrentNavigableMap` construction** — deserializing a JSON object
   into a field typed as `ConcurrentMap<K,V>` must produce a live `ConcurrentMap`
   implementation from `java.util.concurrent`; deserializing into a `ConcurrentNavigableMap<K,V>`
   must produce a live `ConcurrentNavigableMap` implementation. Deserializing into an
   explicit implementation class such as `ConcurrentHashMap<K,V>` or
   `ConcurrentSkipListMap<K,V>` must continue to work.
4. **Unquoted numeric map keys** — with default settings, `Gson` must deserialize a JSON
   document such as `{123:"456"}` into a `Map<Integer,String>` correctly, and analogously
   for `Long`; keys larger than `Integer.MAX_VALUE` must round-trip into `Long`. Serialization
   continues to emit quoted keys.

---

## Target 5: `@JsonAdapter` annotation overhaul

### Background

The `@JsonAdapter` annotation currently accepts only a `TypeAdapter` or `TypeAdapterFactory`
class. Users authoring stateless transformations (e.g. mapping a database enum to a JSON
string) would prefer to write a small `JsonSerializer` / `JsonDeserializer` and point
`@JsonAdapter` at it — that's the sweet spot for tree-model transformations. Separately,
today's `@JsonAdapter` implicitly wraps every custom adapter in `.nullSafe()`; users who
actually want to receive `null` (e.g. to emit a sentinel string) have no way to opt out.
Also, when both a class default and a field-level `@JsonAdapter` are present, the class
default is currently applied to the field — the opposite of the least-surprise rule.
Finally, a factory reached via `@JsonAdapter` cannot participate in the standard
`Gson.getDelegateAdapter(this, type)` recursion pattern, which prevents users from writing
wrapping/decorating adapters via the annotation route.

### What we need

Extend the annotation and the machinery that reads it so that:

- A class referenced by `@JsonAdapter(...)` may be a `TypeAdapter`, a `TypeAdapterFactory`,
  a `JsonSerializer`, a `JsonDeserializer`, or a single class that implements both a
  `JsonSerializer` and a `JsonDeserializer`. Whichever pieces are present are used; the
  missing piece uses Gson's default behaviour.
- The annotation exposes a `nullSafe` element with a default value that keeps existing
  behaviour intact (adapters remain null-safe by default). Explicitly setting the element
  to `false` means the annotation must _not_ wrap the resulting adapter with
  `.nullSafe()`, so the adapter's own `read`/`write` methods observe `null` values.
- A field-level `@JsonAdapter` takes precedence over any `@JsonAdapter` on the field's
  declared class, for both primitive and non-primitive field types.
- A factory obtained through `@JsonAdapter` is a legitimate participant in the
  `Gson.getDelegateAdapter(TypeAdapterFactory, TypeToken)` recursion protocol: passing
  such a factory as `skipPast` yields the next-in-line adapter (typically the default
  reflective one) rather than throwing or returning the wrapping factory again.

### Requirements

1. **Serializer/Deserializer values in `@JsonAdapter`** — a field annotated with
   `@JsonAdapter(SomeSerializer.class)` where `SomeSerializer implements JsonSerializer<T>`
   must serialize that field through the serializer; a `JsonDeserializer` must be similarly
   honoured on read; a class implementing both must be used for both directions. Whichever
   direction is not covered by the annotation-referenced class must fall back to the
   library's default handling for the field's declared type.
2. **`nullSafe` element** — the annotation must expose a boolean attribute controlling the
   null-safety wrapping. The default value must preserve today's behaviour (i.e., custom
   adapters are wrapped and only see non-null values). Setting the attribute to `false`
   must disable the wrapper so that the custom adapter's `read` sees the raw incoming
   `null` token / its `write` receives a `null` reference.
3. **Class-annotated null-safe default** — deserializing the literal JSON `null` into a
   type whose class carries a default `@JsonAdapter` must return a Java `null` (i.e., the
   custom adapter's `read` is not invoked). This is the observable consequence of the
   default null-safe wrapping.
4. **Field-level precedence** — a `@JsonAdapter` on a field must override a `@JsonAdapter`
   present on the field's declared type, and this must hold for both reference-typed fields
   (e.g. a field whose class has its own default `@JsonAdapter`) and for primitive fields
   (e.g. a `long` field with a field-level `@JsonAdapter` pointing at a factory that
   converts long-to-string).
5. **`getDelegateAdapter` interoperation** — a factory reached via `@JsonAdapter` that
   calls `gson.getDelegateAdapter(this, type)` in its `create(...)` implementation must
   receive the "next" adapter for the same type (typically the reflective default), not
   the same wrapping factory. In particular the well-known regression pattern — a factory
   that uses a `ThreadLocal` sentinel to break the recursion and delegates back to
   `gson.getDelegateAdapter(this, type)` — must serialize and deserialize successfully.

---

## Target 6: Type-token factories and instance introspection API

### Background

Constructing a parameterized `TypeToken`, e.g. `TypeToken<List<String>>`, today requires an
anonymous-subclass idiom (`new TypeToken<List<String>>() {}`). This is verbose, and impossible
when the type arguments are not known at compile time. Similarly, `Gson` itself hides its
effective configuration (excluder, field-naming strategy, null-serialization flag, HTML-safety
flag) from callers, and `JsonObject` hides its member count. All three are natural
introspection accessors that would let user code build higher-level tooling (custom factories,
diagnostic renderers, size-limit checks) without reflection or intermediate serialization.

### What we need

Add two static factories on `TypeToken` — one for parameterized types, one for array types
— so callers can build a `TypeToken<?>` from a raw type and a list of type arguments, or
from a component type. Add four accessor methods on `Gson` returning the effective
`Excluder`, `FieldNamingStrategy`, `serializeNulls` flag, and `htmlSafe` flag. Add a
`size()` accessor on `JsonObject`.

Two `TypeToken`s constructed from equivalent components must compare equal to the
corresponding anonymous-subclass form; specifically,
`TypeToken.getParameterized(List.class, String.class).equals(new TypeToken<List<String>>() {})`
must be true.

### Requirements

1. **`TypeToken.getParameterized(rawType, typeArguments...)`** — must return a
   `TypeToken<?>` representing the raw type applied to the given type arguments, equal
   (via `equals`) to the anonymous-subclass form of the same generic type. Must support
   nesting (a type argument may itself be a `Type` obtained from another
   `getParameterized` call).
2. **`TypeToken.getArray(componentType)`** — must return a `TypeToken<?>` representing an
   array of the given component type, equal to the anonymous-subclass form of the same
   array type. Component types may themselves be parameterized types.
3. **`Gson` accessors** — `excluder()`, `fieldNamingStrategy()`, `serializeNulls()`,
   `htmlSafe()` must return the values the `Gson` instance was actually built with. The
   two boolean accessors must reflect what the corresponding `GsonBuilder` methods
   configured (or the default if not configured).
4. **`JsonObject.size()`** — returns the number of key/value pairs currently held by the
   object; updates after `add(...)` and `remove(...)` calls.

---

## Target 7: Type-hierarchy factory runtime type check

### Background

`registerTypeHierarchyAdapter(Class<T>, TypeAdapter<T>)` installs an adapter that is used
for every subtype of `T`. Today, if the adapter's `read` returns an object whose runtime
type is not a subtype of the specific class the caller actually requested, that mismatch
propagates silently and later fails elsewhere (typically as a `ClassCastException`
deep inside user code) or, worse, is not caught at all. The most visible manifestation of
this bug in the library itself is the `JsonElement` type hierarchy: the built-in
`JsonElement` adapter is registered as a type-hierarchy adapter over `JsonElement`, so
`gson.fromJson("\"abc\"", JsonObject.class)` currently returns a `JsonPrimitive` (or
crashes on cast) instead of a clear error.

### What we need

Tighten the type-hierarchy factory so that, after the underlying adapter reads a non-null
value, the factory checks that the returned object's runtime class is assignable to the
type the caller actually requested via the `TypeToken`. If it isn't, throw a
`JsonSyntaxException` whose message identifies both the requested type and the actual
returned type. Serialization must be unaffected — the check exists only on the read side
— and null returns must be passed through unchanged.

### Requirements

1. **Mismatch throws `JsonSyntaxException`** — for a type-hierarchy adapter registered on
   a base type `B`, if the caller requests a specific subtype `S` via
   `fromJson(json, S.class)` and the adapter returns an instance of a different subtype
   `S'` of `B`, the call must throw a `JsonSyntaxException`. The message must mention both
   `S` (the requested type) and `S'` (the actual type) in a way that a human can identify
   both classes from the message.
2. **Null passthrough** — if the adapter returns Java `null` (i.e. read a JSON `null`),
   the runtime check must not fire; the caller receives `null` regardless of the requested
   subtype.
3. **Compatible values pass through** — a value whose runtime type is assignable to the
   requested subtype must be returned unchanged, with no additional wrapping.
4. **Serialisation unaffected** — writing an instance of a subtype through a type-hierarchy
   adapter must behave identically to before (the adapter simply delegates `write`).
5. **`JsonElement` visibility** — the specific visible consequence for the built-in
   `JsonElement` type hierarchy: `fromJson("\"abc\"", JsonObject.class)` and
   `fromJson("[1,2]", JsonObject.class)` must both throw `JsonSyntaxException` describing
   the mismatch; `fromJson("{}", JsonObject.class)` must succeed and return an empty
   `JsonObject`.

---

## Completion Criteria

- All new public classes / interfaces / annotations / methods listed above are reachable
  from their documented packages.
- Existing public APIs remain source-compatible unless a Target explicitly changes their
  behaviour; the classic streaming and binding tests in the module continue to pass.
- The default `Gson` (built via `new Gson()` or `new GsonBuilder().create()`) must
  continue to reject the syntax deviations it rejects today (only RFC 7159 top-level
  scalar tolerance and unquoted numeric map keys are relaxed by this release).
- `GsonBuilder` chained calls must remain fluent (each configuration method returns the
  builder).
- Where a Target overlaps with the `Gson` constructor signature (Targets 2 and 6), all
  in-tree callers must be updated so the module continues to compile end-to-end.
