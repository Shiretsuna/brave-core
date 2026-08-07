# Kitsune

A debranded Brave fork: Brave's privacy engine, without the crypto/BAT and
communication add-ons, and with Google as the default search engine.

## What is removed, and how

The feature removals are **baked into this fork's buildflag defaults** rather
than passed as build arguments, so they are version-controlled and apply to any
checkout with no special invocation:

| Flag | File | Removes |
|---|---|---|
| `enable_brave_wallet` | `components/brave_wallet/common/buildflags/buildflags.gni` | Crypto wallet |
| `enable_brave_rewards` | `components/brave_rewards/core/buildflags/buildflags.gni` | BAT rewards |
| `enable_brave_talk` | `components/brave_talk/buildflags/buildflags.gni` | Brave Talk |
| `enable_web_discovery`<br>`enable_web_discovery_native` | `components/web_discovery/buildflags/buildflags.gni` | Web Discovery + its opt-in nags |

> **Keep these four in lockstep.** Upstream they all default to
> `!is_brave_origin_branded` — Brave Origin, a shipping Brave product, disables
> exactly this set, so all-off is a configuration Brave actually builds and
> tests. Disabling only *some* of them yields untested combinations that fail to
> compile. This cost a 7.5-hour build once: `enable_web_discovery=false` with
> rewards still enabled dies at `rewards_page_handler.cc:636`, which references
> `kWebDiscoveryEnabled` without guarding it behind the buildflag.

These four lines are the expected conflict points when rebasing on upstream.
They are one-liners and obvious to resolve.

## Search engine

Default is Google in both normal and private windows:

- `chromium_src/components/regional_capabilities/regional_capabilities_utils.cc`
  — `GetDefaultEngine()` returns Google unconditionally instead of resolving a
  versioned per-country map (which returned Brave Search for most major
  markets).
- `browser/search_engines/search_engine_provider_util.cc` —
  `SetBraveAsDefaultPrivateSearchProvider()` hardcoded the Brave engine ID on a
  path independent of the regular-window default.

**Tor windows deliberately still use `brave_search_tor`.** Google has no
`.onion` endpoint, so switching it would push Tor searches onto a clearnet
domain — a privacy regression, not a branding change.

Brave Search remains selectable in the engine list; it is simply not the
default.

## Building

`kitsune/kitsune.ps1` wraps the normal `pnpm run build` with machine tuning
(job count, symbol level). Feature flags are *not* passed here — they live in
the `.gni` files above.

```powershell
C:\kitsune\kitsune.ps1 build          # component build
C:\kitsune\kitsune.ps1 build -Jobs 4  # fewer jobs if the box thrashes
C:\kitsune\kitsune.ps1 package        # stage + zip a runnable tree
C:\kitsune\kitsune.ps1 status         # branch, tools, RAM, out/ size
```

`build-release` will very likely OOM on a 16 GB machine (full LTO). Component
dev builds are fine.

### A component build is not portable

The build splits across ~585 DLLs, so `brave.exe` alone will not run elsewhere.
`package` stages the runtime files (excluding `obj/`, `gen/`, `.pdb`) into a
zip — roughly 684 MB versus 17 GB for the full output directory.

## Build host notes

Documented in the repo only so they are not lost; specific to the current
setup.

- `DEPOT_TOOLS_WIN_TOOLCHAIN=0` is **required** for non-Googlers, otherwise
  depot_tools tries to fetch Google's internal hermetic toolchain.
- Chromium probes `%ProgramFiles%\Microsoft Visual Studio\2022\<edition>`, but
  VS **BuildTools** installs under `Program Files (x86)`. Set the
  `vs2022_install` env var — `vs_toolchain.py` checks it before its hardcoded
  paths.
- `gn gen` needs **Debugging Tools for Windows**, which Visual Studio does not
  install by default. Add via
  `winsdksetup.exe /features OptionId.WindowsDesktopDebuggers`.
- brave-core's `devPreinstall.ts` hard-requires **Windows Developer Mode**
  (`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowDevelopmentWithoutDevLicense=1`).
- Exclude the checkout from Windows Defender; real-time scanning of build
  artifacts is a pure tax.
- If setup ran as SYSTEM while you work as another user, git reports "dubious
  ownership" across all ~100 repos in the tree. Fix with
  `git config --system --add safe.directory '*'`. Note `icacls` does **not**
  fix this — it grants permissions, and git checks *ownership*.
