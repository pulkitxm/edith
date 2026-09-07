# Plugins

Plugins lives in the Agents suite. Enable it from Extensions or run
`ed extensions enable plugins`.

The library contains Edith's own skills. It currently includes one:
**Edith Remote Work**, which teaches a harness on your laptop to discover remote
projects and perform their work through the `ed` CLI. It does not browse or
list the public skills.sh catalogue.

Click the plugin card to inspect its instructions before installing. Preview
renders the instructions with spacious headings, paragraphs and code blocks,
without the front matter. Skeletons indicate loading. The Markdown tab shows
the complete file in a read-only, syntax-highlighted viewer where text can be
selected. Copy copies the complete original Markdown, including metadata,
from either tab. A loaded skill stays in memory for the app session, so reopening
the preview displays it immediately without another download.

Skill content is fetched from the Edith repository on GitHub, on the main
branch. A valid download is cached locally. When GitHub cannot be reached,
the cached copy remains available and the installer records that fallback
in its output. The first preview or install requires a connection. Malformed
responses never replace the last valid cached skill.

Click Install to review the agents detected on this Mac. The attached dropdown
opens the same sheet with one agent selected for that installation. Changing
the toggles saves the complete selection for subsequent installs, including
agents turned off and an empty selection. These choices survive app restarts.
A newly detected agent starts selected. The dropdown alone does not overwrite
the saved selection.

Installation applies to all projects for the selected agents. The sheet shows
each destination folder. Agents that share a folder also share installed
skills, even if only one is selected. Installing replaces an existing version
of the same skill. Successful installations are verified on disk before the
sheet reports completion. An Installed button reflects a verified installation
from the current app session; click it to install again or choose other agents.

Edith uses `npx skills@1.5.24 add` against a temporary copy of the fetched skill with explicit
skill and agent arguments, global scope, and copy mode. Node.js 22.20 or later
must be available on Edith's PATH. The installer can download its package on
first use. Failed installs show their output and can be retried.

Agent detection uses configuration folders from the skills CLI's agent
catalogue. Agents without global skill support are excluded. Detection respects
environment settings such as `CODEX_HOME`, `CLAUDE_CONFIG_DIR` and
`XDG_CONFIG_HOME`; installation uses the CLI's destination conventions, including
the shared `~/.agents/skills` directory for universal agents. Open a newly
installed agent once so its configuration folder exists, then reopen the sheet.

The skill's source is
[`Packages/Edith/skills/edith-remote-work/SKILL.md`](../Packages/Edith/skills/edith-remote-work/SKILL.md).
It is fetched at runtime rather than packaged into the app, so skill updates
do not require a new app build or a clone of the repository. The same folder uses the standard SKILL.md format
accepted by the [Skills installer](https://github.com/vercel-labs/skills).

Agent marks reuse the bundled provider artwork. Additional official artwork comes
from [Command Code](https://commandcode.ai/favicon/2024/safari-pinned-tab.svg),
[Factory](https://factory.ai/favicon.svg),
[Warp](https://warp.dev/img/logos/warp-pixel-icon.svg),
[Mistral](https://mistral.ai) and
[Zed](https://github.com/zed-industries/zed/blob/main/assets/images/zed_logo.svg).
