# Companion

Companion is Edith's self-hosted memory and conversation system. It stores notes,
recordings, media, derived observations and conversations on hardware you choose.
The Mac app is the client and deployment controller; the backend runs as a
multi-container stack on this Mac or on a machine already registered in Edith.

## What it does

The Companion screen has seven areas:

| Area | Purpose |
| --- | --- |
| Chat | Ask questions over your own history, inspect supporting citations and request a three-lens second opinion. |
| Capture | Record speech and queue it safely when the backend is unavailable. |
| Desk | Review current work assembled from the memory. |
| Library | Add notes, audio, images, video and PDFs; search and inspect the resulting episodes. |
| Mind | Inspect observations, beliefs, entities and other derived memory. |
| Backend | Choose the host, deploy or adopt the stack, control services and read logs. |
| Settings | Configure reasoning, connectors, imports, exports and destructive data controls. |

Dropped files are ingested into the library. Audio is transcribed, supported media
can be interpreted by the vision service, and text is split and embedded for
retrieval. Chat answers can cite the episodes that support them. The system also
runs scheduled reflection to build higher-level memory from the material you gave
it.

## Host requirements

Open Companion and follow the setup sheet. Edith probes this Mac first and every
reachable machine in Machines. A usable host needs:

- a running Docker, Podman or Colima runtime with Compose support;
- at least 12 GB of free disk space;
- the configured API, PostgreSQL and Redis ports, plus port 11434, available;
- the Companion source tree either on this Mac or already in the deployment
  directory.

Apple Container can be detected, but it cannot host this stack because the current
deployment uses Compose. The default ports are 4820 for the API, 5432 for
PostgreSQL, 6379 for Redis and 11434 for Ollama. Change the first three in Backend
before deployment if they conflict with another service.

For a source checkout, Edith looks for `apps/companion` under `~/edith` or
`~/Desktop/Edith`. Set `EDITH_COMPANION_SOURCE` to another checkout before opening
Edith when the repository lives elsewhere. Deployment sends that source to the
chosen host, writes the Compose and environment files, builds the API, starts the
services and runs health checks.

Apple silicon Macs use the Apple Metal overlay. Intel Macs use the CPU overlay.
The initial image pulls, model downloads and Rust build can take several minutes.

## Remote hosts and tunnels

A remote Companion host must already be reachable through Machines. Edith records
the host, deployment directory, execution tier and API port in its local machine
configuration. It saves an SSH port forward that maps the remote API back to
`127.0.0.1:4820` by default and reopens that tunnel when needed.

The default deployment directory is `~/edith-companion`. The Compose project is
named `edith-companion`, so its containers appear as Edith's own Companion group in
the Docker view. Moving or removing the machine entry breaks control of that
deployment until it is added again or a different stack is adopted.

## Models and external services

PostgreSQL with pgvector stores indexed data, Redis provides service state, Ollama
serves the local embedding and vision models, and Whisper handles local speech to
text. The API is the fifth base service. A reasoning model is optional during setup. It can use a local
OpenAI-compatible endpoint, such as the bundled Ollama service, or Anthropic with a
key you provide.

Settings can also connect GitHub and Notion. Tokens are saved through the Companion
service and are only used for the sync you request. Calendar, music and YouTube
history do not have live connectors; import their exported JSON instead.

If reasoning or a connector calls an external provider, the request and the context
needed for it leave the host and are governed by that provider. Edith does not
proxy or receive those requests.

## Data, backup and deletion

The selected host owns the memory. The container volumes hold PostgreSQL data,
models and the plain-file vault. Edith's iCloud backup does not copy the Companion
database or vault.

Settings provides these separate controls:

- **Export everything** writes a portable folder containing the episodes,
  conversations and required manifest data.
- **Import a bundle** merges an export and skips existing items, so importing the
  same bundle twice is safe.
- **Erase derived memory** removes observations and other conclusions while
  retaining episodes and conversations so scheduled work can rebuild them.
- **Wipe the memory** deletes episodes, observations, beliefs, conversations and
  the vault files. Export first if any of it matters.

Stopping the stack preserves its volumes. Removing volumes is a different,
destructive operation and permanently removes the stored memory.

## Health and recovery

The status dot reports whether the API is reachable and whether its doctor checks
pass. Open Backend to inspect every service, restart the stack or read its logs.
Common failures are a stopped container runtime, a closed SSH connection, an
occupied port, a model that has not finished downloading, or a missing source tree
on the first deployment.

The CLI exposes the same deployment, stack, health, export, import and erase
operations. See the [Companion command reference](cli/companion/README.md).
