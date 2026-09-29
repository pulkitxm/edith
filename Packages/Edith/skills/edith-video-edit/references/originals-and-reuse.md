# Originals and reuse

## Inventory the inputs

Inspect only the supplied assets and relevant project directories. For each
original, record a stable identity or checksum where available, path, media kind,
duration, dimensions, rational frame rate, audio streams and availability. Use
the installed media inspection API or a discovered read-only media probe.
Separate filenames from identity: equal names need not mean equal content, and
different paths may contain the same source.

Keep the high-quality original as the edit source. A proxy, downloaded preview,
contact sheet or previous export is a derived asset, not an interchangeable
original. If only a derived asset is available, record that limitation rather
than claiming an original-quality source.

## Import and preserve

Discover original-source import and project-setting operations through
`ed studio edit --help` and `ed studio edit schema`. Import using supported media
operations. If still-image duration or orientation needs explicit fields, obtain
those fields from the schema. If unsupported, report it before doing a conversion.

Maintain non-destructive project references. Apply trim, speed, crop, transforms
and grade in the native plan when available. Repeatedly encoding segments loses
quality and makes later timing or framing changes harder. Do not move, delete or
overwrite source files as a side effect of editing.

## Coordinate reuse

When a media catalog or reservation API is advertised, inspect its help and
existing records before selecting ranges. Record the project, source identity,
source in/out and intended use. Use the API's actual reservation semantics;
a local ledger is not an authoritative lock shared with other projects.

For a request such as "avoid footage already used", compare source ranges, not
just filenames or clip IDs. Check overlap using the original asset's clock and
include existing cuts relevant to the request. If shared usage cannot be queried,
say which projects were checked and which reuse claims remain unverified.

Discover `clone` when making a variation. Verify that the copy has an independent
project identity while the original is unchanged. A clone shares original-media
references and may not copy catalog reservations. Reconcile reservations for the
new project explicitly if the installed API supports them.

## Keep a portable handoff honest

An `.openscreen` document alone may contain absolute paths to external media.
Check source availability before render and report whether the handoff includes
media or only references it. If a supported collect/relink operation exists, use
its help and validate the collected copy. Do not rewrite internal paths by hand.

Keep the ledger local beside the edit. Use relative paths or logical asset labels
in any shared review material. External evidence must use synthetic media when
real project data is not authorized for sharing.
