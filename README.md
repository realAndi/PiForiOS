# PiForiOS

[Pi](https://github.com/earendil-works/pi), the open-source agent harness from
Earendil Works, running natively on jailbroken iOS and distributed as a
Sileo/APT package.

Pi ships standalone builds for macOS, Linux and Windows. There is no iOS build,
and there cannot easily be one: the standalone binary is Bun-compiled, and Bun
has no iOS target. So this project patches the `darwin-arm64` executable until
iOS's dyld will load it and JavaScriptCore's JIT will run inside it, and
packages the patcher so the whole thing installs, updates and rolls back through
APT like any other package.

Pi talks to whatever model provider you have an API key for, and keeps that key
in a plain file it writes itself. That makes this a much smaller port than the
sibling [CCForiOS](https://github.com/realAndi/CCForiOS): no keychain to work
around, no OAuth helper, no credential dance. The whole port is a Mach-O patch,
a 68 KB shim and a wrapper that sets four environment variables.

| | |
|---|---|
| Sileo source | `https://reallyitsandi.com/repo/` |
| Package | `com.andi.pi-coding-agent` ("Pi Coding Agent") |
| Source | https://github.com/realAndi/PiForiOS |
| Current upstream | Pi 0.85.1 |
| Verified on | iPhone 15 Pro (A17 Pro), iOS 17.3 (21D50), Dopamine rootless (`/var/jb`, Procursus) |

## Installing

Sileo → Sources → **+** → `https://reallyitsandi.com/repo/`, then install
**Pi Coding Agent**. Then give it a key and run it:

```sh
export ANTHROPIC_API_KEY=sk-ant-...
pi
```

Any provider Pi supports works the same way — `OPENAI_API_KEY`, `GEMINI_API_KEY`,
`OPENROUTER_API_KEY` and about twenty more. Or run `pi` and use `/login`, which
writes the key to `~/.pi/agent/auth.json`. Nothing here touches the keychain,
which is the whole reason this port needs no login helper.

Requirements:

* a rootless jailbreak (`/var/jb`); only Dopamine on iOS 17.3 / arm64 has been
  tested
* a network connection during install — the package does not contain Pi, it
  fetches it (see [What the package contains](#what-the-package-contains))
* about 500 MB free during install, about 81 MB afterwards
* `zsh`, `bash`, `python3`, `ldid`, `curl`, `tar`, `coreutils`, `ripgrep`, `fd`,
  `uikittools` — declared as dependencies, so Sileo offers to install anything
  missing first. **Node.js is not needed**: the Pi binary is Bun-compiled and
  self-contained. The `postinst` also checks each tool by name before doing any
  work, so a hand-installed `.deb` fails immediately with what is missing rather
  than part-way through a download.

Install takes about six seconds: download, checksum, patch, sign, smoke-test,
move into place.

Sileo and Zebra do not check repository signatures, so that is all they need.
The `apt` CLI does check. The repo is signed, so install the key once and name
it in the source line:

```sh
sudo mkdir -p /var/jb/usr/share/keyrings
curl -fsSL https://reallyitsandi.com/repo/andi.gpg \
  | sudo tee /var/jb/usr/share/keyrings/andi.gpg >/dev/null

echo 'deb [signed-by=/var/jb/usr/share/keyrings/andi.gpg] https://reallyitsandi.com/repo/ ./' \
  | sudo tee /var/jb/etc/apt/sources.list.d/andi.list
sudo apt update && sudo apt install com.andi.pi-coding-agent
```

The key goes in `usr/share/keyrings`, not `/var/jb/etc/apt/trusted.gpg.d/`: a
key in the global store can validate *any* repository apt sees, whereas
`signed-by=` limits it to this one.

`/var/jb/usr/local/bin` is on the PATH of a *login* shell, which is what NewTerm
gives you, but not of a non-interactive `ssh host 'cmd'`. Over SSH use:

```sh
ssh phone 'zsh -l -c "pi -p \"reply with the single word OK\""'
```

### What works

`pi --version`, the full `--help`, `pi auth`, `pi update`, and the interactive
TUI: it renders, redraws, takes input, runs `!` shell commands and exits cleanly
on ctrl+D. HTTPS to a provider works — a deliberately invalid key comes back as
a real `401 authentication_error` from `api.anthropic.com`, which is the proof
that DNS, TLS and certificate-chain verification all work on device. Subprocess
spawn works: `!echo $$` in the TUI returns bash's own pid. The working directory
is preserved, so Pi treats the directory you launched it in as the project.

Startup is about 600 ms. The installed tree is 81 MB.

Not yet exercised: a full model session with tool calls, which needs a live API
key. Everything under it has been tested separately — the network path, process
spawn, and the search binaries — but the composition has not.

## How it works

### What the macOS binary needs

Upstream's `pi-darwin-arm64.tar.gz` contains a thin Mach-O 64-bit arm64
executable, `MH_EXECUTE`, PIE, two-level namespace, 23 load commands,
`LC_BUILD_VERSION` platform 1 (macOS) minos 13.0 sdk 15.2, 74,872,418 bytes,
built with Bun 1.3.14. It links exactly four dylibs, every one of which exists
on iOS — no frameworks, no `/Versions/`, no `@rpath`:

```
/usr/lib/libicucore.A.dylib
/usr/lib/libresolv.9.dylib
/usr/lib/libc++.1.dylib
/usr/lib/libSystem.B.dylib
```

It has 715 undefined symbols. Running `dlsym` for every one of them against
those four dylibs on an iOS 17.3 device found **three** that iOS's libSystem
does not export:

```
___clear_cache
_pthread_jit_write_protect_np
_pthread_jit_write_protect_supported_np
```

So the port is small: tell dyld the binary is for iOS, supply three functions,
fix two macOS-only path strings, and make the JIT work.

### The patch

`packaging/payload/piios_patch.py` makes four changes to the Mach-O, in pure
Python with no cctools dependency so it can run on the phone (Procursus ships
`otool`/`nm`/`ldid` but not `vtool`). The result is then re-signed with
`ldid -S entitlements.plist`.

**1. `LC_BUILD_VERSION` platform → iOS (2), minos 15.0, sdk 17.0.**
On its own this is enough for dyld to accept the binary.

**2. Link the shim and repoint four imports at it.**
The patcher appends an `LC_LOAD_DYLIB` for `@executable_path/libshim.dylib`
(ordinal 5, after the four existing dylibs) and, inside
`LC_DYLD_CHAINED_FIXUPS`, rewrites the `lib_ordinal` of four imports from 4
(libSystem) to 5 (the shim): the three missing symbols above plus `_mmap`, which
is not missing but which the JIT emulation has to intercept (see below).

`DYLD_INSERT_LIBRARIES` cannot do this job, for two independent reasons: dyld
ignores every `DYLD_*` variable for a binary carrying entitlements (and this one
needs JIT entitlements), and the import table is two-level — each import names
libSystem specifically — so an inserted library would never win the lookup.

**3. Rewrite the macOS framework paths.**
Bun `dlopen()`s CoreFoundation and CoreServices at runtime by their macOS bundle
paths:

```
.../CoreFoundation.framework/Versions/A/CoreFoundation   dlopen fails on iOS
.../CoreFoundation.framework/CoreFoundation              OK
```

On iOS the binary sits directly inside the bundle. Shimming `dlopen` is not an
option (the shim needs `dlopen` to find the real `dlopen`), so the patcher
rewrites the string data instead: the `Versions/X/` component is removed in
place and the string re-terminated. The replacement is always shorter, so the
tail of the old string is simply left behind.

**4. Blank the gigacage warning.**
Cosmetic, and the one patch that is not load-bearing — see the next section for
why the warning appears at all. It is a `printf` format string with its newline
inside it, so truncating it to empty prints nothing rather than a blank line. If
upstream ever rewords it the patcher says so and carries on.

### Why the gigacage has to be off

JavaScriptCore reserves a "gigacage" — a 64 GB region, aligned to 64 GB, that
all typed-array backing stores are allocated inside, so an out-of-bounds write
cannot reach anything else. On the first launch after the platform patch, Pi
died with:

```
FATAL: Could not allocate gigacage memory with maxAlignment = 68719476736,
totalSize = 68719476736.
```

iOS caps how much address space one process may reserve, well below what that
needs. Measured on device, `mmap` of `PROT_NONE`, `MAP_NORESERVE` anonymous
memory:

| reservation | result |
|---|---|
| 1 GB | ok |
| 2 GB | ok |
| 4 GB | ok |
| 8 GB | **`ENOMEM`** |
| 16 GB and above | **`ENOMEM`** |

The cage size is compiled into JSC and cannot be reduced, so there is nothing to
negotiate: the wrapper sets `GIGACAGE_ENABLED=0` and JSC skips it. This is a
mitigation being turned off, not a feature, and it is disabled because on iOS it
cannot be on. The sibling Claude Code port does not need this — its Bun is a
release newer — which is worth knowing if this ever stops being necessary.

### Why the JIT is emulated

The three missing symbols are why the shim exists at all: two of them are the
`pthread_jit_write_protect` pair, and a two-level namespace import that resolves
to nothing is a load-time failure, so the binary cannot start without something
defining them. Defining them as no-ops would be the minimum. Making them work is
what this section is about.

Worth stating because the sibling Claude Code port's README says the opposite
about *its* binary: Pi does **not** hard-require a working JIT. JSC forces
`useSharedArrayBuffer=false` whenever `useJIT=false`, and Claude Code dies at
startup on `new SharedArrayBuffer(4)`; Pi does not touch one. With
`BUN_JSC_useJIT=0` the whole CLI still works, `--help` and a full `-p` session
included, and it is a genuine fallback if a future Bun ever breaks the
emulation below.

So this is about speed, not about starting. With the shim in place JSC reports:

```
useJIT=true
useSharedArrayBuffer=true
useConcurrentJIT=false (default: true)
```

One measurement to keep the claim honest: `pi --help` is if anything *faster*
with the JIT off (0.30 s against 0.37 s), because a process that lives for a
third of a second never amortises compilation. Whether the JIT pays for itself
over a long session has not been measured here.

macOS-arm64 JSC maps its executable pool with `MAP_JIT` and flips per-thread W^X
with `pthread_jit_write_protect_np()`. Neither exists on iOS. What iOS actually
allows, probed on device with each strategy in a forked child so a fault does
not end the run:

| strategy | result |
|---|---|
| `mmap` RW | ok |
| `mmap` RWX | mapping succeeds |
| `mmap` with `MAP_JIT` (any prot) | **fails, `EINVAL`** |
| write to an RWX page, then execute it | **`SIGBUS`** |
| `mmap` RW → write → `mprotect` RX → execute | **works** |
| `mmap` RWX → write → `mprotect` RX → execute | **works** |

iOS enforces W^X: it will not execute a page that is *currently* writable, but
it will let `mprotect` flip a page between RW and RX. That is enough.

### The shim

`packaging/payload/shim.c` is built against the iPhoneOS SDK into a 68 KB
`libshim.dylib` and does two jobs:

**JIT memory.**

* `mmap` — when called with `MAP_JIT` (0x0800), strips the flag, maps the region
  RW instead of RWX, and records it. This is JSC's executable pool.
* `pthread_jit_write_protect_np(enabled)` — `mprotect`s every recorded region to
  RX when `enabled` is 1 ("done writing, must be executable") and RW when 0
  ("about to write").
* `pthread_jit_write_protect_supported_np()` — returns 1.

The real `mmap` is resolved with `dlsym` on an explicit libSystem handle, not
`RTLD_DEFAULT`: the default search walks the global list and finds the shim's
own `mmap` first. A guard aborts with `[piios] fatal: mmap resolved to the shim
itself` rather than recursing, should that ever happen.

**The missing symbol.**

* `__clear_cache` → `sys_icache_invalidate`, iOS's spelling of the same operation
  (the JIT calls it after emitting code).

The shim also defines `posix_spawn_file_actions_addfchdir`, which Pi 0.85.1 does
not import but Claude Code's newer Bun does. The patcher treats it as optional
and repoints it only if it turns up, so a Bun bump does not need a new shim.

Set `PIIOS_SHIM_DEBUG=1` to have the shim print the JIT pool mapping and any
`mprotect` failure to stderr.

### The one load-bearing setting

The real `pthread_jit_write_protect_np` is **per-thread**; `mprotect` is
**process-wide**. With JSC's concurrent JIT enabled, a background compiler
thread flips the pool to RW while the main thread is executing from it, and Bun
dies with `panic: Bus error`.

The wrapper therefore sets:

```
BUN_JSC_useConcurrentJIT=0
```

Compilation happens on the mutator thread instead, so nothing flips the pool
underneath running code. Baseline, DFG and FTL all stay enabled; only the
concurrency does not. **Never drop this setting.**

### Runtime environment

`/var/jb/usr/local/bin/pi-native` (which `pi` symlinks to) sets:

| variable | why |
|---|---|
| `BUN_JSC_useConcurrentJIT=0` | see above |
| `GIGACAGE_ENABLED=0` | see above |
| `PI_SKIP_VERSION_CHECK=1` | APT is the updater. Pi's own check would tell an iOS user to download the macOS build. Set with `-` rather than `:-`, so `PI_SKIP_VERSION_CHECK= pi` re-enables it |
| `HOME` | defaulted to `/var/jb/var/mobile` if unset |
| `PATH` | prefixed with `$LIB/shims`, which holds one symlink: `open` → `uiopen` |

and `exec`s `/var/jb/usr/local/lib/pi-native/runtime/pi`. `libshim.dylib` must
sit beside the binary — it is loaded as `@executable_path/libshim.dylib`.

### Search: ripgrep and fd

Pi's Grep and Glob tools shell out to `ripgrep` and `fd`. If it cannot find
them it downloads them from GitHub — and for `process.platform === "darwin"`,
which is what the patched binary reports, that means the **macOS** builds, which
cannot run here:

```
dyld: Library not loaded: /usr/lib/libiconv.2.dylib
  Reason: tried: '/usr/lib/libiconv.2.dylib' (wrong platform to load into process)
```

Worse, Pi looks in its own `~/.pi/agent/bin` *before* PATH, so once a macOS copy
lands there it permanently shadows a working one and every search fails.

Both tools exist in Procursus as native iOS builds (`ripgrep` 12.1.1, `fd`
8.6.0), so they are `Depends` and Pi finds them on PATH and never downloads
anything — confirmed by watching a first run leave `~/.pi/agent/bin` empty. For
the case where a copy is already there from another platform, the wrapper runs
each one once and deletes it if it cannot execute. That converges after a single
launch, because from then on PATH answers first.

### Credentials

Pi keeps provider credentials in `~/.pi/agent/auth.json`, a plain file it writes
itself, and reads the usual `*_API_KEY` environment variables. It never reaches
Security.framework, so the entitlements ask for no keychain group — the sibling
Claude Code port needs one and a whole login helper besides, and none of that
applies here.

## What the package contains

**Not Pi.** The `.deb` is about 16 KB and ships only:

| file | installed to | |
|---|---|---|
| `libshim.dylib` | `/var/jb/usr/local/lib/pi-native/` | the 68 KB shim, prebuilt against the iPhoneOS SDK |
| `piios_patch.py` | `/var/jb/usr/local/lib/pi-native/` | the Mach-O patcher |
| `shim.c` | `/var/jb/usr/local/lib/pi-native/` | shim source, so it can be rebuilt on device |
| `entitlements.plist` | `/var/jb/usr/local/lib/pi-native/` | JIT entitlements (`dynamic-codesigning`, `com.apple.security.cs.allow-jit`, `get-task-allow`, …) for `ldid` |
| `version.env` | `/var/jb/usr/local/lib/pi-native/` | upstream version, pinned SHA-256s, download URL |
| `shims/open` | `/var/jb/usr/local/lib/pi-native/` | symlink to `uiopen` |
| `pi-native` | `/var/jb/usr/local/bin/` | the wrapper |

The runtime is produced at install time by `packaging/DEBIAN/postinst`:

1. Check every tool it will invoke, by name, and check for ~500 MB free.
2. Stage in a temp directory *inside* that lib directory, not `/tmp`. The
   sandbox refuses to `mmap()` a dylib out of `/var/mobile`, so the smoke test
   in step 6 could not load `libshim.dylib` from there; staying on the same
   filesystem also makes the final swap a rename.
3. Download `pi-darwin-arm64.tar.gz` and refuse to continue unless it hashes to
   the SHA-256 pinned in `version.env`. Extract it, and check the executable
   inside against its own pinned hash too.
4. Run `piios_patch.py` on it. The patcher exits non-zero if the binary links a
   dylib outside the four known-good ones or no longer imports a symbol the shim
   provides, and the install aborts.
5. Sign with `ldid -S entitlements.plist`.
6. **Run it.** With `libshim.dylib` copied alongside and the wrapper's
   environment set, execute `./pi --version` and require the output to contain
   the expected version. If it does not run, the install aborts here, and the
   previously installed tree is untouched.
7. Swap it into place by rename in both directions, so `runtime/` is never
   absent or half-written, then point `/var/jb/usr/local/bin/pi` at the wrapper.
   A non-symlink `pi` already there — an npm install, most likely — is kept as
   `pi-legacy`; `prerm` hands `pi` back to it on removal.

No rollback copy of the previous tree is kept — the new one is verified before
the old one is touched, and a reinstall can always re-fetch.

The one consequence of this design is that installing needs a network
connection. Pi is MIT-licensed and could be redistributed, unlike the
proprietary binary the sibling port wraps; it is fetched rather than shipped
because a 31 MB `.deb` per release, ten releases deep for rollback, is a poor
fit for a repository served off GitHub Pages.

### Where the binary comes from

`https://github.com/earendil-works/pi/releases/download/v<version>/pi-darwin-arm64.tar.gz`,
the same artifact upstream's own install instructions use.

Each release publishes a `SHA256SUMS` asset covering its artifacts, and
`tools/build-deb.sh` requires the tarball it downloads to match the line for it,
then records both that hash and the hash of the executable inside into
`version.env`. The postinst re-checks both on device and aborts with

```
Refusing to install a build that is not the one this package was made against.
```

if either differs.

Being straight about what that is worth: `SHA256SUMS` and the tarball are
published by the same party over the same channel, so this is not the
two-independent-channels check the Claude Code port can do. Pi publishes no
second checksum to cross-check against. What the pin genuinely buys is that
every device installs the exact bytes CI inspected and accepted, and that a
release quietly rewritten in place stops the install rather than getting
patched.

## Updating

There is no custom updater. **APT is the updater.**

Pi's own `pi update self` is not disabled and does not need to be: for a Bun
standalone install it reports `pi cannot self-update this installation` and
changes nothing. Only the version *check* is turned off, because the advice it
would print — download the macOS build from GitHub releases — is wrong here.

### Where the packages come from

| | |
|---|---|
| `https://reallyitsandi.com/repo/` | the one to add — signed, and carries other packages too |
| `https://realandi.github.io/PiForiOS/` | where this repository's CI publishes its build |

The domain syncs from the Pages repo on its own schedule, verifying each package
against the checksum the upstream index declares, and keeps the newest few for
rollback. It only ever adds or replaces, so if Pages is unreachable the domain
keeps serving what it had.

`.github/workflows/publish.yml` runs every 30 minutes (and on
`workflow_dispatch`, and on pushes to `main` that touch `packaging/`, `tools/`
or the workflow). The orchestration is the reusable workflow in
[`realAndi/ios-port-ci`](https://github.com/realAndi/ios-port-ci), shared with
the other iOS ports and pinned at `@v1`; this repository supplies only the three
scripts in `tools/` and everything in `packaging/`. Its jobs:

1. **resolve** — `tools/resolve-version.sh` asks GitHub what the latest release
   is, via the `/releases/latest` redirect rather than the API, which on a
   shared runner egress IP has a permanently exhausted anonymous quota. Given a
   `workflow_dispatch` version it validates it instead, and fails immediately if
   no `pi-darwin-arm64.tar.gz` is published for it. Reads `packaging/revision`.
2. **payload** — `tools/build-payload.sh` builds and signs `libshim.dylib` on a
   macOS runner (the only step that needs the iPhoneOS SDK; the 75 MB Pi binary
   is never touched here) and asserts the result is signed, because iOS will not
   load a dylib without a cdhash.
3. **publish** — on Ubuntu: `tools/build-deb.sh` fetches the real upstream
   tarball, checks it against `SHA256SUMS`, runs `piios_patch.py --check`, and
   builds the 16 KB package with version `<upstream>-<revision>`. The shared
   `fetch-published.sh` pulls the packages already on the live repo forward and
   keeps the newest 10, `make-repo.py` regenerates `Packages{,.gz,.bz2,.xz}` and
   `Release` and signs them, and the result is deployed to GitHub Pages.

The resolve job skips a scheduled run whose version-revision is already
published, so a poll that finds nothing new costs a few seconds on one Ubuntu
job and deploys nothing.

**Bump `packaging/revision`** when the payload changes but the upstream version
does not. Otherwise apt sees a version it already has and offers nobody the
upgrade, while CI stays green. `build-deb.sh` guards against this by diffing the
package contents against what is already published and failing if they differ at
the same version.

## Building locally

```sh
tools/build-payload.sh 0.85.1     # macOS: needs the iPhoneOS SDK and ldid
tools/build-deb.sh                # needs dpkg-deb, curl, python3
```

`tools/ci.sh` clones `realAndi/ios-port-ci` into `.ci/` on first use, so the
shared `check-macho.py` runs the same way on a laptop as on a runner.

`tools/make-icon.py` regenerates `assets/icon.png` — pure stdlib, no image
libraries.

## Verifying on device

`ssh iphone`. Test in this order, because a failure early is easily mistaken for
one later:

1. `pi --version` / `pi --help` — does the runtime come up at all as a bare CLI?
   Check stderr is clean and `cwd` is preserved. To separate "the shim loaded"
   from "the JIT emulation works", run `BUN_JSC_dumpOptions=2 pi --version` and
   look for `useJIT=true` and `useConcurrentJIT=false`.
2. Network — `pi --provider anthropic --model claude-sonnet-4-5 --api-key
   sk-ant-invalid -p hi` and expect a real `401`, not a connection error. That
   proves DNS (libresolv), TLS, and certificate-chain verification.
3. Search — launch the TUI once and confirm `~/.pi/agent/bin` stays empty. A
   line saying `ripgrep not found. Downloading...` means PATH is wrong and the
   macOS build is about to be installed where it will shadow the working one.
4. Subprocesses — `!echo $$` in the TUI.
5. TUI under a pty — `ssh -tt`, and let the process own the pty (piping to
   `head` on the remote side steals it).

Install with `dpkg -i`, not by side-loading, so `postinst` is exercised.
`dpkg -V com.andi.pi-coding-agent` afterwards confirms the shipped files match;
it will not mention `runtime/`, which the postinst builds and dpkg does not own.

## Known gaps

* **No model session has been run end to end**, for want of an API key. The
  network path, the process spawn and the search binaries are each verified;
  their composition through a real tool call is not.
* **Clipboard and modifier keys do not work.** Pi's helpers for those are
  native modules — `clipboard.darwin-arm64.node` links AppKit, CloudKit and
  CoreData, none of which exist on iOS. Pi loads them inside a `try` and
  degrades quietly, so nothing breaks; the features are simply absent. They are
  left in the tree rather than deleted, so the installed runtime stays exactly
  upstream's tarball plus a patched executable.
* **Image resizing is untested.** It runs through a WASM module
  (`photon_rs_bg.wasm`) in a worker, which is present and shipped.

## License

MIT, matching upstream. This repository contains the patcher, the shim and the
packaging; the Pi binary it installs is downloaded from Earendil Works and is
MIT-licensed too.
