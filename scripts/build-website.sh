#!/bin/bash
# Builds the generated parts of the PhotonHTTP website (https://photon-http.sstools.co/).
#
#   scripts/build-website.sh
#
# Writes, from docs/guide/*.md and the sources below:
#   Website/docs/<page>.html     every docs page: the guides, getting-started and the docs index
#   Website/docs/<page>.md       a raw markdown copy of each, links made absolute (for agents)
#   Website/llms.txt             llmstxt.org index; Website/llms-full.txt the full text
#   Website/sitemap.xml, Website/robots.txt
# Never touches the hand-written home page (Website/index.html), Website/assets/,
# Website/images/ or Website/install.sh. Python 3 standard library only, no packages.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 -I - "$repo" <<'PY'
import datetime
import html
import os
import re
import subprocess
import sys

REPO = sys.argv[1]
GUIDE = os.path.join(REPO, "docs", "guide")
WEB = os.path.join(REPO, "Website")
OUT = os.path.join(WEB, "docs")
GITHUB = "https://github.com/brennanMKE/PhotonHTTP"
SITE = "https://photon-http.sstools.co"
SUMMARY = ("PhotonHTTP is a fast, modular HTTP/1.1, HTTP/2 and HTTP/3 web server for macOS 15 "
           "and later, written in Swift 6 with Swift Concurrency and no package dependencies. "
           "Run it as the `photon` command, configured by one JSON file, or compose its "
           "components into your own Swift server.")

# Every docs page, in sidebar order: (name, title, description, group, source).
# source "guide" is docs/guide/<name>.md; "inline" is markdown defined in this script.
PAGES = [
    ("index", "Documentation", "Guides for running PhotonHTTP on a Mac and building your own server from its components.", None, "inline"),
    ("getting-started", "Getting started", "Install the photon command with one line and serve any folder as a static website with photon serve.", "Start here", "inline"),
    ("overview", "Overview and architecture", "Core and optional components, HTTP/1.1, HTTP/2 and HTTP/3, the transports, the concurrency model and the handler chain.", "Start here", "guide"),
    ("running-on-a-mac", "Running on a Mac", "The photon command line and control commands, the complete http-config.json reference, certificates, public binding, LaunchAgents, logs, reload, restart and shutdown.", "Run a site", "guide"),
    ("static-sites", "Static websites", "StaticFiles, caching and conditional requests, Range, error pages, compression, virtual hosts and authentication.", "Run a site", "guide"),
    ("dynamic-sites", "Dynamic websites", "In-process Swift with Router and WebSockets; reverse proxy to local apps; Apache mod_proxy mapping; a production checklist.", "Run a site", "guide"),
    ("tls", "TLS", "PKCS#12 identities loaded in memory (never the keychain), ALPN and protocol selection, versions and options, getting certificates, testing safely.", "Run a site", "guide"),
    ("http1", "HTTP/1.1", "The request lifecycle, keep-alive and pipelining, bodies and chunked coding, every limit and timeout, error codes and smuggling defences.", "Protocols", "guide"),
    ("http3", "HTTP/3", "QUIC from Network.framework, Alt-Svc discovery, streams and QPACK, limits and abuse defences, known limitations, testing with curl.", "Protocols", "guide"),
    ("websockets", "WebSockets", "In-process endpoints, the message API, the handshake over HTTP/1.1, HTTP/2 and HTTP/3, permessage-deflate, limits, close codes and proxying.", "Protocols", "guide"),
    ("choosing-components", "Choosing components", "Every target and library product, what it depends on and when to include it; building your own server as a Swift package.", "Build your own server", "guide"),
    ("performance", "Performance notes", "Benchmark results against nginx, lighttpd, h2o, Apache and Caddy, per-request costs, and what they mean for configuration.", "Build your own server", "guide"),
]
PAGE_NAMES = {p[0] for p in PAGES}
GROUPS = ["Start here", "Run a site", "Protocols", "Build your own server"]

GETTING_STARTED = r"""# Getting started

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
[binding to all interfaces and the firewall prompt](running-on-a-mac.md#binding-to-all-interfaces-and-the-firewall-prompt).

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
[Running on a Mac](running-on-a-mac.md).

## Next steps

- [Static websites](static-sites.md): caching and ETags, Range, error pages, compression,
  virtual hosts and authentication.
- [Running on a Mac](running-on-a-mac.md): every command and config key, certificates, ports
  80 and 443, LaunchAgents, logs, reload.
- [TLS](tls.md): HTTPS, HTTP/2 and HTTP/3 with a PKCS#12 identity loaded in memory, never the
  keychain.
- [Dynamic websites](dynamic-sites.md): proxy paths to a local app, or write handlers in Swift
  with Router and WebSockets.
- [Choosing components](choosing-components.md): build your own server as a Swift package from
  the parts you need.
- [Overview and architecture](overview.md): how the pieces fit.
"""


def docs_index_markdown():
    lines = ["# Documentation", "",
             "How PhotonHTTP is put together, how to pick the parts you need, how to run it on a "
             "Mac for static and dynamic websites, and how each protocol works.", ""]
    for group in GROUPS:
        lines += [f"## {group}", ""]
        lines += [f"- [{t}]({n}.md): {d}" for n, t, d, g, _ in PAGES if g == group]
        lines.append("")
    lines += ["## More", "",
              "Design and project records live in the repository: [ROADMAP](../ROADMAP.md) (the "
              "design, authoritative), [MIDDLEWARE](../MIDDLEWARE.md), "
              "[SERVER-COMPARISON](../SERVER-COMPARISON.md) and "
              "[benchmarks](../benchmarks/README.md).", ""]
    return "\n".join(lines)


def source_markdown(name, source):
    if source == "guide":
        with open(os.path.join(GUIDE, name + ".md"), encoding="utf-8") as f:
            return f.read()
    return GETTING_STARTED if name == "getting-started" else docs_index_markdown()

# ---------------------------------------------------------------- links

def rewrite_link(url, absolute=False):
    """A link in a docs page's markdown (relative to docs/guide) as the site should show it.

    Links to other docs pages become NAME.html (or, with absolute, the page's .md copy on the
    site); links to other repository files become GitHub URLs on main."""
    if re.match(r"^[a-z][a-z0-9+.-]*:", url, re.I) or url.startswith("#"):
        return url
    path, _, frag = url.partition("#")
    frag = "#" + frag if frag else ""
    if "/" not in path:
        name = path[:-3] if path.endswith(".md") else path
        if name == "README":
            name = "index"
        if name in PAGE_NAMES:
            return f"{SITE}/docs/{name}.md{frag}" if absolute else f"{name}.html{frag}"
    target = os.path.normpath(os.path.join("docs/guide", path))
    if target.startswith(".."):
        return url
    full = os.path.join(REPO, target)
    kind = "tree" if path.endswith("/") or os.path.isdir(full) else "blob"
    return f"{GITHUB}/{kind}/main/{target}{frag}"


def absolutize_markdown(text):
    """The markdown with every link rewritten for use outside the repository."""
    out, fence = [], None
    for line in text.split("\n"):
        m = re.match(r"^\s*(```+|~~~+)", line)
        if fence:
            if line.strip().startswith(fence):
                fence = None
            out.append(line)
            continue
        if m:
            fence = m.group(1)
            out.append(line)
            continue
        parts = re.split(r"(`+[^`]*`+)", line)
        for k in range(0, len(parts), 2):
            parts[k] = re.sub(r"\]\(([^)\s]+)\)",
                              lambda mm: "](" + rewrite_link(mm.group(1), absolute=True) + ")",
                              parts[k])
        out.append("".join(parts))
    return "\n".join(out)

# ---------------------------------------------------------------- markdown -> html

def slugify(text, used):
    """GitHub-style heading id: lowercase, drop punctuation, spaces to hyphens."""
    s = re.sub(r"<[^>]+>", "", text)
    s = html.unescape(s).strip().lower()
    s = re.sub(r"[^\w\- ]", "", s)
    s = s.replace(" ", "-")
    base, n = s, 0
    while s in used:
        n += 1
        s = f"{base}-{n}"
    used.add(s)
    return s


def inline(text):
    codes = []

    def keep_code(m):
        codes.append("<code>" + html.escape(m.group(2).strip() if m.group(2).strip() else m.group(2), quote=False) + "</code>")
        return f"\x00{len(codes) - 1}\x00"

    text = re.sub(r"(`+)(.+?)\1", keep_code, text, flags=re.S)
    text = re.sub(r"\\([\\`*_{}\[\]()#+\-.!|<>])", lambda m: f"\x01{ord(m.group(1))}\x01", text)
    text = html.escape(text, quote=False)

    def link(m):
        label, url = m.group(1), html.unescape(m.group(2).strip())
        href = html.escape(rewrite_link(url))
        ext = ' rel="noopener"' if href.startswith("http") else ""
        return f'<a href="{href}"{ext}>{label}</a>'

    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, text)
    text = re.sub(r"&lt;(https?://[^\s&]+)&gt;", r'<a href="\1">\1</a>', text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text, flags=re.S)
    text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", text, flags=re.S)
    text = re.sub(r"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)", r"<em>\1</em>", text, flags=re.S)
    text = re.sub(r"\x01(\d+)\x01", lambda m: html.escape(chr(int(m.group(1))), quote=False), text)
    text = re.sub(r"\x00(\d+)\x00", lambda m: codes[int(m.group(1))], text)
    return text


def split_row(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|") and not line.endswith("\\|"):
        line = line[:-1]
    cells = re.split(r"(?<!\\)\|", line)
    return [c.strip().replace("\\|", "|") for c in cells]


LIST_RE = re.compile(r"^( {0,3})([-*+]|\d+[.)])( +)(.*)$")
FENCE_RE = re.compile(r"^ {0,3}(```+|~~~+)\s*([\w+-]*)")


class Renderer:
    def __init__(self):
        self.used_ids = set()
        self.toc = []
        self.title = None

    def blocks(self, lines, tight=False):
        out = []
        i, n = 0, len(lines)
        while i < n:
            line = lines[i]
            if not line.strip():
                i += 1
                continue
            m = FENCE_RE.match(line)
            if m:
                fence, lang = m.group(1), m.group(2)
                i += 1
                body = []
                while i < n and not lines[i].strip().startswith(fence):
                    body.append(lines[i])
                    i += 1
                i += 1
                cls = f' class="language-{lang}"' if lang else ""
                code = html.escape("\n".join(body), quote=False)
                out.append(f'<pre><code{cls}>{code}</code></pre>')
                continue
            m = re.match(r"^(#{1,6})\s+(.*?)\s*#*\s*$", line)
            if m:
                level, content = len(m.group(1)), inline(m.group(2))
                hid = slugify(content, self.used_ids)
                if level == 1 and self.title is None:
                    self.title = re.sub(r"<[^>]+>", "", content)
                    out.append(f"<h1 id=\"{hid}\">{content}</h1>")
                else:
                    if level == 2:
                        self.toc.append((hid, content))
                    out.append(f'<h{level} id="{hid}"><a class="anchor" href="#{hid}" aria-hidden="true">#</a>{content}</h{level}>')
                i += 1
                continue
            if re.match(r"^ {0,3}([-*_])( *\1){2,} *$", line):
                out.append("<hr>")
                i += 1
                continue
            if line.lstrip().startswith(">"):
                body = []
                while i < n and lines[i].strip() and lines[i].lstrip().startswith(">"):
                    body.append(re.sub(r"^\s*> ?", "", lines[i]))
                    i += 1
                out.append("<blockquote>\n" + self.blocks(body) + "\n</blockquote>")
                continue
            if "|" in line and i + 1 < n and re.match(r"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$", lines[i + 1]):
                head = split_row(line)
                aligns = []
                for spec in split_row(lines[i + 1]):
                    aligns.append("center" if spec.startswith(":") and spec.endswith(":")
                                  else "right" if spec.endswith(":")
                                  else "left" if spec.startswith(":") else None)
                i += 2
                rows = []
                while i < n and lines[i].strip() and "|" in lines[i]:
                    rows.append(split_row(lines[i]))
                    i += 1

                def cell(tag, text, k):
                    a = aligns[k] if k < len(aligns) else None
                    style = f' style="text-align:{a}"' if a else ""
                    return f"<{tag}{style}>{inline(text)}</{tag}>"

                t = ['<div class="table-wrap"><table>', "<thead><tr>"]
                t += [cell("th", c, k) for k, c in enumerate(head)]
                t.append("</tr></thead><tbody>")
                for r in rows:
                    r = (r + [""] * len(head))[: len(head)]
                    t.append("<tr>" + "".join(cell("td", c, k) for k, c in enumerate(r)) + "</tr>")
                t.append("</tbody></table></div>")
                out.append("".join(t))
                continue
            m = LIST_RE.match(line)
            if m:
                ordered = m.group(2)[0].isdigit()
                items, loose = [], False
                while i < n:
                    m = LIST_RE.match(lines[i])
                    if not m or m.group(2)[0].isdigit() != ordered:
                        break
                    indent = len(m.group(1)) + len(m.group(2)) + len(m.group(3))
                    item = [m.group(4)]
                    i += 1
                    ended = False
                    while i < n:
                        l = lines[i]
                        if not l.strip():
                            # A blank line: the item continues if the next line is indented.
                            j = i
                            while j < n and not lines[j].strip():
                                j += 1
                            if j < n and len(lines[j]) - len(lines[j].lstrip()) >= indent:
                                item.extend([""] * (j - i))
                                i = j
                                continue
                            nxt = LIST_RE.match(lines[j]) if j < n else None
                            if nxt and nxt.group(2)[0].isdigit() == ordered:
                                loose = True
                            else:
                                ended = True
                            i = j
                            break
                        lead = len(l) - len(l.lstrip())
                        if lead >= indent:
                            item.append(l[indent:])
                        elif LIST_RE.match(l) or FENCE_RE.match(l) or l.lstrip().startswith("#"):
                            break
                        else:
                            item.append(l.strip())  # lazy continuation
                        i += 1
                    items.append(item)
                    if ended:
                        break
                tag = "ol" if ordered else "ul"
                start = ""
                if ordered:
                    first = int(re.match(r"\s*(\d+)", line).group(1))
                    start = f' start="{first}"' if first != 1 else ""
                parts = [f"<{tag}{start}>"]
                for item in items:
                    parts.append("<li>" + self.blocks(item, tight=not loose and "" not in item) + "</li>")
                parts.append(f"</{tag}>")
                out.append("\n".join(parts))
                continue
            # Paragraph: until a blank line or the start of another block.
            para = []
            while i < n and lines[i].strip():
                l = lines[i]
                if para and (FENCE_RE.match(l) or re.match(r"^#{1,6}\s", l) or LIST_RE.match(l)
                             or l.lstrip().startswith(">")):
                    break
                para.append(l.strip())
                i += 1
            content = inline("\n".join(para))
            out.append(content if tight else f"<p>{content}</p>")
        return "\n".join(out)



# ---------------------------------------------------------------- page template

FONTS = ("https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700"
         "&family=JetBrains+Mono:wght@400;500&family=Space+Grotesk:wght@500;700&display=swap")


def nav_html(current):
    items = []
    for name, title, _, _, _ in PAGES:
        cur = ' aria-current="page"' if name == current else ""
        items.append(f'<li><a href="{name}.html"{cur}>{html.escape(title)}</a></li>')
    return "\n".join(items)


TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} · PhotonHTTP</title>
<meta name="description" content="{description}">
<link rel="canonical" href="{url}">
<link rel="alternate" type="text/markdown" href="{name}.md" title="Markdown">
<meta property="og:type" content="article">
<meta property="og:site_name" content="PhotonHTTP">
<meta property="og:title" content="{title} · PhotonHTTP">
<meta property="og:description" content="{description}">
<meta property="og:url" content="{url}">
<meta property="og:image" content="{site}/images/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="PhotonHTTP">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{title} · PhotonHTTP">
<meta name="twitter:description" content="{description}">
<meta name="twitter:image" content="{site}/images/og.png">
<link rel="icon" type="image/png" sizes="32x32" href="../images/favicon-32.png">
<link rel="apple-touch-icon" href="../images/apple-touch-icon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="{fonts}">
<link rel="stylesheet" href="../assets/site.css">
<script src="../assets/site.js" defer></script>
</head>
<body class="docs">
<!-- Generated by scripts/build-website.sh from {source}. Do not edit. -->
<header class="site-header">
  <div class="wrap header-inner">
    <a class="brand" href="../"><img src="../images/logo.png" alt="" width="28" height="28" onerror="this.remove()"><span>Photon<b>HTTP</b></span></a>
    <nav class="top-nav" aria-label="Site">
      <a href="index.html"{docs_current}>Docs</a>
      <a href="getting-started.html"{start_current}>Get started</a>
      <a href="{github}" rel="noopener">GitHub</a>
    </nav>
  </div>
</header>
<div class="wrap docs-layout">
  <aside class="docs-nav" aria-label="Documentation">
    <details open>
      <summary>Guides</summary>
      <ul>
{nav}
      </ul>
    </details>
  </aside>
  <main class="prose" id="main">
{body}
    <p class="edit-link">{source_link} · <a href="{name}.md">Markdown</a></p>
  </main>
</div>
<footer class="site-footer">
  <div class="wrap">
    <p>PhotonHTTP · a modular HTTP/1.1, HTTP/2 and HTTP/3 server for macOS, in Swift ·
    <a href="{github}" rel="noopener">GitHub</a> · <a href="index.html">Docs</a> ·
    <a href="../llms.txt">llms.txt</a></p>
  </div>
</footer>
</body>
</html>
"""


def docs_index_body():
    parts = ['<h1 id="documentation">Documentation</h1>',
             '<p class="lead">How PhotonHTTP is put together, how to pick the parts you need, how '
             'to run it on a Mac for static and dynamic websites, and how each protocol works.</p>']
    for group in GROUPS:
        gid = slugify(group, set())
        parts.append(f'<h2 id="{gid}"><a class="anchor" href="#{gid}" aria-hidden="true">#</a>{html.escape(group)}</h2>')
        parts.append('<div class="cards">')
        for n, t, d, g, _ in PAGES:
            if g == group:
                featured = " featured" if n == "getting-started" else ""
                parts.append(f'<a class="card{featured}" href="{n}.html"><strong>{html.escape(t)}</strong>'
                             f'<span>{html.escape(d)}</span></a>')
        parts.append("</div>")
    parts.append('<h2 id="more"><a class="anchor" href="#more" aria-hidden="true">#</a>More</h2>')
    links = [("ROADMAP", "docs/ROADMAP.md", " (the design, authoritative)"), ("MIDDLEWARE", "docs/MIDDLEWARE.md", ""),
             ("SERVER-COMPARISON", "docs/SERVER-COMPARISON.md", ""), ("benchmarks", "docs/benchmarks/README.md", "")]
    a = [f'<a href="{GITHUB}/blob/main/{p}" rel="noopener">{t}</a>{x}' for t, p, x in links]
    parts.append(f"<p>Design and project records live in the repository: {a[0]}, {a[1]}, {a[2]} and {a[3]}.</p>")
    return "\n".join(parts)


def build_page(name, title, description, source):
    md = source_markdown(name, source)
    toc = ""
    if name == "index":
        body = docs_index_body()
    else:
        r = Renderer()
        body = r.blocks(md.split("\n"))
        if len(r.toc) >= 3:
            links = "\n".join(f'<li><a href="#{hid}">{label}</a></li>' for hid, label in r.toc)
            toc = f'<details class="toc"><summary>On this page</summary><ul>\n{links}\n</ul></details>'
    if source == "guide":
        src = f"docs/guide/{name}.md"
        source_link = f'<a href="{GITHUB}/blob/main/{src}" rel="noopener">View the source on GitHub</a>'
    else:
        src = "scripts/build-website.sh"
        source_link = f'<a href="{GITHUB}/blob/main/{src}" rel="noopener">Generated by scripts/build-website.sh</a>'
    url = f"{SITE}/docs/" if name == "index" else f"{SITE}/docs/{name}.html"
    page = TEMPLATE.format(
        title=html.escape(title), description=html.escape(description), name=name, url=url,
        site=SITE, github=GITHUB, fonts=html.escape(FONTS), source=src, source_link=source_link,
        docs_current=' aria-current="page"' if name != "getting-started" else "",
        start_current=' aria-current="page"' if name == "getting-started" else "",
        nav=nav_html(name), body=body.replace("</h1>", "</h1>\n" + toc, 1) if toc else body)
    write(os.path.join(OUT, name + ".html"), page)
    md_abs = absolutize_markdown(md).rstrip() + "\n"
    write(os.path.join(OUT, name + ".md"), md_abs)
    return md_abs, src

# ---------------------------------------------------------------- outputs

written = []


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    written.append(os.path.relpath(path, REPO))


def lastmod(rel):
    """The source file's last commit date, or its modification time when it has local changes."""
    full = os.path.join(REPO, rel)
    try:
        dirty = subprocess.run(["git", "-C", REPO, "status", "--porcelain", "--", rel],
                               capture_output=True, text=True, timeout=20).stdout.strip()
        date = subprocess.run(["git", "-C", REPO, "log", "-1", "--format=%cs", "--", rel],
                              capture_output=True, text=True, timeout=20).stdout.strip()
        if date and not dirty:
            return date
    except (OSError, subprocess.SubprocessError):
        pass
    return datetime.date.fromtimestamp(os.path.getmtime(full)).isoformat()


os.makedirs(OUT, exist_ok=True)
full_text = []
sitemap = [(f"{SITE}/", lastmod("Website/index.html"))]
for name, title, description, group, source in PAGES:
    if source == "guide" and not os.path.exists(os.path.join(GUIDE, name + ".md")):
        print(f"warning: docs/guide/{name}.md is missing; skipped", file=sys.stderr)
        continue
    md_abs, src = build_page(name, title, description, source)
    url = f"{SITE}/docs/" if name == "index" else f"{SITE}/docs/{name}.html"
    sitemap.append((url, lastmod(src)))
    if name != "index":
        full_text.append((name, md_abs))

# llms.txt (https://llmstxt.org/)
llms = ["# PhotonHTTP", "", f"> {SUMMARY}", "",
        "- Requirements: macOS 15 or later and a Swift 6.4 toolchain (Xcode or swift.org). Not built or tested on Linux.",
        "- Install (builds from source, installs `photon` to `~/.local/bin`, no sudo): "
        "`curl -fsSL https://photon-http.sstools.co/install.sh | bash` "
        "(options `--prefix DIR`, `--version REF`; from a checkout, `scripts/install.sh`).",
        "- Serve a folder as a static website: `photon serve [DIR] [--port PORT] [--host HOST]` "
        "(defaults: current directory, port 8080, host 127.0.0.1; prints `listening 127.0.0.1:8080`).",
        "- Everything else (TLS, HTTP/2, HTTP/3, compression, logs, virtual hosts, auth, reverse proxy) "
        "is configured in `http-config.json` and run with `photon --config http-config.json`.",
        f"- Source code: {GITHUB}", ""]
for group in GROUPS:
    llms += [f"## {group}", ""]
    llms += [f"- [{t}]({SITE}/docs/{n}.md): {d}" for n, t, d, g, _ in PAGES if g == group]
    llms.append("")
llms += ["## Optional", "",
         f"- [Full text of the documentation]({SITE}/llms-full.txt): every page above in one file",
         f"- [Documentation index]({SITE}/docs/index.md): the pages above, grouped",
         f"- [README]({GITHUB}/blob/main/README.md): the repository's front page",
         f"- [ROADMAP]({GITHUB}/blob/main/docs/ROADMAP.md): the design and milestone plan (authoritative)", ""]
write(os.path.join(WEB, "llms.txt"), "\n".join(llms))

full = ["# PhotonHTTP documentation (full text)", "", f"> {SUMMARY}", "",
        f"Every page of {SITE}/docs/ as markdown, in reading order. Links point at the site.", ""]
for name, md in full_text:
    full += ["", "---", "", f"<!-- Source: {SITE}/docs/{name}.md (HTML: {SITE}/docs/{name}.html) -->", "", md.rstrip(), ""]
write(os.path.join(WEB, "llms-full.txt"), "\n".join(full))

xml = ['<?xml version="1.0" encoding="UTF-8"?>',
       '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
xml += [f"  <url><loc>{html.escape(u)}</loc><lastmod>{d}</lastmod></url>" for u, d in sitemap]
xml.append("</urlset>")
write(os.path.join(WEB, "sitemap.xml"), "\n".join(xml) + "\n")

write(os.path.join(WEB, "robots.txt"),
      "# Everything here is public. Search engines and AI agents and crawlers are welcome.\n"
      "# For agents: /llms.txt indexes the docs; every docs page has a .md copy.\n"
      "User-agent: *\nAllow: /\n\n"
      f"Sitemap: {SITE}/sitemap.xml\n")

extra = sorted(f[:-3] for f in os.listdir(GUIDE)
               if f.endswith(".md") and f[:-3] not in PAGE_NAMES and f != "README.md")
if extra:
    print("warning: guides not on the site (add them to PAGES):", ", ".join(extra), file=sys.stderr)
print(f"wrote {len(written)} files under Website/")
PY

# The installer the site serves at /install.sh.
cp "$(dirname "$0")/install.sh" "$(dirname "$0")/../Website/install.sh"
