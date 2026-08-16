# How Homebrew distribution works, and how Edith's was built

This is the long version. [docs/homebrew.md](homebrew.md) is the page you want when
you just need the commands; this one explains the machinery underneath them, why
each piece was chosen, and what to do when a piece breaks.

It is written for someone who has used `brew install` a hundred times without ever
reading what it does. Everything here about Homebrew's own behaviour was checked
against Homebrew's documentation and source rather than recalled, and the places
where a claim is a judgement call rather than a documented rule are marked as such.

Contents:

1. [The problem Homebrew solves](#1-the-problem-homebrew-solves)
2. [The prefix, and the three trees under it](#2-the-prefix-and-the-three-trees-under-it)
3. [Formulae and casks](#3-formulae-and-casks)
4. [Taps](#4-taps)
5. [How a name becomes a package](#5-how-a-name-becomes-a-package)
6. [The install pipeline, step by step](#6-the-install-pipeline-step-by-step)
7. [Upgrades, and why Edith opts out of them](#7-upgrades-and-why-edith-opts-out-of-them)
8. [Uninstall, zap, and what state is left behind](#8-uninstall-zap-and-what-state-is-left-behind)
9. [Quarantine, Gatekeeper, and notarization](#9-quarantine-gatekeeper-and-notarization)
10. [The cask DSL, stanza by stanza](#10-the-cask-dsl-stanza-by-stanza)
11. [Edith's cask, annotated line by line](#11-ediths-cask-annotated-line-by-line)
12. [The release pipeline this plugs into](#12-the-release-pipeline-this-plugs-into)
13. [The cask bump](#13-the-cask-bump)
14. [The tap repository](#14-the-tap-repository)
15. [Decision log](#15-decision-log)
16. [Runbook](#16-runbook)
17. [Failure modes](#17-failure-modes)
18. [What was verified, and how](#18-what-was-verified-and-how)
19. [Glossary](#19-glossary)
20. [Sources](#20-sources)

---

## 1. The problem Homebrew solves

macOS ships without a package manager for third-party software. The default way to
install a Mac app is: open a browser, find a download page, fetch a disk image,
mount it, drag an icon into `/Applications`, eject the image, delete it. To update,
do all of that again, or trust whatever updater the app bundles. To uninstall, drag
the app to the trash and leave its preferences, caches and support files behind
forever.

Every step of that is manual, unscriptable, and unverifiable. Nothing checks that
the disk image you downloaded is the one the developer built. Nothing records what
was installed, at which version, or where its files went. A new laptop means doing
the whole dance again for every app.

Homebrew replaces that with a description of the software, kept in a git
repository, that a program can read:

- where to download it from,
- what its contents should hash to,
- what to do with the contents once verified,
- what to remove when you change your mind.

Given that description, installing becomes one command, and so does upgrading,
listing, uninstalling, and reproducing the whole set on another machine. The
description is plain text under version control, so it is reviewable and its history
is auditable.

That description is a **formula** for command line software, and a **cask** for a
Mac application. Edith ships both kinds of thing in one bundle, so it is a cask, but
the distinction matters and is covered in section 3.

---

## 2. The prefix, and the three trees under it

Homebrew installs everything under a single directory called the **prefix**. On
Apple Silicon that is `/opt/homebrew`; on Intel Macs it is `/usr/local`. Ask your
own installation rather than assuming:

```
brew --prefix        # where packages land
brew --repository    # Homebrew's own git checkout, which is also where taps are cloned
brew --caskroom      # where casks are staged
brew --cellar        # where formulae are installed
```

Three trees under the prefix matter for understanding what an install actually did.

### The Cellar

`$(brew --cellar)` holds formula installations, one directory per formula per
version:

```
/opt/homebrew/Cellar/
  jq/
    1.7.1/
      bin/jq
      share/man/man1/jq.1
```

Nothing on your `PATH` points into the Cellar directly. Instead Homebrew creates
symlinks from `$(brew --prefix)/bin` into the versioned directory. That indirection
is what makes switching versions cheap: the files stay where they are and only the
link moves.

### The Caskroom

`$(brew --caskroom)` is the same idea for casks:

```
/opt/homebrew/Caskroom/
  edith/
    0.0.76/
      Edith.app -> moved out to /Applications, with a record kept here
```

The cookbook states the staging path plainly: downloaded files are staged at
`$(brew --caskroom)/<token>/<version>`. The Caskroom is Homebrew's memory of what it
did. It is how `brew list --cask edith` knows what exists and how `brew uninstall`
knows what to remove. Deleting an app by dragging it to the trash leaves the
Caskroom entry behind, which is why Homebrew then reports the cask as installed when
it is not. Use `brew uninstall --cask` so both sides stay in agreement.

### The link farm

`$(brew --prefix)/bin` is a directory of symlinks, not real binaries. This is the
part of Homebrew that interacts with your shell, and the part that surprises people:

```
/opt/homebrew/bin/ed -> /Applications/Edith.app/Contents/MacOS/ed
```

Homebrew's `bin` sits ahead of `/usr/bin` on a default macOS `PATH`. Anything linked
there wins over the system copy of the same name. That single fact drives one of the
sharper trade-offs in Edith's cask, discussed in section 15.

---

## 3. Formulae and casks

Homebrew has two package types, and the difference is not cosmetic.

| | Formula | Cask |
| --- | --- | --- |
| Describes | Command line software, libraries | macOS applications and other prebuilt artifacts |
| Written in | Ruby, a `Formula` subclass | Ruby, a `cask` block |
| Source | Usually built from source, or a bottle | Always a prebuilt download from the vendor |
| Lands in | `$(brew --cellar)`, linked into `$(brew --prefix)` | `/Applications`, staged through `$(brew --caskroom)` |
| Command | `brew install jq` | `brew install --cask edith` |
| Platform | macOS and Linux | macOS only |

A **bottle** is a precompiled formula build, which is why `brew install jq` finishes
in seconds instead of compiling. Casks have no equivalent because a cask is already
a prebuilt binary by definition: Homebrew downloads exactly what the vendor
published, checks its hash, and moves it into place.

Edith is a cask. It is a signed `.app` bundle distributed as a `.dmg`, which is the
canonical cask shape. The fact that the bundle also contains two command line tools
does not make it a formula: the unit of distribution is still the application.

An important consequence of "cask means macOS only": nothing about the cask can be
end-to-end tested on a Linux machine, including in CI. This shapes what verification
is possible, covered in section 18.

---

## 4. Taps

A **tap** is a git repository of package descriptions. Homebrew ships with a default
tap and can clone any number of others.

### What is in one

A tap is a normal git repository with a conventional layout:

```
homebrew-tap/
  Casks/
    edith.rb
  Formula/
    something.rb
  README.md
```

Homebrew finds casks in `Casks/` and formulae in `Formula/`. There is no manifest,
no index, no registry call: the file layout is the interface. Adding a package to a
tap means adding a file and pushing it.

### Where they live on disk

Tapping clones the repository into Homebrew's own checkout:

```
$(brew --repository)/Library/Taps/<user>/homebrew-<name>/
```

So `pulkitxm/tap` becomes
`/opt/homebrew/Library/Taps/pulkitxm/homebrew-tap`. `brew update` is, for third-party
taps, essentially `git pull` in each of those directories. This is why a tap must
stay small if you care about `brew update` latency: every tap you add is another
repository to fetch on every update.

### The naming rule

From Homebrew's Taps documentation:

> On GitHub, a repository must be named `homebrew-<repository>` to use the
> one-argument form of `brew tap`. The `homebrew-` prefix can be omitted from the
> command.

So `brew tap pulkitxm/tap` resolves to the GitHub repository
`pulkitxm/homebrew-tap`. The prefix is stripped by convention, not by magic, and it
is the only reason a tap can be referred to by a short name at all.

The two-argument form escapes the convention:

> `brew tap <user>/<repository> <URL>` clones a repository from the specified Git
> URL without assuming GitHub or a particular transport.

That form is what lets any repository act as a tap, at the cost of every user having
to type the URL. Edith started there and moved off it, which is the subject of
section 15.

### The default tap

`homebrew/cask` is bundled with Homebrew. Its casks resolve by bare token with no
tapping required, which is the entire reason `brew install --cask firefox` works on
a machine that has never been configured. Getting into it is a review process with
an explicit notability bar, covered in section 15.

---

## 5. How a name becomes a package

This is the part that governs what the install command looks like, so it is worth
being precise. Homebrew accepts two shapes of name.

### Bare token

```
brew install --cask edith
```

A bare token is looked up in every tap installed on the machine, plus the bundled
`homebrew/cask`. On a machine with no relevant tap, a bare token for a third-party
cask cannot resolve, because there is nothing to resolve it against. Nothing about
the cask's contents changes this. It is purely a question of what repositories the
machine has cloned.

### Fully qualified name

```
brew install --cask pulkitxm/tap/edith
```

Three segments: user, repository, token. Homebrew matches this with a regex, from
`Library/Homebrew/tap_constants.rb`:

```ruby
# Match taps' casks, e.g. `someuser/sometap/somecask`.
HOMEBREW_TAP_CASK_REGEX =
  %r{\A(?<user>[^/]+)/(?<repository>[^/]+)/#{HOMEBREW_TAP_CASK_TOKEN_REGEX.source}\Z}
```

Two things follow from reading it literally.

First, exactly three segments are required. A two-segment name such as
`pulkitxm/edith` does not match, so it is not treated as a tap reference at all. It
falls through to being an ordinary token, and the token pattern is
`[\w+\-.@]+`, which does not permit a slash. The result is an unavailable-cask
error. There is no two-segment form; it is not a matter of taste or configuration.

Second, the `repository` segment is the tap name, not the project name. In
`pulkitxm/tap/edith`, `tap` is the repository `pulkitxm/homebrew-tap` and `edith` is
the cask token. Naming the tap repository after the project is what produces the
much-mocked `pulkitxm/edith/edith`.

### Tapping happens automatically

A fully qualified name does not require a separate `brew tap` first. Homebrew's
install command resolves the tap and installs it before doing anything else, in
`Library/Homebrew/cmd/install.rb`:

```ruby
args.named.each do |name|
  if (tap_with_name = Tap.with_formula_name(name))
    tap, = tap_with_name
  elsif (tap_with_token = Tap.with_cask_token(name))
    tap, = tap_with_token
  end

  tap&.ensure_installed!
end
```

`ensure_installed!` clones the tap if it is missing. That is why one command is
enough on a fresh machine, and why the documented install line for Edith has no
`brew tap` step in front of it.

Note the asymmetry this creates. The first install needs the long name because
nothing is tapped yet. Every command after it can use the bare token, because the
tap is now on the machine. That is not sloppiness in the docs; it is the resolution
rule doing exactly what it says.

---

## 6. The install pipeline, step by step

What actually happens on `brew install --cask pulkitxm/tap/edith`:

1. **Parse the name.** Three segments match `HOMEBREW_TAP_CASK_REGEX`, giving user
   `pulkitxm`, repository `tap`, token `edith`.
2. **Ensure the tap.** `Tap.fetch("pulkitxm", "tap")` maps to the GitHub repository
   `pulkitxm/homebrew-tap`, and `ensure_installed!` clones it into
   `Library/Taps/pulkitxm/homebrew-tap` if it is not already there.
3. **Load the cask.** `Casks/edith.rb` is read and evaluated as Ruby. The stanzas in
   it are method calls that record configuration; nothing is executed against your
   machine at this point.
4. **Check requirements.** `depends_on macos:` and `depends_on arch:` are evaluated
   against the running machine. A mismatch stops the install here, before anything
   is downloaded.
5. **Download.** The `url` is fetched into Homebrew's download cache. `version` is
   interpolated into the URL first, so one line of the cask determines what gets
   fetched.
6. **Verify.** The download is hashed and compared to `sha256`. A mismatch aborts.
   This is the integrity check that makes the whole scheme trustworthy: a tampered
   or truncated download cannot proceed.
7. **Stage.** The disk image is mounted and its contents are copied into
   `$(brew --caskroom)/edith/<version>`.
8. **Install artifacts.** Each artifact stanza runs in order. `app "Edith.app"`
   moves the bundle to `/Applications`. Each `binary` stanza creates a symlink in
   `$(brew --prefix)/bin`.
9. **Record.** The Caskroom entry and its metadata are written, so later commands
   know what is installed and at what version.

Steps 5 and 6 are the ones people forget exist, and they are the reason a cask is
strictly better than a download link: the download link has no step 6.

---

## 7. Upgrades, and why Edith opts out of them

### The normal path

```
brew update              # refresh Homebrew itself and every tap, changes nothing installed
brew outdated --cask     # compare installed versions against what the taps now say
brew upgrade --cask      # install the newer versions
```

`brew update` and `brew upgrade` are different commands and the confusion between
them is universal. `update` refreshes descriptions. `upgrade` acts on them. Running
`update` alone never changes an installed application.

### Self-updating apps

Many Mac apps update themselves. Edith is one: it ships Sparkle and checks a signed
appcast that the release workflow generates and publishes alongside each release.

This creates a conflict. If an app updates itself from 0.0.76 to 0.0.77, Homebrew's
record still says 0.0.76, because nothing told it otherwise. Homebrew now believes
an upgrade is needed when it is not, and "upgrading" means downloading and
reinstalling a version the machine already has.

The cask DSL resolves this with a declaration:

```ruby
auto_updates true
```

This tells Homebrew the app maintains itself, so a routine `brew upgrade` skips it
rather than fighting the built-in updater. The escape hatch is `--greedy`, which
means "include casks that say they update themselves":

```
brew outdated --cask --greedy
brew upgrade --cask --greedy edith
```

That is the documented upgrade command for Edith, and the reason it looks unusual.
It is not a workaround; it is the intended interface for exactly this case.

### Which updater wins

Both work, and they do not corrupt each other. Sparkle replaces the bundle in
`/Applications` in place. The `binary` symlinks point at paths inside that bundle,
so they keep resolving after a Sparkle update. A later `brew upgrade --greedy`
reinstalls the current cask version over the top and brings Homebrew's record back
in line. The only visible artifact of the drift is `brew info` reporting a version
older than the running app, between a Sparkle update and the next greedy upgrade.

---

## 8. Uninstall, zap, and what state is left behind

Homebrew distinguishes removing an application from removing everything the
application ever wrote.

```
brew uninstall --cask edith          # the app and its symlinks
brew uninstall --cask --zap edith    # the above, plus settings, caches and history
```

`uninstall` reverses the artifact stanzas: the `.app` is removed, the `binary`
symlinks are unlinked, and the Caskroom entry goes away. It deliberately does not
touch anything in your home directory, because your data is not Homebrew's to
delete by default.

The `uninstall` stanza can also declare cleanup that must happen first. Edith
declares the processes to stop:

```ruby
uninstall quit: [
  "com.pulkit.edith",
  "com.pulkit.edith.statusbar",
  "com.pulkit.edith.files",
]
```

Three bundle identifiers, because Edith is three bundles: the main application, the
menu bar login item, and the Files helper. Quitting them before removing the app
avoids the classic failure where a running process holds files open and a partially
deleted app keeps its menu bar icon until logout.

The `zap` stanza is the opt-in deep clean, listing the paths the application creates
outside its bundle. Edith's covers the support directory, both caches, the network
storage directory, the three preference domains, and saved window state. Homebrew
prefers `trash:` over `delete:` for exactly the reason you would hope: recoverable
beats irreversible when a glob is involved.

The stanza is only as good as its inventory. A feature that starts writing to a new
location and does not update `zap` leaves that location behind forever. Treat the
zap list as part of the feature, not as packaging trivia.

---

## 9. Quarantine, Gatekeeper, and notarization

Three separate mechanisms are involved in whether a downloaded app will open, and
they are routinely confused with one another.

**Quarantine** is a file attribute, `com.apple.quarantine`, that macOS attaches to
downloads. Homebrew applies it to cask installs by default, deliberately: an app
installed through Homebrew is treated exactly like an app you downloaded yourself,
so the same operating system checks apply. `--no-quarantine` skips it, which is a
decision for the person installing, not for the cask author.

**Gatekeeper** is the enforcement: on first launch of a quarantined bundle, macOS
verifies its signature and notarization status and decides whether to open it,
warn, or refuse.

**Notarization** is Apple's service. You upload a signed build, Apple scans it and
returns a ticket, and `stapler` attaches that ticket to the artifact so verification
works without a network round trip.

Edith's release workflow signs unconditionally and notarizes conditionally:

```yaml
HAS_NOTARY: ${{ secrets.NOTARY_KEY_ID != '' && secrets.NOTARY_ISSUER_ID != '' && secrets.NOTARY_KEY != '' }}
```

The notarize-and-staple step and the `spctl` verification both run only when those
three secrets exist. Signing and the Sparkle key, by contrast, are mandatory: the
job fails outright without them.

This matters to Homebrew users specifically. If a build is not notarized, installing
through `brew install --cask` produces the same Gatekeeper warning as downloading the
disk image by hand, because Homebrew applied the same quarantine attribute. The cask
does not and cannot paper over that. The fix is notarization in the release
pipeline, not a cask stanza.

---

## 10. The cask DSL, stanza by stanza

A cask file is Ruby. `cask "edith" do ... end` is a method call taking a block, and
every stanza inside is another method call. That is why the syntax is so regular and
why `ruby -c` can check it, but also why a typo in a stanza name is a runtime error
rather than a parse error.

The token in the header must match the filename: `cask "edith"` lives in
`Casks/edith.rb`. Homebrew's token rules are mechanical: lowercase, spaces and
underscores become hyphens, version numbers and words like "App" and "for macOS" are
dropped, non-alphanumeric characters other than hyphens are deleted. `Edith.app`
gives `edith`.

### Required stanzas

**`version`** is the version string, interpolated into `url` and used as the
Caskroom directory name. The special value `:latest` exists for vendors who publish
an unversioned "current" download, and it is a last resort: it defeats version
comparison, so Homebrew cannot tell whether an upgrade is needed.

**`sha256`** is the checksum of the file at `url`. The special value `:no_check`
pairs with `version :latest` for downloads whose contents change under a fixed URL.
Every use of `:no_check` is a place where a compromised or corrupted download would
be installed without complaint, which is why a real checksum is worth the automation
needed to keep it current.

**`url`** is where the artifact is fetched from. It accepts a `verified:` parameter,
which is a prefix assertion: it declares that the URL is expected to live under that
host and path, so a redirect to somewhere else is a failure rather than a silent
substitution.

**`name`**, **`desc`**, **`homepage`** are metadata: the proper vendor name, a
one-line description, and the project's page. `desc` is what `brew search` matches
against, so it is worth writing for a stranger rather than for yourself.

**At least one artifact stanza** must be present, otherwise the cask describes a
download that goes nowhere.

### Artifact stanzas

**`app "Something.app"`** moves an application bundle into `/Applications`. A
`target:` parameter renames it or places it elsewhere.

**`binary "path"`** symlinks an executable into `$(brew --prefix)/bin`. The path may
point inside an installed app bundle, which is how a GUI application ships a CLI. A
`target:` parameter renames the link.

**`pkg`** installs an Apple installer package. It requires a matching `uninstall`
stanza, because a `.pkg` can scatter files anywhere and Homebrew has no other way to
know what to remove.

**`suite`** moves a directory of related applications. **`installer`** runs a manual
or scripted installer and, like `pkg`, requires `uninstall`.

### Behaviour stanzas

**`livecheck`** teaches Homebrew where to look for the newest version, which drives
`brew livecheck` and the automated bumping that runs against the official taps.

**`auto_updates true`** declares that the app updates itself, as discussed in
section 7.

**`depends_on`** declares requirements: `macos:`, `maximum_macos:`, `arch:`,
`cask:`, `formula:`. These are checked before the download, so an unsupported
machine fails fast instead of after fetching tens of megabytes.

**`conflicts_with`** names casks that cannot be installed alongside this one.

**`uninstall`** and **`zap`**, covered in section 8.

**`caveats`** prints a message at install time. It is the right place for something
the user must know and the wrong place for something the cask should have handled
itself.

**`preflight`**, **`postflight`**, and their uninstall counterparts run Ruby around
the install. They are an escape hatch, and every one of them is a thing that can
break on a machine you have never seen.

---

## 11. Edith's cask, annotated line by line

The whole file, from `Casks/edith.rb` in this repository:

```ruby
cask "edith" do
  version "0.0.98"
  sha256 "338f7aaad4714ad10e31e25174793d63f9e9415fa55e96ff2b5310cc2699e04d"

  url "https://github.com/pulkitxm/edith/releases/download/v#{version}/Edith.dmg",
      verified: "github.com/pulkitxm/edith/"
  name "Edith"
  desc "Menu bar control center for coding agents, clipboard, music, and disk tools"
  homepage "https://edith.pulkit.page/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Edith.app"
  binary "#{appdir}/Edith.app/Contents/MacOS/ed"
  binary "#{appdir}/Edith.app/Contents/MacOS/edh"

  uninstall quit: [
    "com.pulkit.edith",
    "com.pulkit.edith.statusbar",
    "com.pulkit.edith.files",
  ]

  zap trash: [
    "~/Library/Application Support/Edith",
    "~/Library/Caches/Edith",
    "~/Library/Caches/com.pulkit.edith",
    "~/Library/HTTPStorages/com.pulkit.edith",
    "~/Library/Preferences/com.pulkit.edith.plist",
    "~/Library/Preferences/com.pulkit.edith.shared.plist",
    "~/Library/Preferences/com.pulkit.edith.statusbar.plist",
    "~/Library/Saved Application State/com.pulkit.edith.savedState",
  ]
end
```

Taking it in order.

**`version` and `sha256`** are the only two lines that change between releases, and
neither is ever edited by hand. The release workflow rewrites both, which is what
keeps them consistent with each other. A hand-edited version with a stale checksum
is the single most common way a tap breaks, and automating the pair together makes
that failure impossible rather than merely unlikely.

**`url`** interpolates `version` back into the release download path, so
`0.0.98` produces
`https://github.com/pulkitxm/edith/releases/download/v0.0.98/Edith.dmg`. Note the
`v` prefix outside the interpolation: tags are `v0.0.98`, versions are `0.0.98`, and
the cask holds the version, not the tag. The `verified:` parameter pins the host and
path prefix so a redirect elsewhere fails.

**`desc`** describes the app, not the technology. Someone running `brew search
clipboard` should find it.

**`livecheck`** with `url :url` and `strategy :github_latest` means "look at the
GitHub releases for the repository this URL points at, and report the latest tag".
For a cask in a third-party tap, nothing automatically acts on that: Homebrew's
BrewTestBot bumps casks in the official taps, not in yours. It is still worth
declaring, because `brew livecheck --cask pulkitxm/tap/edith` becomes a one-command
answer to "is this tap stale", which is a useful thing to be able to ask when a
release job has failed silently.

**`auto_updates true`** because Sparkle is in the bundle. Section 7 covers the
consequence.

**`depends_on macos: ">= :sonoma"`** encodes the README's "macOS 14 or later".
Sonoma is macOS 14; Homebrew uses names rather than numbers here.

**`depends_on arch: :arm64`** encodes Apple Silicon only. Together these two lines
turn "requirements" from prose on a download page into a check that runs before
anything is fetched. An Intel Mac gets a clear refusal instead of an app that will
not launch.

**`app "Edith.app"`** is the artifact. The disk image contains `Edith.app` and an
`/Applications` symlink for the drag-and-drop path; Homebrew ignores the symlink and
takes the bundle.

**The two `binary` lines** point inside the installed bundle, using `appdir`, which
is Homebrew's variable for the applications directory rather than a hard-coded
`/Applications`. This is the mechanism that makes `ed` and `edh` work immediately
after install, with no separate `ed install` step, and it is also the most
consequential line in the file, for reasons in section 15.

**`uninstall quit:`** lists all three bundle identifiers, as covered in section 8.
They are not guesses: `com.pulkit.edith` is `Resources/Info.plist`,
`com.pulkit.edith.statusbar` is `Resources/HelperInfo.plist`, and
`com.pulkit.edith.files` is the Files helper, named in
`Packages/Edith/Sources/EdithKit/Core/AppIdentity/MainApp.swift` and used by
`Packages/Edith/Sources/EdithCLI/AppBridge.swift`.

**`zap trash:`** covers the eight locations Edith writes outside its bundle. The
support directory and cache come from
`Packages/Edith/Sources/EdithCore/AppDirectories.swift`
(`~/Library/Application Support/Edith`, `~/Library/Caches/Edith`). The three
preference domains are the three bundles plus the shared suite from
`Packages/Edith/Sources/EdithKit/Core/Defaults/SharedDefaults.swift`
(`com.pulkit.edith.shared`). `HTTPStorages`, the Sparkle cache under
`com.pulkit.edith`, and saved application state are the standard macOS-side
leftovers any Cocoa app accumulates.

---

## 12. The release pipeline this plugs into

The cask bump is the last step of a single pipeline. Understanding where it sits
requires knowing what runs before it.

### Trigger

There is one entry point. `.github/workflows/ci.yml` runs on every pull request and
every push to `main`. Its `changes` job works out which areas a commit touched, the
check jobs run for the areas that moved, and a final `release` job calls
`.github/workflows/release.yml` as a reusable workflow.

That `release` job requires a push to `main`, a successful routing and policy job,
no applicable job failure or cancellation, and a change to the macOS app or Linux
package. The Ubuntu package, macOS build, Swift tests and Companion backend are each
required when their routed area changed. Checks and release are therefore the same
run, and the release cannot start until every applicable check has gone green.
There is no second workflow watching for a tag, and no tag trigger anywhere.

`ci.yml` skips itself when the head commit message starts with `Release v` or
`Refresh the contributor list`, which is what stops the pipeline's own commits from
starting another run. Those pushes use `RELEASE_PUSH_TOKEN`, and unlike the
`GITHUB_TOKEN` an Actions run is handed, a personal access token does trigger
further workflows: the message guard is the loop protection, not the token.

`ci.yml`'s concurrency group cancels in progress runs only for pull requests. On
`main` runs queue instead, because a release pushes to `main` while its own checks
are still finishing, and a cancelling group would kill the run that is mid-release.

### Build

`release.yml` has three jobs feeding a fourth.

**`version`** runs on Ubuntu, reads `Resources/Info.plist`, refuses to start without
the signing, Sparkle, push, and tap secrets, and computes the next patch version and
build number. It writes nothing and pushes nothing; it only decides what is being
released and which commit is being built.

**`dmg`** runs on macOS. It checks out the commit `version` chose, stamps both plists
with the release version, imports the signing certificate into a temporary keychain,
builds with `./build.sh --no-open --release`, checks the built bundle carries the
version it was told to build, packages a UDZO disk image with an `/Applications`
symlink inside, notarizes and staples when the notary secrets exist, generates the
Sparkle appcast signed with the Sparkle key, verifies the appcast points at the right
disk image and carries a signature, and uploads `Edith.dmg` and `appcast.xml`. It
also uploads the two stamped plists, so the bytes that go on to `main` are the exact
bytes that produced the disk image rather than a second, independent edit.

**`deb`** runs in a Swift container on Ubuntu, runs the portable tests, validates the
desktop metadata, builds the Debian package at the release version, checks its
version, installs it, runs `edith-linux --diagnose`, and uploads `Edith.deb`.

### Bump

**`publish`** is where every write happens, and it happens once. It downloads the
artifacts, commits the stamped plists and the rewritten cask together as a single
`Release vX.Y.Z` commit, tags it, pushes commit and tag atomically, creates the
GitHub release, mirrors the cask to the tap, and reads the tap back to confirm it
landed.

Two properties fall out of doing it in that order. A release costs exactly one commit
on `main`, where it used to cost two. And nothing is written until both builds have
passed, so a failed build leaves no tag, no bumped version, and no cask pointing at a
release that does not exist. The next merge simply tries the same version again.

To rebuild the current release when its assets need replacing, run the Release
workflow by hand from `main` with its required `rebuild` input set to that tag. The
workflow builds from the tag, replaces the three release assets, commits a changed
DMG checksum to `main` when necessary, and mirrors the cask to the tap. It refuses
older tags. This path does not create a new version or move the existing tag.

A new release cannot be cut from the Release workflow's manual entry point. To
recover an automatic release that CI skipped, dispatch the CI workflow from `main`
with its `release` input enabled. CI runs every routed product check and calls the
reusable Release workflow with `cut_release: true` only after they pass.

---

## 13. The cask bump

The `publish` job computes the disk image checksum and hands release-state updates
to `scripts/publish-release-state.sh`:

```bash
RELEASE_SHA256="$(sha256sum ../release-assets/Edith.dmg | cut -d' ' -f1)"
export RELEASE_SHA256
export RELEASE_PLISTS_DIR="$GITHUB_WORKSPACE/release-plists"
../scripts/publish-release-state.sh cut
```

For a rebuild it exports the newly computed checksum and invokes the same script
with `rebuild`. The script validates the tag, version and checksum; rewrites the
cask through a temporary file; verifies both fields; and owns the appropriate git
commit and push. Keeping those rules in a tested script lets CI exercise the cut
and rebuild behavior without duplicating shell logic in the workflow.

Design notes on the parts that are not obvious.

**`RELEASE_PUSH_TOKEN`, not `GITHUB_TOKEN`.** `main` is protected by a ruleset
requiring pull requests and status checks. The token an Actions run is handed cannot
bypass it, and on a personal repository the GitHub Actions app cannot be added to a
ruleset bypass list at all: the API answers `Actor GitHub Actions integration must
be part of the ruleset source or owner organization`. The ruleset does grant the
repository admin role an unconditional bypass, and a fine grained personal access
token acts as its owner, so checking out with one lets the push through. This is the
standard arrangement for a personal repository that both protects its default branch
and automates its releases; the same secret carries the version bump in the same
commit.

**`ref: main`, not the tag.** `publish` checks out `main` and creates the tag itself,
at the release commit it has just written. The commit has to land on the branch
people install from, and tagging it afterwards means the tag names a tree whose
plists and cask both describe the release that exists.

**The artifact, not the release.** The checksum comes from
`actions/download-artifact`, the same bytes the `dmg` job produced and `publish`
uploaded, rather than from re-downloading the published asset. One less network
dependency, and no window in which a re-download could differ from what was
published.

**`sed` with anchored patterns.** `^  version "..."$` matches the stanza with its
exact two-space indentation, so nothing else in the file can be hit by accident.

**Verify the rewrite.** `grep -qx` after the `sed` turns a silent no-op into a
failure. A `sed` expression that matches nothing exits successfully, which is
exactly the sort of thing that produces a tap pinned to an old version for months
without anyone noticing.

The cut path in `publish-release-state.sh`:

```bash
git fetch origin main --tags
[[ "$(git rev-parse HEAD)" == "$BUILT_SHA" ]]
[[ "$(git rev-parse origin/main)" == "$BUILT_SHA" ]]
cp "$RELEASE_PLISTS_DIR/Info.plist" Resources/Info.plist
cp "$RELEASE_PLISTS_DIR/HelperInfo.plist" Resources/HelperInfo.plist
rewrite_cask
verify_cask
git add Resources/Info.plist Resources/HelperInfo.plist Casks/edith.rb
git commit -m "Release ${RELEASE_TAG}"
git tag "$RELEASE_TAG"
git push --atomic origin HEAD:main "refs/tags/$RELEASE_TAG"
```

**One commit.** The plists and the cask move together, so a release is a single
`Release vX.Y.Z` commit rather than a bump commit followed by a cask commit. The
plists are copied from the `dmg` job's artifact, so they are the same bytes that were
built rather than a re-derived edit that could drift.

**Refuse a moving base.** `main` can move while a release builds. The script verifies
that both its checkout and the latest `origin/main` still equal the commit CI built.
If another change landed, the release stops before writing anything instead of
combining checked artifacts with a different source revision. The next CI run can
release the new head.

**Atomic.** `git push --atomic` sends the branch and the tag as one update. Either
both land or neither does, so there is no window in which `main` carries a version
that no tag names, or a tag exists for a commit that was never pushed.

**No release loop.** The commit message starts with `Release v`, which `ci.yml`'s
`changes` job refuses to run on. This is load-bearing: a release commit that
triggered a release would produce an infinite chain of version bumps.

The mirror step:

```yaml
      - name: Mirror the cask to the tap repository
        env:
          TAP_PUSH_TOKEN: ${{ secrets.TAP_PUSH_TOKEN }}
        run: |
          git clone --depth 1 \
            "https://x-access-token:${TAP_PUSH_TOKEN}@github.com/pulkitxm/homebrew-tap.git" tap
          cp release-source/Casks/edith.rb tap/Casks/edith.rb
          cd tap
          if git diff --quiet -- Casks/edith.rb; then
            echo "the tap already carries $RELEASE_TAG"
            exit 0
          fi
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add Casks/edith.rb
          git commit -m "Update the Edith cask to ${RELEASE_TAG}"
          git push origin HEAD:main
```

**Why a token.** `GITHUB_TOKEN` is scoped to the repository the workflow runs in. It
cannot push to a different repository, so a cross-repository push needs a credential
of its own: a fine-grained personal access token scoped to `pulkitxm/homebrew-tap`
with read and write access to contents, stored as `TAP_PUSH_TOKEN`.

**Fail rather than skip.** The version job refuses to start without the token, and
the mirror step fails on any clone or push error. A silent skip could publish a
release while leaving the tap that users install from on the previous version.
Blocking before the build when the secret is absent, and failing loudly on a later
transport error, keeps that drift visible.

---

## 14. The tap repository

[pulkitxm/homebrew-tap](https://github.com/pulkitxm/homebrew-tap) contains a
`Casks/edith.rb` and a `README.md`. That is the entire repository.

It is generated output. The cask is authored in this repository, next to the source
it installs, and the release job copies it across. Editing the tap directly means
the next release silently overwrites your change, which is why the tap README says
so at the top.

The `homebrew-` prefix is required for the short `pulkitxm/tap` form, per the naming
rule in section 4. The name after it, `tap`, is deliberately generic: the same
repository can carry casks and formulae for other projects later without a second
tap to clone or a second name to remember.

**Why not use this repository as the tap.** Homebrew can tap any repository if you
give it the URL, and the first implementation did exactly that. Two problems drove
the change. The command was
`brew tap pulkitxm/edith https://github.com/pulkitxm/edith` followed by an install,
which is two commands and a URL for something that should be one line. And tapping
clones the whole repository, roughly 50 MB of application source, videos and
history, into Homebrew's own checkout, where `brew update` then pulls it forever.
The tap repository is a few kilobytes.

---

## 15. Decision log

### Why not homebrew-cask upstream

The shortest possible command is `brew install --cask edith`, with no tap, and it
requires being in the `homebrew/cask` tap that ships with Homebrew. That has an
explicit notability bar, from Homebrew's Package Acceptance Policy:

> at least 30 forks, 30 watchers or 75 stars

and, for someone submitting their own project:

> at least 90 forks, 90 watchers or 225 stars for a self-submission by the
> repository owner

Also:

> A code repository less than 30 days old is normally not eligible

At the time of writing, `pulkitxm/edith` has 2 stars, 4 forks and 0 watchers. A
submission today is closed on the notability rule regardless of the quality of the
cask. The 30-day rule is satisfied.

Two things are worth recording for when the numbers change.

The `edith` token is unclaimed upstream: `formulae.brew.sh/api/cask/edith.json`
returns 404 and none of the 7,690 casks in the API index use it. The name will be
there.

The `binary "ed"` line is the likely sticking point in review. There is no
documented rule that forbids shadowing a system binary, so this is a judgement call
rather than a citation, but a cask that puts an `ed` ahead of `/usr/bin/ed` for
every user who installs it is the sort of thing reviewers push back on. The likely
outcome is dropping that line upstream while keeping it in the tap.

There is a second cost to upstreaming that is easy to miss: version bumps stop being
yours. Instead of the `publish` job mirroring the cask, each release becomes a pull
request into a queue reviewed by other people. For a project releasing patch
versions frequently, that is a real change in release latency.

### Why the tap is a separate repository

Covered in section 14: one command instead of two, no URL, and a clone measured in
kilobytes rather than tens of megabytes.

### Why `pulkitxm/tap/edith` and not something shorter

Section 5 has the regex. Three segments are required, two-segment names do not
parse, and a bare token cannot resolve on a machine with no tap. The only free
choice is the middle segment, which is the tap repository name. `pulkitxm/edith/edith`
was the first attempt and reads badly, hence `homebrew-tap`.

### Why both `ed` and `edh` are linked

The alternative was linking `edh` only and leaving `ed` to the app's own
`ed install --directory ~/.local/bin` flow, which avoids shadowing the POSIX line
editor.

Linking both was chosen deliberately: the CLI is a first-class half of this project,
`ed` is its name, and an install that does not give you `ed` is not the product.
The cost is documented in three places rather than hidden, and `/usr/bin/ed` remains
available by absolute path for anyone who wants the editor.

This is the one decision in the whole design with a real trade-off against other
software on the user's machine. It is worth revisiting if anyone reports it.

### Why `auto_updates true`

Section 7. Sparkle owns updates; the cask says so rather than competing.

### Why the cask lives in this repository

The tap could have been the source of truth, with the cask edited there. Keeping it
here means the packaging sits next to the thing it packages, the release workflow
can rewrite it without a second checkout, and the same tests that guard the CLI and
the docs guard the cask.

---

## 16. Runbook

### Cut a release

Nothing Homebrew-specific to do. Merge to `main` and let CI call the release
workflow after every required check passes. To rebuild the current release, run
the Release workflow manually from `main` with `rebuild` set to its tag. The
`publish` job refreshes the release assets, updates this repository if the checksum
changed, and mirrors the cask to the tap.

Confirm afterwards:

```
gh api repos/pulkitxm/homebrew-tap/contents/Casks/edith.rb --jq .content | base64 -d | head -3
```

The `version` line should be the release you just cut.

### Set up the two push tokens

Both are required once, before the first release that mirrors the cask.

`RELEASE_PUSH_TOKEN` lets the release jobs push to a protected `main`: a fine
grained token scoped to `pulkitxm/edith` with read and write access to Contents,
created by someone with the repository admin role, whose ruleset bypass it inherits.

```
gh secret set RELEASE_PUSH_TOKEN --repo pulkitxm/edith
```

`TAP_PUSH_TOKEN` lets the mirror step push to the tap.

1. Create a fine-grained personal access token.
2. Scope it to `pulkitxm/homebrew-tap` only.
3. Give it read and write access to Contents.
4. Add it to `pulkitxm/edith` as `TAP_PUSH_TOKEN`:

```
gh secret set TAP_PUSH_TOKEN --repo pulkitxm/edith
```

Rotating it is the same command with a new value. Nothing else needs to change.

### Fix a broken checksum

If the tap names a version whose checksum is wrong, every install fails at
verification. Recompute from the published asset and correct both repositories:

```
curl -sL -o /tmp/Edith.dmg \
  "https://github.com/pulkitxm/edith/releases/download/vX.Y.Z/Edith.dmg"
shasum -a 256 /tmp/Edith.dmg
```

Edit `Casks/edith.rb` here, commit, and copy the file to the tap. Do not fix the tap
alone: the next release overwrites it from this repository.

### Roll the tap back

Casks have no version history of their own; the git history is the version history.
Revert the tap's last commit and the previous version is live again. Do the same
here so the next release does not restore the bad version.

### Add another project to the tap

Add its cask or formula to `pulkitxm/homebrew-tap` and give that project's release
pipeline the same mirror step, pointed at its own file. The tap name stays
`pulkitxm/tap`, so the install command for the new project is
`brew install --cask pulkitxm/tap/<token>`.

### Check whether the tap is stale

```
brew livecheck --cask pulkitxm/tap/edith
```

Compares the cask's version against the newest GitHub release, which is exactly the
question worth asking after a failed release run.

---

## 17. Failure modes

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Cask 'edith' is unavailable` on a new machine | Bare token with no tap installed | Use `brew install --cask pulkitxm/tap/edith` |
| Error naming `pulkitxm/edith` | Two-segment name, does not match the tap regex | Three segments: `pulkitxm/tap/edith` |
| `SHA256 mismatch` | Cask version and checksum are out of step, or the release asset was replaced | Recompute from the published DMG, fix both repositories |
| Release green, tap still on the old version | `publish` job's mirror step failed, usually an expired `TAP_PUSH_TOKEN` | Fix the secret, re-run the job |
| `GH013: Repository rule violations found for refs/heads/main` | A job pushed to `main` with `GITHUB_TOKEN`, which no ruleset bypass covers | Check out with `RELEASE_PUSH_TOKEN` |
| `brew upgrade` never updates Edith | `auto_updates true`, working as designed | `brew upgrade --cask --greedy edith` |
| `brew info` shows an older version than the running app | Sparkle updated in place | Cosmetic; a greedy upgrade re-syncs it |
| Gatekeeper warning on first launch | Build was not notarized; Homebrew applied quarantine like any download | Notary secrets in the release workflow |
| `ed` runs Edith instead of the editor | `binary "ed"` links ahead of `/usr/bin` on `PATH` | `/usr/bin/ed`, documented behaviour |
| Uninstall leaves the menu bar icon | A helper process still running | `uninstall quit:` handles it; if it persists, quit Edith first |
| `brew update` is slow | Every installed tap is fetched | Not this tap's doing at a few kilobytes; check `brew tap` for large third-party taps |

---

## 18. What was verified, and how

Casks are macOS-only and this was built on Linux, so it is worth being explicit
about which claims are tested and which are structural.

**Verified directly:**

- The cask is syntactically valid Ruby (`ruby -c Casks/edith.rb`).
- The checksum in the cask is the SHA-256 of the published `Edith.dmg` for v0.0.98,
  computed from the downloaded asset.
- The URL the cask interpolates resolves to that published asset.
- The tap repository clones and contains `Casks/edith.rb`, which is exactly what
  `ensure_installed!` does during an install.
- The bundle identifiers in `uninstall quit:` match `Resources/Info.plist`,
  `Resources/HelperInfo.plist`, `MainApp.swift` and `AppBridge.swift`.
- The zap paths match `EdithCore/AppDirectories.swift` and
  `EdithKit/Core/Defaults/SharedDefaults.swift`.
- `ed` and `edh` exist at the linked paths inside the built bundle, asserted by
  `make verify-bundle`.
- Homebrew's name resolution rules, quoted in sections 4 and 5, from
  `tap_constants.rb` and `cmd/install.rb`.
- `scripts/homebrew-cask.test.js` guards the cask's shape, the release job's
  behaviour, and the documented command, and runs in CI whenever `Casks/` changes.

**Not verifiable here:**

- `brew install --cask pulkitxm/tap/edith` end to end. Homebrew refuses cask
  installs on Linux, so this needs a Mac.

---

## 19. Glossary

**appcast** A signed XML feed of available updates. Sparkle reads Edith's from the
GitHub release.

**artifact stanza** A cask line describing something to install: `app`, `binary`,
`pkg`, `suite`, `installer`.

**bottle** A precompiled build of a formula.

**cask** A description of a prebuilt macOS application.

**Caskroom** `$(brew --caskroom)`, where casks are staged and recorded.

**Cellar** `$(brew --cellar)`, where formulae are installed.

**formula** A description of command line software.

**Gatekeeper** The macOS check on first launch of a quarantined app.

**greedy** `--greedy`, include casks marked `auto_updates true`.

**notarization** Apple's scan-and-ticket service for distributed software.

**prefix** `$(brew --prefix)`, the root of a Homebrew installation.

**quarantine** The `com.apple.quarantine` attribute macOS attaches to downloads.

**Sparkle** The macOS update framework Edith embeds.

**tap** A git repository of formulae and casks.

**token** A cask's short name, matching its filename.

**zap** The opt-in deep uninstall that removes user data too.

---

## 20. Sources

Homebrew documentation and source, read rather than recalled:

- [Taps](https://docs.brew.sh/Taps), naming rules and the two-argument form.
- [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook), stanzas, token rules and the
  Caskroom path.
- [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks).
- [Package Acceptance Policy](https://docs.brew.sh/Package-Acceptance-Policy),
  quoted notability thresholds.
- `Library/Homebrew/tap_constants.rb`, the name regexes.
- `Library/Homebrew/cmd/install.rb`, automatic tapping of qualified names.
- `Library/Homebrew/cask/cask_loader.rb`, cask loading from an installed tap.

In this repository:

- [docs/homebrew.md](homebrew.md), the command reference.
- `Casks/edith.rb`, the cask.
- `.github/workflows/release.yml`, the release publisher and cask mirror.
- `scripts/homebrew-cask.test.js`, the tests.
