# `ed machines power reboot`

Restarts a configured remote Mac. Nothing happens unless `--yes` is present.

```text
ed machines power reboot studio --yes
```

With `--json`, success returns the machine name, action, and remote command. Edith runs `sudo -n shutdown -r now` by default. When the account requires a password, save it with `ed machines edit <machine> --sudo-password-stdin`.

The SSH connection can close before the final output arrives because the remote Mac is restarting. Edith treats a cleanly accepted command as success.

- [Machine power and processes](./README.md)
- [All `ed` commands](../README.md)
