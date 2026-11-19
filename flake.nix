{
  description = "stack4ops Nix packages and NixOS modules";

  inputs = {
    # Pinned to the release the consuming hosts track. Following unstable here
    # would drag a second nixpkgs instance -- and a second Go toolchain and
    # cacert -- into any system that imports this flake.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    inputs:
    let
      # Explicit rather than flake-utils' eachDefaultSystem, so the list is a
      # visible decision.
      #
      # aarch64-linux is built under binfmt emulation on the x86_64 builder,
      # not natively. That is fine for everything here except the behavioural
      # test; see `checks` below for why that one is gated.
      #
      # Two gates have to agree before any of this reaches CI: this list, and
      # `services.argunix.systems` on the coordinator. argunix only walks the
      # systems named there, so an entry here alone stays invisible.
      #
      # "aarch64-darwin"
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      eachSystem =
        systems: f:
        builtins.foldl' (
          acc: system:
          let
            outputs = f system;
          in
          builtins.foldl' (
            acc': name:
            acc'
            // {
              ${name} = (acc'.${name} or { }) // {
                ${system} = outputs.${name};
              };
            }
          ) acc (builtins.attrNames outputs)
        ) { } systems;

      inherit (inputs.nixpkgs) lib;
    in
    {
      # Not per-system, so outside eachSystem.
      #
      # This is the output the images repository consumes. It takes the
      # overlay rather than `packages.<system>.zot` on purpose: an overlay is
      # a plain function and carries no nixpkgs with it, so the consumer keeps
      # exactly one nixpkgs instance in its closure and decides the pin
      # itself. Depending on `packages` instead would pin this flake's
      # nixpkgs into every consumer's closure.
      overlays.default = import ./overlay.nix;

      # The module defaults `services.zot.package` to `pkgs.zot`, so a
      # consumer that applies the overlay above needs no further wiring.
      nixosModules.zot = ./modules/zot.nix;
      nixosModules.default = inputs.self.nixosModules.zot;
    }
    // eachSystem systems (
      system:
      let
        pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [ inputs.self.overlays.default ];
        };
      in
      {
        # Plain names, no suffixes. The `zot-bin` name this package used to
        # carry existed only to avoid colliding with the image of the same
        # name when both sets were merged into one `packages`. With the image
        # in its own repository the collision is gone -- and since argunix
        # derives the registry path from the attribute name, there is also no
        # risk of a package accidentally being published: nothing here carries
        # meta.image-format, so argunix builds these and pushes none of them.
        #
        # The aarch64 variant compiles under qemu-user. Expect it to take an
        # order of magnitude longer than the native one, the Go test suite
        # included -- correct, just slow.
        packages = {
          zot = pkgs.zot;
          default = pkgs.zot;
        };

        apps.default = {
          type = "app";
          program = lib.getExe pkgs.zot;
          meta.description = "Run the zot registry";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.zot
            # htpasswd, for generating the push credentials the module's
            # htpasswdFile option wants.
            pkgs.apacheHttpd
            # Bumping zot: nix-update rewrites version, src.hash and
            # vendorHash in pkgs/zot.nix in one pass. This is the manual
            # fallback for when Renovate's postUpgradeTasks did not run --
            # see "Updating zot" in the README.
            pkgs.nix-update
            # For reading the module graph when a bump moves vendorHash
            # unexpectedly, which is the one case worth looking at.
            pkgs.go
          ];
        };

        checks =
          {
            # Assertions on what the module GENERATES: the zot config file and
            # the systemd unit, both read straight out of the evaluation.
            #
            # Runs on every system in the list, aarch64 included: it is a plain
            # derivation whose build is a shell script and some jq, so under
            # emulation it is merely slow rather than meaningless. What it
            # checks -- the generated config and unit -- is architecture
            # independent anyway.
            #
            # nixosSystem is passed in rather than reached for inside the test,
            # so the nixpkgs it evaluates against is this flake's pinned one.
            #
            # `nixpkgs.pkgs = pkgs` hands it the instance built above, overlay
            # and all. Without it nixosSystem instantiates a FRESH nixpkgs that
            # has never seen overlay.nix, and the module's
            # `default = pkgs.zot` fails with "attribute 'zot' missing" --
            # confusingly pointing at the module rather than at the caller.
            # It is also the cheaper route: one nixpkgs instance, not two, and
            # the very same zot derivation the package output builds.
            zot-module-config = pkgs.callPackage ./tests/module-config.nix {
              nixosSystem =
                modules:
                inputs.nixpkgs.lib.nixosSystem {
                  modules = modules ++ [ { nixpkgs.pkgs = pkgs; } ];
                };
            };
          }
          # zot-referrers exercises the MODULE AT RUNTIME: DynamicUser,
          # LoadCredential-fed htpasswd, systemd hardening, StateDirectory,
          # and that the native Referrers API really answers. Its node is a
          # systemd-nspawn container, so it needs no /dev/kvm -- only a builder
          # advertising `uid-range`.
          #
          # x86_64 ONLY, AND THE GATE DEPENDS ON IT. The derivation requires
          # `nixos-test`, and argunix counts that feature only on a builder
          # whose NATIVE system matches: a builder serving aarch64 through
          # binfmt cannot run an aarch64 container test meaningfully, so it is
          # refused rather than scheduled. With no native aarch64 builder
          # enrolled, exposing this for aarch64 puts the job in
          # SkippedNoBuilder, which counts as interrupted, which turns the
          # whole `argunix: evaluation` status to Error -- permanently red, on
          # the one status branch protection requires.
          #
          # Widen this the day a native aarch64 builder with `uid-range` is
          # enrolled, and not before.
          #
          # The image's own behavioural test lives in the images repository,
          # which is the point of the split: a module regression and an image
          # regression are separately red.
          // lib.optionalAttrs (system == "x86_64-linux") {
            zot-referrers = pkgs.testers.runNixOSTest ./tests/zot-referrers.nix;
          };
      }
    );
}