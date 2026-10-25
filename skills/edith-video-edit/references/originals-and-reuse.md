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

## Inspect capture dates before sorting

Read metadata from the original file before import or conversion. Record every
candidate capture date with its tag name, raw value, source asset identity,
timezone or offset, subsecond precision and interpretation. Capture-specific
metadata on the original takes precedence over dates on proxies, exports or
downloaded copies. Filesystem creation/modification times, filename dates and
upload timestamps are not substitutes for missing capture metadata.

For photographs, prefer original EXIF `DateTimeOriginal`, paired with
`OffsetTimeOriginal` and `SubSecTimeOriginal` when present. EXIF digitization or
modification dates describe different events; do not silently promote them to
capture dates. For video, inspect original QuickTime recording metadata such as
`com.apple.quicktime.creationdate`, including its explicit offset, before using
generic movie or track creation fields. Generic QuickTime creation fields can
describe container creation, and device conventions can differ. Record the
reason for interpreting a field as capture time instead of assuming it.

Normalize offset-bearing dates to a common UTC instant for comparison, while
retaining the original local value and offset. Preserve available fractional
seconds at their actual precision. Never invent subseconds to break ties. For
offset-free values, retain local wall time and mark the timezone unknown unless
independent, recorded evidence establishes it. Do not assume the host timezone,
infer an offset from file location, or overlook daylight-saving ambiguity.

Compare normalized candidates before resolving apparent disagreements. Different
offsets can represent the same instant. If credible capture fields still disagree,
mark the date conflicting and retain all candidates; record any explicit user
resolution and its basis. Missing or uninterpretable capture dates remain unknown.
There is no filesystem fallback. Do not describe an unresolved ordering as proven
capture chronology.

For chronological edits, sort confirmed comparable capture instants first under
an explicit policy. Group unknown or conflicting dates separately for review,
or use their explicitly agreed placement. Break genuine timestamp ties by stable
source identity, keeping the tie visible. Avoid changing shot order just because
a directory listing, import or metadata inspection returned a different order.

## Keep each order explicit

Capture chronology, editorial shot order, upload order and publication order are
separate fields. Record each requested order explicitly. An upload timestamp or
publication sequence does not prove when media was captured. Project identity
identifies an editable document; neither its UUID nor the order projects were
created establishes capture chronology or intended publication order.

Keep a stable, ordered shot ledger beside the plan. Give each selected shot a
stable shot key and explicit sequence number, then record original identity,
capture-date status/provenance, source range, output range, persisted clip ID and
any upload/publication position. Distinguish shot identity from source identity:
multiple shots can reference the same original. After reordering, update sequence
numbers while retaining shot keys and recording the new order.

For a brief requiring 45 unique originals in capture order, acceptance means 45
ordered ledger rows, 45 distinct verified source identities, no duplicate originals
under different filenames, and saved clip order matching the approved chronology.
Forty-five project clip IDs alone do not prove uniqueness. If "unique shots"
instead means distinct ranges from reusable originals, establish that definition
and validate those ranges. Report insufficient unique sources or unresolved dates
rather than padding the sequence or claiming an unsupported chronology. Confirm
any separate upload/publication order against its own requested sequence.

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
