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
| `tests/module-config.nix` | assertions on the generated config and unit (no KVM) |
| `tests/zot-referrers.nix` | behavioural test of the module (needs KVM, see below) |

## Outputs

```
overlays.default                 # pkgs.zot
nixosModules.zot                 # services.zot
nixosModules.default             # = nixosModules.zot
packages.<system>.zot            # the binary
packages.<system>.default        # = zot
apps.<system>.default            # run the registry
devShells.<system>.default       # zot, htpasswd, nix-prefetch-github, go
```

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

## Updating zot

```sh
nix develop
nix-prefetch-github project-zot zot --rev v2.1.18
```

Put the `hash` into `pkgs/zot.nix`, then build. `buildGoModule` will reject
the stale `vendorHash` with a `got: sha256-...` line; paste that value in and
build again.

The binary is built with `subPackages = [ "cmd/zot" ]` -- the core registry as
defined by the OCI Distribution Specification, without extensions. The
Referrers API is part of that core, so SBOM and signature discovery works; the
extensions add the web UI, GraphQL search, CVE scanning and friends. The `tags`
line in `pkgs/zot.nix` turns them on.

## Tests

`tests/module-config.nix` reads what the module *generates* -- the zot config
file and the systemd unit, both straight out of the evaluation -- and asserts
on the things that break silently: the port as a string rather than a number
(zot rejects a number at startup with an unhelpful message), the
`/run/credentials/zot.service/htpasswd` path rather than a `%d` specifier zot
would never expand, `deleteReferrers = false`, anonymous pull, `DynamicUser`,
`StateDirectory`, `ProtectSystem`, and that both of the module's own assertions
fire when they should. It is a plain derivation, so it needs no VM and runs on
any builder:

```sh
nix build .#checks.x86_64-linux.zot-module-config
```

`tests/zot-referrers.nix` is the behavioural half: boot a VM running the
module, push an artifact, attach a referrer and assert it is discoverable
through the *native* `/v2/<name>/referrers/<digest>` endpoint rather than only
through oras' fallback to the Referrers Tag Schema. That distinction is the
reason this registry was chosen (ADR-006), so it is the assertion that carries
the weight.

It needs `/dev/kvm`, and is therefore commented out in `flake.nix`. Run it
locally, where KVM exists, before pushing:

```sh
nix build .#checks.x86_64-linux.zot-referrers -L   # after uncommenting
```

On the argunix dev instance it will not run until a builder with `/dev/kvm` is
enrolled. A builder that cannot verify the device no longer advertises the
`kvm` feature, so the check fails fast with the scheduler's capability dump
rather than hanging in `queued`.

## CI

`.github/workflows/ci.yml` runs `nix flake check -L` on every pull request
and on `main`. That is the merge gate: branch protection on `main` requires
the "flake check" job and has "Allow auto-merge" enabled, so a Renovate PR
waits for it instead of merging the moment it opens.

argunix deliberately does **not** watch this repository. argunix exists to
build and publish artefacts, and nothing here carries `meta.image-format`, so
it would publish nothing; and the check that gates a merge belongs where the
merge decision is made, which is GitHub. argunix enters one step later, in
[stack4ops/images](https://github.com/stack4ops/images), which consumes this
repository's overlay.

Open option, recorded so it does not simply drop out of sight: argunix could
watch this repository *in addition*, publishing nothing, purely as the signal
"can my own infrastructure still build this". That is the dogfooding the dev
instance exists for (ADR-003), and giving it up is the one real cost of
gating on a GitHub runner. The merge gate would stay where it is -- the two
answer different questions.
