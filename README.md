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

Pi talks to whatever model provider you have an API key for, and signs in
through the same `pi` TUI as everywhere else. That makes this a much smaller
port than the sibling [CCForiOS](https://github.com/realAndi/CCForiOS): no
OAuth helper, no login command of its own. The whole port is a Mach-O patch, a
68 KB shim, a keychain helper, and a wrapper that sets four environment
variables and keeps the credential file off disk between runs.

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
stores the credential in the **iOS keychain** — see
[Where the credential is stored](#where-the-credential-is-stored).
Environment-variable keys are unaffected by any of it.

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

and runs `/var/jb/usr/local/lib/pi-native/runtime/pi` as a child. `libshim.dylib`
must sit beside the binary — it is loaded as `@executable_path/libshim.dylib`.

The child, not an `exec`d process, is deliberate: the wrapper has to outlive Pi
to run the exit half of the credential sync (see [Where the credential is
stored](#where-the-credential-is-stored)) and to pass the exit status through.
With `PI_PLAINTEXT=1` there is nothing to sync and the wrapper `exec`s directly,
as it always did. Cost when the sync is on: one idle zsh per session.

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

### Where the credential is stored

Pi keeps provider credentials in `~/.pi/agent/auth.json`, a plain JSON file it
reads and writes itself — on `/login`, on token refresh, whenever a provider is
added or removed. Unlike the sibling Claude Code port, nothing here needs to do
the OAuth flow for it, and nothing needs to translate the credential into a
shape Pi cannot produce: Pi's own sign-in works as-is.

The problem is where the file lives. On a rootless jailbreak `$HOME` is
`/var/jb/var/mobile`, which is physically on the **preboot volume** — the same
volume as the jailbreak itself, rebuilt on an iOS update and replaced on a
jailbreak reinstall, and not rewritten by "Erase All Content and Settings",
which crypto-shreds only the data volume; a preboot copy leaves with the phone.

So the port owns the file's **rest state** and nothing else. Pi still reads and
writes it exactly as upstream; the wrapper (`pi-native`) moves it around the
run:

* **before** — if the keychain holds a copy, materialise `auth.json` from it,
  unless an identical file is already there. A leftover file that *differs* is
  treated as newer — it is what a run that was killed before it could sync
  wrote — and is imported into the keychain. A file holding exactly `{}` is
  never imported over a populated keychain: that is what Pi writes when a
  credential operation finds the file missing, so it means "there was no file",
  not "the user logged out".
* **after** — if `auth.json` changed, store the whole file back into the
  keychain (last writer wins; the keychain is always updated), then remove the
  file. Nothing with a secret sits on the preboot volume between runs.

The blob is the whole `auth.json`, provider-agnostic: one generic-password item
covers every provider at once, and the sync code never parses it. Concurrency
is handled by removing the file only when no other `pi` process is running — an
earlier exit stores its changes but leaves the file for the session still
using it, and that session's exit repeats the same steps.

The keychain item is created by `pi-keychain`, a small helper installed next to
the binary: `kSecClassGenericPassword`, service
`com.andi.pi-coding-agent.auth`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
authorized by the package's entitlements (`keychain-access-groups:
com.andi.pi-coding-agent`). Three properties fall out of that, all of which the
plain file lacked:

* **The item lives on the data volume** (`/var/Keychains/keychain-2.db`),
  outside `/var/jb` and the preboot volume. An iOS update or a jailbreak
  reinstall rebuilds the jailbreak root — the package has to be reinstalled
  either way, but the sign-in survives, for every provider at once.
* **"Erase All Content and Settings" destroys it.** The item is wrapped in the
  device keybag, which erase crypto-shreds. A wiped and sold phone takes no
  credential with it; the preboot copy of a plain file would survive.
* **It is excluded from backups and device-to-device restores**
  (`ThisDeviceOnly`), so the credential does not ride along to another device.

An `auth.json` from a previous, pre-keychain install is migrated on the first
launch: it is imported into the keychain, used for that run, and removed at the
end of it. If the keychain misbehaves on a given device, `PI_PLAINTEXT=1`
restores the old behaviour — `auth.json` is the store, mode `0600`, no keychain
involved, file left in place between runs. API keys in environment variables
(`ANTHROPIC_API_KEY` and the rest) never touch `auth.json` or the keychain and
work exactly as upstream.

### What the keychain does and does not protect against

A stored `/login` credential can act as its account on every provider it
covers, so it is worth being precise about where the protection ends:

| scenario | plain `auth.json` (the old rest state) | keychain (now) |
|---|---|---|
| "Erase All Content and Settings", then the phone is sold | **survives** — erase crypto-shreds the data volume, but the preboot copy is only rewritten by a full restore | gone — the item is wrapped in the device keybag, which erase destroys |
| stolen device, offline image of the flash | readable bytes | requires the device's passcode-bound class keys |
| backups / restored onto another device | not backed up (preboot is outside the backup roots) | `ThisDeviceOnly` — excluded by construction |
| another process on a stock iOS device | anything running as the same user | blocked without the package's keychain access group |
| a process with root on the jailbroken device | readable | **readable** — see below |

That last row is the honest limit, and no storage scheme changes it: a
jailbroken device has no security boundary against root, and the entitlement
that authorizes keychain access is ldid-fake-signable by anything that can
already run code on the device. The keychain is not protecting the credential
from the phone's owner-with-root; it is protecting it from everyone the phone
might belong to after it leaves your hands — the buyer, the thief, the offline
image. Against the live-root threat the mitigations are behavioural, not
technical: treat stored credentials like pasted API keys, and log out of
providers you do not need before handing the device on.

Two edges of the sync itself, stated plainly:

* **A crash between write and remove leaves the plaintext in place.** If the
  wrapper is killed after Pi wrote `auth.json` but before the exit sync — a
  `SIGKILL`, a dead ssh session, a battery cut — the file survives one run. The
  next launch imports it into the keychain and removes it, so the worst case is
  the plaintext sitting in a `0700`/`0600` directory until the next run, not
  its loss.
* **Concurrent sessions are last-writer-wins.** The keychain always receives
  whatever the most recently exited session saw; the file is only removed by
  the last session out. Two sessions signing in to different providers at the
  same moment can, in principle, leave one of the two changes as the keeper —
  the same semantics as two machines sharing a file, without anything being
  silently dropped on the floor.

## What the package contains

**Not Pi.** The `.deb` is about 16 KB and ships only:

| file | installed to | |
|---|---|---|
| `libshim.dylib` | `/var/jb/usr/local/lib/pi-native/` | the 68 KB shim, prebuilt against the iPhoneOS SDK |
| `pi-keychain` | `/var/jb/usr/local/lib/pi-native/` | the keychain helper, prebuilt and ldid-signed with the package entitlements (re-signed in place by the `postinst`) |
| `pi-keychain.c` | `/var/jb/usr/local/lib/pi-native/` | helper source, so it can be rebuilt on device |
| `piios_patch.py` | `/var/jb/usr/local/lib/pi-native/` | the Mach-O patcher |
| `shim.c` | `/var/jb/usr/local/lib/pi-native/` | shim source, so it can be rebuilt on device |
| `entitlements.plist` | `/var/jb/usr/local/lib/pi-native/` | entitlements for `ldid`: the JIT set (`dynamic-codesigning`, `com.apple.security.cs.allow-jit`, `get-task-allow`, …) plus `keychain-access-groups: com.andi.pi-coding-agent`, which is what authorizes the helper's SecItem access |
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
8. Re-sign the *installed* keychain helper with the entitlements (signing only
   the staged copy is the bug shape that produces a deb whose probe works
   locally and fails on device), run its `probe` subcommand — advisory: a
   failure is a loud warning, never a failed install — and look in the keychain
   when deciding whether to print a set-a-key hint or a run-hint.

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

Sign-ins survive updates: the keychain item is not part of the package or the
jailbreak, so neither an upgrade of this package nor an iOS update nor a
jailbreak reinstall touches it (`prerm` deletes it only on `purge` — see
[Where the credential is stored](#where-the-credential-is-stored)).

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
6. Credentials — verify by exit codes and file absence, never by printing
   contents:
   ```sh
   /var/jb/usr/local/lib/pi-native/pi-keychain probe    # expect "probe: ok"
   # place a credential (sign in with /login, or for a pure storage test:
   printf '{"test-provider":{"type":"api","key":"sk-test"}}' \
       | /var/jb/usr/local/lib/pi-native/pi-keychain set
   /var/jb/usr/local/lib/pi-native/pi-keychain get >/dev/null; echo $?  # 0
   pi -p 'reply with the single word OK'; echo $?                       # exits cleanly
   test -e ~/.pi/agent/auth.json && echo "MIRROR LEFT BEHIND" || echo "file absent"
   /var/jb/usr/local/lib/pi-native/pi-keychain del                      # clean up
   ```
   And the strongest check of all — the keychain database itself, on the data
   volume, must never contain the JSON:
   `sudo grep -ac sk-test /var/Keychains/keychain-2.db` → `0`. (The db is a
   binary file, so grep counts matching "lines"; anything above zero means a
   credential leaked to disk in the clear and the design failed.)

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
* **The exit sync can be skipped by a hard kill.** `SIGKILL`, a dead ssh
  session or a battery cut after Pi wrote `auth.json` but before the wrapper's
  after-exit sync leaves the plaintext in place until the next launch, which
  imports it into the keychain and removes it. Ctrl+C and normal exits run the
  sync; the window is the crash itself, and the worst case is the file sitting
  in a `0700` directory for one run, not its loss.

## License

MIT, matching upstream. This repository contains the patcher, the shim and the
packaging; the Pi binary it installs is downloaded from Earendil Works and is
MIT-licensed too.
