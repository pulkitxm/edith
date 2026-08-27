# Quinjet

Quinjet reviews pull requests and follows live workspace changes from an Edith
panel tab. Enable it in Settings under Extensions, or run:

```sh
ed extensions enable quinjet
ed tools install quinjet
```

The extension needs the `quinjet` executable on Edith's assembled PATH. Verify
the installation without opening the app:

```sh
ed tools ls --json | jq '.[] | select(.id == "quinjet")'
ed extensions info quinjet --json
```

Choose `embedded` to run workspaces inside Edith. Choose `cmux` to open them in
cmux, which must be installed separately in Applications. The default `app`
theme sends Edith's own light and dark palettes to Quinjet. Changing Edith's
theme or appearance updates every open Quinjet session. Choosing a named Quinjet
theme keeps that explicit palette while still following light and dark appearance.
Named themes are discovered from the installed Quinjet version, so new Quinjet
palettes appear without an Edith update.
Both settings are available to scripts:

```sh
ed config set quinjetTerminal embedded
ed config set quinjetTheme app
ed config set quinjetTheme tokyo-night
```

If Quinjet is missing, retry `ed tools install quinjet` or run
`brew install pulkitxm/tap/quinjet`. If cmux is unavailable, switch the terminal
back to `embedded`. Disable and re-enable the extension only to control its
visibility. It does not uninstall the command line tool or erase these settings.
