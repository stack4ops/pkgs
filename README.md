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

`tests/zot-referrers.nix` boots a VM running the module, pushes an artifact,
attaches a referrer and asserts it is discoverable through the *native*
`/v2/<name>/referrers/<digest>` endpoint rather than only through oras'
fallback to the Referrers Tag Schema. That distinction is the reason this
registry was chosen (ADR-006), so it is the assertion that carries the weight.

It needs `/dev/kvm`, and the `checks` block in `flake.nix` is therefore
commented out. Locally:

```sh
nix build .#checks.x86_64-linux.zot-referrers   # after uncommenting
```

On the argunix dev instance it will not run until a builder with `/dev/kvm` is
enrolled. A builder that cannot verify the device no longer advertises the
`kvm` feature, so the check sits unscheduled rather than failing with a
confusing boot log.

## CI

Watched by argunix. argunix builds every attribute of every system in
`services.argunix.systems` and publishes only outputs carrying
`meta.image-format` -- nothing here does, so this repository is a build and
test target only, and doubles as cache warming for the images repository,
which builds its image from the identical `zot` derivation.
