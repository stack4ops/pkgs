# stack4ops/pkgs

Nix packages and the NixOS modules that run them.

This repository holds the *sources*: a package derivation and, where the thing
is a service, the NixOS module that runs it. It does not build container
images. Those live in [stack4ops/images](https://github.com/stack4ops/images),
which consumes the overlay from here.

The split follows ADR-010. The short version: a package and its NixOS module
version together and belong in one tree, the way nixpkgs keeps `pkgs/` and
`nixos/modules/` together. An image is a downstream artefact of a package, has
a different release cadence and a different failure mode, and gets its own
repository.

## Contents

| Path | What |
|---|---|
| `pkgs/zot.nix` | the zot binary (`buildGoModule`, minimal build, no extensions) |
| `modules/zot.nix` | `services.zot` -- DynamicUser, systemd hardening, htpasswd via `LoadCredential` |
| `overlay.nix` | exposes `pkgs.zot` |
| `tests/module-config.nix` | assertions on the generated config and unit |
| `tests/zot-referrers.nix` | behavioural test of the module, in a systemd-nspawn container |

## Outputs

```
overlays.default                 # pkgs.zot
nixosModules.zot                 # services.zot
nixosModules.default             # = nixosModules.zot
packages.<system>.zot            # the binary
packages.<system>.default        # = zot
apps.<system>.default            # run the registry
devShells.<system>.default       # zot, htpasswd, nix-update, go
checks.<system>.zot-module-config
checks.x86_64-linux.zot-referrers
```

Note the asymmetry on the last line. `systems` covers `x86_64-linux` and
`aarch64-linux`, the latter built under binfmt emulation, but `zot-referrers`
is exposed for x86_64 only. See [Tests](#tests) for why.

## Use it

As a NixOS consumer:

```nix
{
  inputs.stack4ops-pkgs = {
    url = "github:stack4ops/pkgs";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # in the host configuration
  imports = [ inputs.stack4ops-pkgs.nixosModules.zot ];
  nixpkgs.overlays = [ inputs.stack4ops-pkgs.overlays.default ];

  services.zot = {
    enable = true;
    htpasswdFile = config.age.secrets.zot-htpasswd.path;
    pushUsers = [ "argunix" ];
  };
}
```

Note that the module and the overlay are separate imports. The module defaults
`services.zot.package` to `pkgs.zot`, which only exists once the overlay is
applied; set `package` explicitly if you would rather not apply it.

Just the binary:

```sh
nix build github:stack4ops/pkgs#zot
./result/bin/zot --version
```

The binary is built with `subPackages = [ "cmd/zot" ]` -- the core registry as
defined by the OCI Distribution Specification, without extensions. The
Referrers API is part of that core, so SBOM and signature discovery works; the
extensions add the web UI, GraphQL search, CVE scanning and friends. The `tags`
line in `pkgs/zot.nix` turns them on.

## Updating zot

Renovate notices a release and bumps the annotated `version` in
`pkgs/zot.nix`. It cannot compute `src.hash` or `vendorHash`: both are
fixed-output hashes, and a fixed-output derivation needs its hash *before* it
is allowed to fetch anything. No amount of Nix evaluation produces them either
-- evaluation has no network at all. The hashes have to come from somewhere
that is allowed to build.

That somewhere is `nix-update`, run as a `postUpgradeTasks` command: Renovate
executes it after applying the update and before committing, so the corrected
hashes land in the *same* commit and the pull request is correct on its first
build. There is no fixup commit and therefore no race between a fixup landing
and automerge firing.

This works because Renovate runs as a service on the argunix coordinator, a
NixOS host where `nix` and `nix-update` simply exist. The GitHub-Actions-hosted
bot it replaced could not do this without a purpose-built container image.

Three pieces of configuration, in two places:

**On the host** (`renovate.nix` on the coordinator) -- these are self-hosted
options, ignored in a repository config:

```nix
services.renovate = {
  runtimePackages = [ pkgs.nix pkgs.nix-update ];
  settings.allowedCommands = [
    "^nix-update --flake --version [0-9][0-9a-zA-Z.-]* [a-zA-Z0-9_-]+$"
  ];
};
```

**Here**, in `renovate.json`:

```json
{
  "packageRules": [
    {
      "matchDepNames": ["project-zot/zot"],
      "postUpgradeTasks": {
        "commands": ["nix-update --flake --version {{{newVersion}}} zot"],
        "fileFilters": ["pkgs/zot.nix"],
        "executionMode": "update"
      }
    }
  ]
}
```

`allowedCommands` is an allowlist of regular expressions; a command that does
not match is **silently not run**. The anchors matter. Note also that since
Renovate 43 these commands no longer run inside a shell, which is why the
command above is plain argv -- a command using `&&` or a pipe would fail
quietly and need `allowShellExecutorForPostUpgradeCommands`.

`fileFilters` restricts what gets committed after the command runs; anything
touched outside that list is discarded. `nix-update` writes only
`pkgs/zot.nix`.

### When a pull request arrives with stale hashes anyway

The symptom is a red `argunix: evaluation` on a `src.hash` mismatch, with
nothing pointing at the cause. Check, in order: that `nix-update` is on the
Renovate service's PATH; that the templated command matches the
`allowedCommands` regex exactly; and that `fileFilters` covers `pkgs/zot.nix`.
A run with `LOG_LEVEL=debug` says which of the three it is.

Meanwhile, and whenever it misbehaves, the manual path is one command:

```sh
nix develop
nix-update --flake --version <new version> zot
```

Commit that onto the Renovate branch and the next argunix build is green.

## Tests

`tests/module-config.nix` reads what the module *generates* -- the zot config
file and the systemd unit, both straight out of the evaluation -- and asserts
on the things that break silently: the port as a string rather than a number
(zot rejects a number at startup with an unhelpful message), the
`/run/credentials/zot.service/htpasswd` path rather than a `%d` specifier zot
would never expand, `deleteReferrers = false`, anonymous pull, `DynamicUser`,
`StateDirectory`, `ProtectSystem`, and that both of the module's own assertions
fire when they should.

It is a plain derivation, so it runs anywhere, emulated architectures
included, and it is where the hardening directives are asserted -- a container
applies some of them differently, so the generated unit is the honest place to
check them.

```sh
nix build .#checks.x86_64-linux.zot-module-config
```

`tests/zot-referrers.nix` is the behavioural half: run the module, push an
artifact, attach a referrer and assert it is discoverable through the *native*
`/v2/<name>/referrers/<digest>` endpoint rather than only through oras'
fallback to the Referrers Tag Schema. That distinction is the reason this
registry was chosen (ADR-006), so it is the assertion that carries the weight.

Its node is a **systemd-nspawn container**, not a virtual machine. It needs no
`/dev/kvm` -- only a builder that advertises `uid-range`:

```nix
nix.settings = {
  auto-allocate-uids = true;
  extra-experimental-features = [ "auto-allocate-uids" "cgroups" ];
  extra-system-features = [ "uid-range" ];
};
```

`uid-range` gives the build root inside a user namespace with 65536 UIDs,
which is what nspawn needs; `auto-allocate-uids` is a prerequisite of it, and
both the setting and the experimental feature have to be present or the
generated `nix.conf` fails validation. Use `extra-system-features`, not
`system-features`: the latter replaces Nix's defaults and silently drops
`nixos-test` and `kvm` along with them.

```sh
nix build .#checks.x86_64-linux.zot-referrers -L
```

On a shared-vCPU cloud instance with no KVM at all this completes in about six
seconds, boot included.

Two things to know about it:

**x86_64 only, and the merge gate depends on that.** The derivation requires
the `nixos-test` feature, and argunix counts that feature only on a builder
whose *native* system matches -- a builder serving aarch64 through binfmt
cannot run an aarch64 container test meaningfully, so it is refused rather
than scheduled. Exposed for aarch64 with no native aarch64 builder enrolled,
the job lands in `SkippedNoBuilder`, which counts as interrupted, which turns
`argunix: evaluation` to Error. Permanently red, on the one status that gates
merges. Widen it the day a native aarch64 builder with `uid-range` exists.

**What a container cannot do**, recorded so a future assertion is not written
against it: no custom kernel, no setuid (the Nix sandbox forbids it, so
`security.wrappers` is disabled on the test node), no ACLs on the build
filesystem (hence `networking.resolvconf.enable = false` there), and systemd
hardening that is applied selectively depending on the container's privileges.
A module that genuinely needs any of those belongs in a VM test.

Note for whoever enrols a builder: the test driver's closure still pulls QEMU
and its VM networking stack even for a container-only run. That is roughly a
quarter of a gigabyte of download that never executes, which matters on a
disk-constrained builder with pressure-triggered GC.

## Builds and the merge gate

**There is no CI in this repository.** No `.github` directory, no workflows.
argunix watches it, evaluates the flake and builds every attribute under
`packages`, `checks` and `devShells` -- which is both tests above, on real
builders with capabilities a hosted runner does not have.

argunix posts commit statuses back to the forge. Three contexts appear:

| Context | What it is |
|---|---|
| `argunix: evaluation` | the rollup over the whole evaluation |
| `argunix: <attr path>` | one per job, e.g. `argunix: checks.x86_64-linux.zot-referrers` |
| `argunix: registry · <target>` | publishing effects; none in this repository |

**Branch protection requires `argunix: evaluation`, and nothing else.** Two
reasons, both load-bearing:

- It is the only stable name. A per-job context contains the attribute path,
  so requiring one of those and later renaming or removing that check means
  the required status never appears again and every pull request blocks
  forever.
- Despite the name it is not the evaluation's status, it is the rollup:
  pending while builds run, then Success only if no job failed and none was
  interrupted. A job that found no matching builder counts as interrupted and
  the status goes to Error, so an unbuildable check cannot read as green.

Above a threshold (100 jobs by default) argunix collapses to that single
rolling status and suppresses the per-job ones. This repository is far below
it, so both appear -- but because the gate is the rollup, it behaves the same
either way.

These are **commit statuses**, not the Checks API, so they appear in the merge
box at the bottom of a pull request and *not* in its "Checks" tab. That is the
usual reason someone concludes argunix posts nothing. The forge token needs
`Commit statuses: read/write`.

Nothing here carries `meta.image-format`, so argunix publishes nothing from
this repository -- it evaluates, builds and reports. Publishing happens one
step later in [stack4ops/images](https://github.com/stack4ops/images), which
consumes this repository's overlay.