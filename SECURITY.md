# Security Policy

## Supported Versions

Security fixes are applied to the latest published release and the `main`
branch.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| `main` | Yes |
| Older releases | No |

## Reporting a Vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's
[private vulnerability reporting form](https://github.com/pulkitxm/edith/security/advisories/new)
so the report and follow-up remain confidential.

Include the affected version, macOS version, reproduction steps, expected and
observed behavior, potential impact, and any suggested mitigation. Remove
credentials, private repository contents, personal data, and local usage
history from the report.

The maintainer aims to acknowledge a complete report within three business
days and provide an initial assessment within seven business days. Remediation
and disclosure timing depend on severity, complexity, and release availability.
The reporter will receive updates when the assessment changes materially.

Please allow time for a fix and coordinated disclosure before publishing
details. A GitHub security advisory will be used to request a CVE when one is
warranted.

## Safe Harbor

Good-faith research that follows this policy is considered authorized. Avoid
privacy violations, service disruption, destructive testing, social
engineering, and access beyond what is necessary to demonstrate the issue.
Stop testing and report immediately if you encounter sensitive data. The
project will not pursue action against researchers who follow these rules and
make a reasonable effort to avoid harm.

## Security Model

Edith is a native macOS application with access to user-approved system
capabilities and local development data. It reads usage histories, calendars,
the pasteboard, media state, files selected by the user, and configured SSH
hosts. Commands run with the permissions of the signed-in macOS user. Only add
machines, repositories, extensions, and media sources that you trust.

The optional Companion backend stores its database and model data on the host
chosen by the user. Its API, PostgreSQL, and Redis ports bind to loopback by
default. Remote deployments are reached through SSH forwarding. Provider keys
and connector tokens are passed directly to the configured backend and must be
protected like other credentials.

Official updates are distributed through GitHub Releases. Sparkle verifies the
signed appcast before installing an update. Release workflows build from the
repository, sign the application, and publish checksummed release state.

Reports are especially useful when they demonstrate credential exposure,
command or argument injection, writes outside an intended directory, unsafe
remote-machine actions, access to Companion from outside its configured trust
boundary, update verification bypass, or a privacy control that fails open.
