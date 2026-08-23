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
cmux, which must be installed separately in Applications. The theme applies to
embedded terminal sessions. Both settings are available to scripts:

```sh
ed config set quinjetTerminal embedded
ed config set quinjetTheme tokyo-night
```

If Quinjet is missing, retry `ed tools install quinjet` or run
`brew install pulkitxm/tap/quinjet`. If cmux is unavailable, switch the terminal
back to `embedded`. Disable and re-enable the extension only to control its
visibility. It does not uninstall the command line tool or erase these settings.
