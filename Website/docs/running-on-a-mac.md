# Running on a Mac

## Install

```bash
curl -fsSL https://photon-http.sstools.co/install.sh | bash
```

The installer clones the repository, builds a release `photon` with your Swift toolchain and
installs it to `~/.local/bin/photon`. It never uses `sudo`; if `~/.local/bin` is not on your
`PATH` it prints the line to add. Options (after `bash -s --`):

| Option | Meaning |
|---|---|
| `--prefix DIR` | Install to `DIR/bin` instead of `~/.local/bin` (must be writable) |
| `--version REF` | Git tag or branch to build (default `main`) |

From a checkout, `scripts/install.sh` builds and installs that checkout. Run the installer
again to update. Uninstall with `rm ~/.local/bin/photon`.

Requirements: macOS 15 or later and a Swift 6.4 toolchain (Xcode or swift.org).

### Build by hand

```bash
swift build -c release -j 2 --product photon     # or scripts/build.sh
.build/release/photon --help
```

The binary has no dependencies outside the system, so you can copy `.build/release/photon`
anywhere, e.g. `/usr/local/bin` or `~/bin`.

## Serve a folder

```bash
cd ~/Sites/my-site
photon serve                        # http://127.0.0.1:8080/
photon serve ~/Sites/blog --port 9000
```

```
photon serve [DIR] [--port PORT] [--host HOST]
```

`photon serve` serves `DIR` (default: the current directory) as a static website. A request
for `/` or any directory serves its `index.html`; a directory requested without the trailing
slash redirects to it. `--port` defaults to `8080` (`0` picks a free one) and `--host` to
`127.0.0.1`, so only this Mac can connect; `--host 0.0.0.0` shares the site with your network
(see [the firewall prompt](#binding-to-all-interfaces-and-the-firewall-prompt)). It prints
`listening HOST:PORT` once ready; Ctrl-C stops.

`serve` never reads `http-config.json`, so a stray config file cannot change what it does.
For HTTPS, compression, access logs, error pages or virtual hosts, write a config and run
`photon --config FILE` (below).

## Command line

```
photon [--config FILE] [--root DIR] [--host HOST] [--port PORT]
```

| Flag | Meaning |
|---|---|
| `--config FILE` | The JSON config. Without it: `$ROOT_PATH/http-config.json` when `ROOT_PATH` is set, else `./http-config.json` if it exists, else built-in defaults |
| `--root DIR` | Directory to serve; overrides `root`. Relative to the working directory |
| `--host HOST` | Numeric address to bind; overrides `host` |
| `--port PORT` | Cleartext port; overrides `port`. `0` picks a free one |
| `--help`, `-h` | Usage |

`--flag=value` works too. Output:

- stderr: `photon: serving /abs/root` (or one line per virtual host), config warnings,
  `signal 15, shutting down`, `stopped`, and errors.
- stdout: `listening 127.0.0.1:8080` once bound, then `listening 127.0.0.1:8443 (https)` and
  `listening 127.0.0.1:8443 (h3)` for the other listeners. Scripts can wait for the first line.
  The access log also goes to stdout when configured that way.

Exit status: `0` after a graceful stop, `1` on a configuration or startup error (bad value,
missing root, unreadable identity, port in use) with a message naming the key, `2` on a usage
error.

### Control commands

The same executable checks a config and talks to a running server (#0143). It finds the server
through its status file (`statusFile`, default `run/status.json` next to the config) and
signals its pid; there is no control socket, so nothing new is reachable over the network.

```
photon check   [--config FILE] [--root DIR] [--host HOST] [--port PORT]
photon reload  [--config FILE] [--root DIR] [--host HOST] [--port PORT] [--timeout SECONDS]
photon status  [--config FILE] [--json]
photon restart [--config FILE] [--root DIR] [--host HOST] [--port PORT] [--timeout SECONDS]
```

| Command | What it does |
|---|---|
| `check` | Loads and builds the config as a reload would (root, error pages, credential files, the TLS identity in memory only) and prints `PATH: valid` or `PATH: invalid: …`. When a server runs with this config, it also prints which keys would change: `can hot-reload: root changed`, `no setting changes` (a reload still rereads the identity and credential files), or `needs a restart: port changed and needs a restart; run `photon restart` to apply them` |
| `reload` | Runs `check`; when the config is valid and needs no restart, sends SIGHUP and waits (up to `--timeout`, default 10 s) for the server to record the outcome, then prints `reloaded: …`, `reload failed, …` or `reload rejected, …`. It does not signal when the config is invalid or needs a restart |
| `status` | Prints the status file: state and pid, listening addresses, config path and SHA-256, the last reload (time, `signal` or `watch`, result, message), the reload count and any restart-required keys. `--json` prints the file itself |
| `restart` | Runs `check`; when the config is valid (whether or not it needs a restart), sends SIGUSR2 and waits (up to `--timeout`, default 10 s) for the outcome: `restarted (changed: port); listening …` or `restart failed, the running server keeps serving: …`. The [graceful restart](#graceful-restart) happens in the same process, so launchd sees one pid. It does not signal when the config is invalid |

Without `--root`/`--host`/`--port`, `check`, `reload` and `restart` apply the overrides the
running server was started with (recorded in the status file). Exit status: `0` success, `1`
invalid config, no running server, a failed reload or restart, or a timeout, `2` usage error,
`3` a restart is required (the reload was or would be rejected).

The status file is JSON, rewritten atomically (temporary file, then rename) with mode 0600 at
startup once the listeners are bound, after every reload and restart and at a clean exit
(`"state": "stopped"`). It holds `pid`, `started`, `config`, `configSHA256` (of the file as
last loaded), `arguments`, `listening`, `reloads` (reloads and restarts), `lastReload`
(`time`, `trigger`: `signal` / `watch` / `restart`, `result`: `reloaded` / `failed` /
`rejected` / `restarted`, `message`, `changed`, `restartRequired`), `restarted` (time of the
last graceful restart), `restartRequired` (keys changed in the file but not applied; empty
after a successful reload or restart) and `settings`: a digest per key of the running values, never the values themselves,
so `check` can compare without the file holding passwords. It is written only when the server
runs with a config file.

## `http-config.json` reference

The file is one JSON object. **Every key is optional**: a missing key keeps its default, so
`{}` (or no file) is a valid config serving `./Public` on `127.0.0.1:8080`. Unknown keys print
a warning and are ignored. A wrong type or out-of-range value stops the server (exit 1) with a
message such as `"timeouts.idle" must be a number of seconds`. **Relative paths resolve
against the directory holding the config file** (except `--root`).

Durations are numbers of seconds (fractions allowed, at most one year). For the HTTP/1.1
`timeouts` and the proxy's `proxy[].timeouts` (`connect`, `response`, `idle`, `total`), `0` or
`null` turns a limit off; leaving a key out keeps its default. Turn off the proxy's `idle` and
`response` limits (or set them large) for long-polling or streaming upstreams such as
server-sent events.

[`Root/http-config.json`](https://github.com/brennanMKE/PhotonHTTP/blob/main/Root/http-config.json) spells out the core defaults;
[`Root/http-config.tls.json`](https://github.com/brennanMKE/PhotonHTTP/blob/main/Root/http-config.tls.json) adds HTTPS and HTTP/3;
[`Root/http-config.proxy.json`](https://github.com/brennanMKE/PhotonHTTP/blob/main/Root/http-config.proxy.json) adds a reverse-proxy mount.

### Listening and limits

| Key | Type | Default | Meaning |
|---|---|---|---|
| `host` | string | `"127.0.0.1"` | Numeric address to bind. `"0.0.0.0"` (IPv4) or `"::"` serves the network |
| `port` | integer 0–65535 | `8080` | Cleartext TCP port; `0` picks one |
| `transport` | `"bsd"` \| `"nw"` | `"bsd"` | Cleartext transport: POSIX sockets + kqueue, or Network.framework |
| `maxConnections` | integer ≥ 1 | `1024` | Connections served at once across all listeners; more wait in the listen backlog |
| `maxBodySize` | integer bytes | `10485760` | Largest request body (`413` above). Legacy alias `maxRequestSize` |
| `timeouts` | object | see below | HTTP/1.1 time limits in seconds |
| `timeouts.header` | seconds | `10` | Request head must complete (`408`) |
| `timeouts.idle` | seconds | `5` | Idle keep-alive connection closed; also an idle HTTP/2 connection (`GOAWAY`). Legacy `keepAliveTimeout` |
| `timeouts.body` | seconds | `30` | Longest wait for request body bytes (`408`) |
| `timeouts.send` | seconds | `30` | Longest wait for the client to accept response bytes |
| `timeouts.linger` | seconds | `2` | Lingering close after an error response |
| `drainTimeout` | seconds or `null` | `10` | Graceful stop waits this long for open connections; `null` waits indefinitely (`0` cancels at once) |
| `reload` | bool or object | `{"watch": true, "interval": 2}` | Hot reload when the config or a file it names changes ([reload](#shutdown-restart-and-reload)). `false` reloads on SIGHUP only |
| `reload.watch` | bool | `true` | Poll the files with `stat` and reload on a change |
| `reload.interval` | seconds 0.01–3600 | `2` | Time between polls |
| `statusFile` | path, `false` or `null` | `"run/status.json"` | Status file for the [control commands](#control-commands), relative to the config's directory; `false` turns it off |

### Files

| Key | Type | Default | Meaning |
|---|---|---|---|
| `root` | string | `"Public"` | Directory to serve. Legacy alias `path` |
| `index` | string or array | `["index.html"]` | Index files tried in order for a directory. Legacy alias `defaultIndex` |
| `mimeTypes` | object | `{}` | Extra or overriding types: `{"md": "text/markdown; charset=utf-8"}`. The legacy array form `[{"contentType": …, "pathExtensions": […]}]` is accepted |
| `defaultMimeType` | string | `"application/octet-stream"` | For unknown extensions |
| `blockList` | array of strings | `["http-config.json", ".git", ".DS_Store"]` | Path components answered `403` anywhere in the path, case-insensitively |
| `blockDotfiles` | bool | `true` | `403` for any component starting with `.`, except `.well-known` |
| `caching` | bool or object | `{"enabled": true, "maxAge": 3600}` | `Cache-Control: public, max-age=N` on files and `304`s; `false` or `"enabled": false` sends none |
| `errorPages` | bool or object | `true` | `true`: generated HTML pages for bodiless `4xx`/`5xx`; `false`: none; `{"404": "errors/404.html"}`: files relative to `root` (other statuses keep the generated page); with `hosts`, each site's root first, then `root` |
| `compression` | bool or object | off | See [Compression](#compression) |
| `enableETags` | – | – | Legacy, no effect (ETags are always sent); accepted with a warning |
| `enableCompression` | bool | – | Legacy; `true` is `"compression": true` (ignored when `compression` is set) |

### Compression

`"compression": true` uses every default, or an object:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | `false` turns it off |
| `encodings` | array | `["br", "gzip", "deflate"]` | Codings offered, from `br`, `gzip`, `deflate` |
| `minimumSize` | integer bytes | `1024` | Smaller bodies are sent as they are |
| `level` | integer 1–9 | `4` | zlib level for per-response gzip/deflate |
| `precompressionLevel` | integer 1–9 | `9` | Level for static-file variants compressed once into the cache |
| `mimeTypes` | array | `text/*`, JSON, JavaScript, XML (incl. SVG), wasm, YAML, TOML, some fonts and icons | Types that are compressed; `*` wildcards allowed |
| `precompress` | bool | `true` | Compress small static files once into the file cache |
| `sidecars` | bool | `true` | Serve `file.br` / `file.gz` next to a file as its variants |

### TLS, HTTP/2 and HTTP/3

| Key | Type | Default | Meaning |
|---|---|---|---|
| `tls` | object, `false` or `null` | off | HTTPS listener |
| `tls.identity` | string (required) | – | PKCS#12 file (certificate chain + key), relative to the config file. Loaded in memory only |
| `tls.password` | string | – | Its password; or |
| `tls.passwordEnv` | string | – | Name of an environment variable holding the password (exactly one of the two) |
| `tls.port` | integer | `8443` | TCP port; must differ from `port`; `0` picks one |
| `tls.enabled` | bool | `true` | `false` turns it off |
| `http2` | bool or object | on | HTTP/2. On by default (offered on HTTPS via ALPN); `false` or `"enabled": false` serves HTTP/1.1 only |
| `http2.cleartext` | bool | `false` | Also accept h2c with prior knowledge on the cleartext port (every cleartext connection is then sniffed) |
| `http2.maxConcurrentStreams` | integer 0–65536 | `100` | `SETTINGS_MAX_CONCURRENT_STREAMS` |
| `http2.initialWindowSize` | integer 0–2147483647 | `65535` | Per-stream receive window |
| `http2.maxRequestBodySize` | integer or `null` | `maxBodySize` | Largest request body on HTTP/2 |
| `http2.abuseLimits` | object | defaults | DoS limits (counts per `window`; `null` turns one off): `window` (s, 10), `maxResetStreamsPerWindow` (100), `maxControlFramesPerWindow` (1000), `maxEmptyFramesPerWindow` (100), `maxWindowUpdatesPerWindow` (10000), `maxSmallDataFramesPerWindow` (1000), `smallDataFrameSize` (256), `windowStallTimeout` (s, 30), `maxStreamsPerConnection` (100000). Background: [HTTP2.md](https://github.com/brennanMKE/PhotonHTTP/blob/main/docs/HTTP2.md) |
| `http3` | bool or object | off | HTTP/3 over QUIC; **needs `tls`**. `true` = defaults |
| `http3.port` | integer or `null` | TLS port number | UDP port (the same number as HTTPS is normal: TCP and UDP do not clash) |
| `http3.altSvcMaxAge` | integer seconds | `86400` | `ma` of the `Alt-Svc` header on HTTPS responses |
| `http3.qpackMaxTableCapacity` | integer 0–1048576 | `0` | QPACK dynamic table offered to clients; `0` = static table only |
| `http3.qpackBlockedStreams` | integer 0–1000 | `0` | Streams that may wait on QPACK inserts |
| `http3.enabled` | bool | `true` | `false` turns it off |

### Virtual hosts, auth, proxy and logs

These have their own sections:

| Key | Default | Reference |
|---|---|---|
| `hosts` | `[]` | [Virtual hosts](https://photon-http.sstools.co/docs/static-sites.md#virtual-hosts) |
| `auth` | `[]` | [Authentication](https://photon-http.sstools.co/docs/static-sites.md#authentication) |
| `proxy` | `[]` | [Reverse proxy reference](https://photon-http.sstools.co/docs/dynamic-sites.md#proxy-mount-reference) |
| `accessLog` | off | [Logs](#logs) below |

## HTTPS with a PKCS#12 identity

The server loads a PKCS#12 (`.p12`) file holding the certificate chain and private key, in
memory only (`SecPKCS12Import` with `kSecImportToMemoryOnly`). It never touches the keychain,
so nothing prompts and nothing is installed.

```json
{
  "host": "0.0.0.0",
  "port": 80,
  "root": "/Users/me/Sites/example",
  "tls": { "identity": "certs/example.p12", "passwordEnv": "SWS_P12_PASSWORD", "port": 443 },
  "http3": true
}
```

### Local testing

```bash
scripts/make-test-identity.sh            # .test-identity/server.p12, self-signed for localhost
.build/release/photon --config Root/http-config.tls.json
curl -k https://127.0.0.1:8443/                      # HTTP/2 via ALPN
curl -k --http1.1 https://127.0.0.1:8443/
/opt/homebrew/opt/curl/bin/curl --http3-only -k https://127.0.0.1:8443/   # Homebrew curl has HTTP/3
```

Browsers reject a self-signed certificate unless you trust it, which changes the keychain's
trust settings; do that by hand only if you want to, or test with curl.

### A real certificate (Let's Encrypt)

Any ACME client that writes PEM files works, for example [lego](https://go-acme.github.io/lego/),
[acme.sh](https://github.com/acmesh-official/acme.sh) or certbot (all installable with
Homebrew). The HTTP-01 challenge needs the domain to reach this Mac on port 80, and
StaticFiles serves `/.well-known/` even with `blockDotfiles` on, so you can use webroot mode
with your site's `root`:

```bash
# Example with lego, webroot mode, while PhotonHTTP serves the site on port 80
lego --email you@example.com --domains example.com --domains www.example.com \
     --http --http.webroot /Users/me/Sites/example run
# certificates land in ./.lego/certificates/example.com.crt (full chain) and .key
```

Convert to PKCS#12. Use the legacy-compatible algorithms: `SecPKCS12Import` does not reliably
accept OpenSSL 3's default AES/PBKDF2 encryption (this is what `scripts/make-test-identity.sh`
does too):

```bash
export SWS_P12_PASSWORD='a long random password'
openssl pkcs12 -export \
  -inkey example.com.key -in example.com.crt \
  -out certs/example.p12 -passout env:SWS_P12_PASSWORD \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
chmod 600 certs/example.p12
```

`-in` must be the full chain (leaf first, then intermediates). Use Homebrew's
`/opt/homebrew/bin/openssl` if `/usr/bin/openssl` (LibreSSL) rejects an option.

After a renewal, write the new `.p12` over the old path (make it in a temporary file, then
`mv` it into place, so the server never reads half a file) and send **SIGHUP**: the server
rereads the identity, and new HTTPS and HTTP/3 connections get the new certificate without a
restart or dropped connections (see [reload](#shutdown-restart-and-reload)). With the file
watcher on (the default, `reload.watch`), the signal is optional: the server sees the new file
within `reload.interval` and reloads by itself. ACME clients have a renew hook for that, e.g. `kill -HUP "$(pgrep -f 'photon --config /path/to/http-config.json')"`.
stderr confirms it with `reload: TLS identity PATH reloaded`; if the new file does not load
(wrong password, not PKCS#12) it prints `warning: reload: cannot load TLS identity …; keeping
the current TLS certificate` and keeps serving the old one.

## Binding to all interfaces and the firewall prompt

The default `host` is `127.0.0.1`: only this Mac can connect. To serve your network or the
internet, set `"host": "0.0.0.0"` (all IPv4 interfaces) or `"::"`.

With the macOS application firewall on (System Settings → Network → Firewall), the first time
an **unsigned or newly built** binary listens on a non-loopback address macOS asks "Do you want
the application "photon" to accept incoming network connections?". Each rebuild changes
the binary, so the prompt can come back. Options:

- Click Allow once per build (fine on a desktop; it blocks an unattended start under launchd
  until someone clicks).
- Install one stable copy (e.g. `/usr/local/bin/photon`), and allow it once; sign it
  with your own Developer ID (`codesign -s "Developer ID Application: …"`) so the approval
  survives updates.
- Allow it ahead of time from an admin shell:
  `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/local/bin/photon`
  and `--unblockapp` the same path.

Loopback (`127.0.0.1`, `::1`) never prompts, which is why every example and test here binds
loopback. A server reached only through a local reverse proxy or a tunnel (Tailscale, Cloudflare
Tunnel) can stay on loopback or bind only the tunnel's address.

HTTP/3 needs the UDP port open as well as TCP, in any firewall or router in front of the Mac.

## Ports 80 and 443 without root

Since macOS 10.14 (Mojave), a non-root process may bind ports below 1024 on the **wildcard**
address, so `"host": "0.0.0.0"` (or `"::"`) with `"port": 80` and `"tls": {"port": 443}` works
as a normal user. Binding a *specific* address below 1024 can still fail with `EACCES`
("Permission denied"); bind the wildcard instead. Do not run the server as root.

## Running as a LaunchAgent

A user LaunchAgent starts the server at login and restarts it if it exits. Save as
`~/Library/LaunchAgents/com.example.photonhttp.plist` (adjust paths):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.example.photonhttp</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/photon</string>
    <string>--config</string>
    <string>/Users/me/Sites/example/http-config.json</string>
  </array>
  <key>WorkingDirectory</key>
  <string>/Users/me/Sites/example</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SWS_P12_PASSWORD</key>
    <string>…</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ExitTimeOut</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>/Users/me/Library/Logs/PhotonHTTP/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/me/Library/Logs/PhotonHTTP/stderr.log</string>
</dict>
</plist>
```

```bash
mkdir -p ~/Library/Logs/PhotonHTTP
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.photonhttp.plist
photon restart --config /Users/me/Sites/example/http-config.json   # apply a config, no gap
launchctl kickstart -k gui/$(id -u)/com.example.photonhttp    # new process (a new binary)
launchctl bootout gui/$(id -u)/com.example.photonhttp         # stop and unload
```

- **A config change** that a reload rejects (ports, `tls`, `http2`, `http3`, limits) is applied
  with `photon restart`: the [graceful restart](#graceful-restart) runs inside the
  process launchd started, so the job keeps its pid, nothing is refused, and launchd sees no
  exit.
- **A new binary** needs a new process: `launchctl kickstart -k` sends SIGTERM (the server
  drains for up to `drainTimeout`), then launchd starts the new binary. Connections are refused
  from the moment the old listeners close until the new process has bound them, usually well
  under a second. Moving listening sockets into a new process (an `exec`-based hand-off) does
  not fit launchd's model of one job, one pid it started and watches, so it is not done.

- `KeepAlive` with `SuccessfulExit = false` restarts the server after a crash or a startup
  error, but not after a clean stop (exit 0).
- launchd stops a job with SIGTERM and kills it after `ExitTimeOut` seconds (default 20).
  Keep `drainTimeout` (default 10) below it so the drain finishes.
- A LaunchAgent runs only while you are logged in. For a server that runs without a login, a
  LaunchDaemon in `/Library/LaunchDaemons` (needs admin) with `UserName` set to an unprivileged
  account does the same job.
- Keep the site and config **outside** `~/Desktop`, `~/Documents` and `~/Downloads`: those are
  privacy-protected, and a launchd job reading them is denied or triggers a permission prompt.
- The `EnvironmentVariables` password is readable by anyone who can read the plist; keep it
  `chmod 600`, or point `passwordEnv` at a variable you set another way.

## Logs

- **Startup and errors** go to stderr; **`listening` lines** to stdout.
- **Access log**: the `accessLog` key.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `accessLog` | bool, string or object | off | `true`: Common lines to stdout. A string: the `path`. `false`/`null`: off |
| `accessLog.path` | string or `null` | `"stdout"` | A file (relative to the config file; appended to, created `0644`; its directory must exist), `"stdout"` or `"stderr"`. `null` writes no lines (metrics only) |
| `accessLog.format` | `"common"` \| `"combined"` \| `"json"` | `"common"` | Combined adds `Referer` and `User-Agent`; JSON lines include the duration |
| `accessLog.metrics` | bool or path | off | Serve Prometheus metrics at this path (`true` = `/metrics`) |
| `accessLog.flushInterval` | seconds > 0 | `1` | Longest a line waits in its buffer |
| `accessLog.enabled` | bool | `true` | `false` turns it off |

The access log is outermost in the chain, so it records the final status of every response
(error pages, auth rejections, proxied responses). Lines are buffered per connection and
written by a background task; if the writer falls behind, lines are dropped (counted), never
delayed. A graceful stop writes everything buffered. `metrics` is served to anyone who can
reach the server; protect it with `auth` if that matters.

**Rotation.** The server does not rotate files itself. Move the file aside, then send SIGHUP:
the log is reopened by its path, so the next lines go to a new file and the moved one is
complete once the connections open before the signal have closed (each finishes its buffered
lines into it).

```bash
mv logs/access.log logs/access.log.1
kill -HUP "$(pgrep -f 'photon --config /path/to/http-config.json')"
```

`newsyslog` signals a process through a pid file, which the server does not write; run the two
commands above from a LaunchAgent with `StartCalendarInterval` instead (or have your own
wrapper write a pid file).

## Shutdown, restart and reload

- **SIGUSR2** starts a [graceful restart](#graceful-restart) (what `photon restart`
  sends).
- **SIGINT and SIGTERM** start a graceful shutdown: listeners stop accepting, HTTP/2 and HTTP/3
  connections get `GOAWAY`, proxied WebSocket tunnels are closed at the TCP level (clients see
  1006; in-process `WebSocketUpgrade` sessions in a custom server get Close 1001, see
  [WebSockets](https://photon-http.sstools.co/docs/websockets.md)), in-flight requests finish for up
  to `drainTimeout` seconds, then the rest are cancelled; the access log flushes and the
  process exits 0. A second signal during the drain is harmless. `scripts/sigterm.sh` sends
  SIGTERM to whatever listens on `PORT` (default 8080).
- **Hot reload, no signal needed** (#0142). The server polls `http-config.json` and the files
  it names that a reload reads (the TLS identity, `auth` Basic credential files, `errorPages`
  files) with `stat` every `reload.interval` seconds (default 2). A change of modification
  time, size or inode (an editor or `tailscale cert`/lego renaming a new file into place)
  starts a reload once the files have stopped changing for `min(interval, 0.5 s)`, so a file
  still being written is not read; a file that is malformed when read never replaces the
  running configuration. stderr says `PATH changed, reloading the configuration`. Reloads,
  whether from the watcher or SIGHUP, run one at a time, and none start once the server is
  draining. `"reload": false` turns the watcher off.
- **SIGHUP reloads** `http-config.json` (the same file and command-line overrides as at
  startup) and reopens the access log file. The new configuration is parsed, validated and
  built first; on success new requests use it, while requests already running finish on the
  old one (the old chain, its proxy pools and its log writer are retired once the connections
  opened before the reload have closed). On failure (bad JSON, an unknown key's error, a root
  or error page that cannot be opened, an auth file that cannot be read) stderr says
  `reload failed, keeping the running configuration: …` and nothing changes except the log
  reopen. Success prints `reloaded the configuration`.

  | Reloaded (SIGHUP or the watcher) | Needs a restart (a reload that changes one is rejected whole) |
  |---|---|
  | `root`, `index`, `mimeTypes`, `defaultMimeType`, `blockList`, `blockDotfiles`, `caching`, `errorPages`, `compression`, `hosts`, `auth` (and its credential files), `proxy` and `hosts[].proxy`, `accessLog` (path, format, metrics, flush interval), `reload`, `statusFile`, `tls.identity` and `tls.password` / `tls.passwordEnv` (the identity file is reread on every SIGHUP, so a renewal at the same path is picked up) | `host`, `port`, `transport`, adding or removing `tls`, `tls.port`, `http2`, `http3`, `maxConnections`, `drainTimeout`, `timeouts`, `maxBodySize` |

  The identity reload prints one line: `reload: TLS identity PATH reloaded; new HTTPS and HTTP/3
  handshakes use the new certificate`, `reload: TLS identity PATH unchanged`, or `warning:
  reload: cannot load TLS identity PATH: …; keeping the current TLS certificate`. Open
  connections keep the certificate they negotiated.

  **A restart-only change rejects the whole reload** (#0143): none of the file applies, not
  even its reloadable keys, so the running state always matches one whole config file. stderr
  says `reload rejected, keeping the running configuration: port changed and needs a restart;
  run `photon restart` to apply them`, and the status file records the keys in
  `restartRequired` until a reload succeeds. Every later reload is rejected the same way until
  the file is put back or the server restarts. `photon check` tells you before you
  save or signal. Access log metrics start from zero after a reload (the new chain has its own
  counters). To apply restart-only keys, run `photon restart` (below).
- Static file *contents* need no restart: cached entries are re-checked with `stat` at most
  once per second.

### Graceful restart

`photon restart` (or SIGUSR2 to the server's pid) applies a whole config file,
restart-only keys included, inside the running process (#0144):

1. The server reads, validates and builds the config as at startup (same file and
   command-line overrides): settings, protocols, the TLS identity (in memory only) and the
   handler chain. Any failure stops here and nothing changes.
2. It binds the new listeners **while the old ones still accept**. A port that stays the same
   is never without a listener:
   - **Cleartext on BSD sockets** (the default `transport`): the new socket binds the same
     port with `SO_REUSEPORT`, which the old socket turns on only for the moment of the swap
     (another program binding the port still gets "address already in use"). The kernel sends
     new connections to the new socket; connections already queued on the old one are served,
     then it closes.
   - **HTTPS and HTTP/3** (Network.framework, which cannot share a port), and cleartext with
     `"transport": "nw"`: the running listener is handed to the new configuration as it is,
     when its address and ALPN stay the same. Its certificate comes from the same identity
     store, so a changed identity file applies to new handshakes as on a reload. Turning
     `http2` on or off changes the HTTPS listener's ALPN: that listener closes and rebinds,
     a gap of a few milliseconds on the HTTPS port only.
   - **A changed port** (`port`, `tls.port`, `http3.port`, or `host`): the new port opens; the
     old one stops accepting and closes once the swap is done.
   - A port of `0` that was `0` before keeps the port it was given.
3. The new listeners start accepting with the new settings (limits, timeouts, `maxBodySize`,
   protocols, chain).
4. The old listeners stop accepting. Their connections go on for a second (so a connection
   accepted just before the swap gets its first request answered), then drain as on SIGTERM:
   HTTP/2 and HTTP/3 send `GOAWAY`, HTTP/1.1 closes idle keep-alive connections and finishes
   the request in flight with `connection: close`, tunnels end; whatever is still open after
   the new `drainTimeout` is cancelled. While the old connections drain, each set has its own
   `maxConnections`.

If a new listener cannot bind (its port is taken, a bad `host`), the listeners already bound
for the restart close and **the old ones keep serving**: stderr and `photon restart`
say `restart failed, the running server keeps serving: listener http on 127.0.0.1:8081:
Address already in use (errno 48)`, and the status file records `"result": "failed"` with
`"trigger": "restart"`. Success prints `restarted; listening …` on stderr (not stdout: the
`listening` lines there are the startup ones) and records `"result": "restarted"`.

Restarts and reloads run one at a time on the same task. A server started without `http3`
can turn it on by a restart, but its responses only advertise it (`Alt-Svc`) after a process
restart. A client that keeps a connection idle across the swap may see it closed (as on any
server closing idle keep-alive connections); HTTP clients retry such requests on a new
connection.


## A public server checklist

- Release build, installed at a stable path; firewall decision made for that path.
- `"host": "0.0.0.0"`, `port` 80, `tls.port` 443, `http3` on (UDP 443 open).
- `passwordEnv` rather than an inline `password`; `.p12` mode `0600`.
- `accessLog` to a file, rotated (move it, then SIGHUP); `metrics` behind `auth` or off.
- `maxConnections`, `maxBodySize` and `timeouts` sized for your traffic; the defaults are
  conservative.
- LaunchAgent (or LaunchDaemon) with `ExitTimeOut` above `drainTimeout`; renewal hook sends SIGHUP.
- More for proxied apps: [production checklist](https://photon-http.sstools.co/docs/dynamic-sites.md#production-checklist).
