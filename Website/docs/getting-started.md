# Getting started

Install the `photon` command, serve a folder, then grow into a config file when you need TLS,
compression, logs or more than one site.

## Requirements

- macOS 15 or later. PhotonHTTP is built on Darwin and Network.framework and is not built or
  tested on Linux.
- A Swift 6.4 toolchain, from Xcode or [swift.org](https://www.swift.org/install/macos/). The
  installer builds from source.

## Install

One command clones [the repository](https://github.com/brennanMKE/PhotonHTTP), builds a
release binary with your Swift toolchain and installs `photon` to `~/.local/bin`. It needs no
sudo.

```bash
curl -fsSL https://photon-http.sstools.co/install.sh | bash
```

Pass options after `bash -s --`:

```bash
curl -fsSL https://photon-http.sstools.co/install.sh | bash -s -- --prefix ~/opt --version main
```

| Option | Meaning |
|---|---|
| `--prefix DIR` | Install to `DIR/bin` instead of `~/.local/bin`. It must be writable: the installer never uses sudo |
| `--version REF` | The git tag or branch to build. Default `main` |

From a checkout of the repository, run the same installer directly:

```bash
scripts/install.sh
```

Check that your shell finds it:

```bash
photon --help
```

If it says `command not found`, `~/.local/bin` is not on your `PATH` yet. Add it in
`~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

**Uninstall** by deleting the binary: `rm ~/.local/bin/photon` (or `DIR/bin/photon` with
`--prefix`). It has no other files and no dependencies outside the system.

## Serve a folder

`photon serve` serves a directory as a static website: the current directory unless you name
one. `/` and every directory serve their `index.html`.

```bash
cd ~/Sites/example
photon serve
# listening 127.0.0.1:8080
```

Open `http://127.0.0.1:8080/` in a browser, or check it with `curl http://127.0.0.1:8080/`.
Press Ctrl-C to stop the server.

```
photon serve [DIR] [--port PORT] [--host HOST]
```

| Argument | Default | Meaning |
|---|---|---|
| `DIR` | current directory | The directory to serve |
| `--port PORT` | `8080` | The port to listen on; `0` picks any free port (the `listening` line shows which) |
| `--host HOST` | `127.0.0.1` | The address to bind. `127.0.0.1` means only this Mac can connect; `0.0.0.0` shares the site on your network |

```bash
photon serve public --port 8000          # serve ./public on port 8000
photon serve ~/Sites/example --port 0    # any free port
photon serve . --host 0.0.0.0            # reachable from other devices on your network
```

`photon serve` always does plain static serving: it ignores any `http-config.json` in the
folder. With the macOS firewall on, the first time a newly built `photon` listens on `0.0.0.0`
macOS asks whether to accept incoming connections; see
[binding to all interfaces and the firewall prompt](https://photon-http.sstools.co/docs/running-on-a-mac.md#binding-to-all-interfaces-and-the-firewall-prompt).

## When you need more: a config file

TLS, HTTP/2 and HTTP/3, compression, access logs, virtual hosts, authentication and the reverse
proxy are configured in one JSON file, `http-config.json`, which you pass with
`photon --config`. Every key is optional; relative paths resolve against the file's directory.

```json
{
  "root": "public",
  "compression": true,
  "caching": { "maxAge": 600 },
  "errorPages": { "404": "errors/404.html" },
  "accessLog": { "path": "logs/access.log", "format": "combined" }
}
```

```bash
photon --config http-config.json
# listening 127.0.0.1:8080
```

A running server picks up edits to the file by itself, or on SIGHUP, without dropping
requests. `photon check` validates a config, and `photon reload`, `photon status` and
`photon restart` talk to the running server. Every key and command is in
[Running on a Mac](https://photon-http.sstools.co/docs/running-on-a-mac.md).

## Next steps

- [Static websites](https://photon-http.sstools.co/docs/static-sites.md): caching and ETags, Range, error pages, compression,
  virtual hosts and authentication.
- [Running on a Mac](https://photon-http.sstools.co/docs/running-on-a-mac.md): every command and config key, certificates, ports
  80 and 443, LaunchAgents, logs, reload.
- [TLS](https://photon-http.sstools.co/docs/tls.md): HTTPS, HTTP/2 and HTTP/3 with a PKCS#12 identity loaded in memory, never the
  keychain.
- [Dynamic websites](https://photon-http.sstools.co/docs/dynamic-sites.md): proxy paths to a local app, or write handlers in Swift
  with Router and WebSockets.
- [Choosing components](https://photon-http.sstools.co/docs/choosing-components.md): build your own server as a Swift package from
  the parts you need.
- [Overview and architecture](https://photon-http.sstools.co/docs/overview.md): how the pieces fit.
