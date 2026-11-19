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
      # Two gates have to agree before any of this reaches CI: this list, and
      # `services.argunix.systems` on the coordinator. argunix only walks the
      # systems named there, so an entry here alone stays invisible.
      #
      # "aarch64-darwin"
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # Which of the systems above are served by binfmt emulation rather than
      # by a builder of that architecture.
      #
      # ONE LIST, AND EVERYTHING BELOW HANGS OFF IT. An emulated system gets
      # the binary and nothing else: no devShell, no checks, and the binary
      # built without its upstream test suite. Each of those has its own
      # reason, given at the point where it happens.
      #
      # The day an aarch64 builder is enrolled, empty this list. Every
      # consequence follows from that one edit.
      emulatedSystems = [ "aarch64-linux" ];

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
      #
      # Deliberately unaffected by the doCheck decision below: that is a
      # property of how THIS repository spends its CI time, not of the
      # package. A consumer gets the package with its tests.
      overlays.default = import ./overlay.nix;

      # The module defaults `services.zot.package` to `pkgs.zot`, so a
      # consumer that applies the overlay above needs no further wiring.
      nixosModules.zot = ./modules/zot.nix;
      nixosModules.default = inputs.self.nixosModules.zot;
    }
    // eachSystem systems (
      system:
      let
        native = !lib.elem system emulatedSystems;

        pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [
            inputs.self.overlays.default
          ]
          # Skipping zot's own test suite where the architecture is emulated.
          #
          # `go test` has no separate runner: it compiles a test binary per
          # package and then runs it. Natively that is 83 seconds of
          # compilation for a 28 ms test -- and only for `cmd/zot`, because
          # `subPackages` limits the test phase as well as the build, so none
          # of pkg/api, pkg/storage or pkg/meta runs at all. Under qemu-user
          # the same thing costs roughly an hour and measures the emulator
          # more than the code.
          #
          # It stays ON natively: 83 seconds is not a bottleneck, and it is a
          # free canary for a vendorHash that resolved to subtly different
          # dependencies. Note that the thin coverage comes from
          # `subPackages`, not from here -- relax that line and the native run
          # picks the wider suite up by itself.
          #
          # THIS BELONGS IN THE pkgs INSTANCE, not in `packages`. Several
          # outputs reach for `pkgs.zot`, and overriding only the `packages`
          # attribute would leave the slow derivation reachable through the
          # others -- the same hour under a different attribute name.
          ++ lib.optional (!native) (
            _: prev: {
              zot = prev.zot.overrideAttrs (_: { doCheck = false; });
            }
          );
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
        # This is the ONLY output an emulated system gets. It compiles under
        # qemu-user and takes an order of magnitude longer than the native
        # one, with its test suite skipped per the overlay note above.
        packages = {
          zot = pkgs.zot;
          default = pkgs.zot;
        };

        # Exposed for every system because it costs nothing: a wrapper around
        # the binary that `packages` already builds, and argunix does not walk
        # `apps` at all.
        apps.default = {
          type = "app";
          program = lib.getExe pkgs.zot;
          meta.description = "Run the zot registry";
        };
      }
      //
        # Everything past this point is native-only, and for two different
        # reasons rather than one blanket rule.
        lib.optionalAttrs native {
          # Nobody enters a devShell for an architecture they do not work on.
          # argunix does walk `devShells`, so exposing it for an emulated
          # system means building its closure for no reader.
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

          checks = {
            # Assertions on what the module GENERATES: the zot config file and
            # the systemd unit, both read straight out of the evaluation. It
            # asserts on the things that break silently -- the port as a
            # string rather than a number, the credentials path rather than a
            # %d specifier, deleteReferrers, anonymous pull, DynamicUser,
            # StateDirectory, ProtectSystem.
            #
            # Native only, because every one of those is architecture
            # independent: the generated config and unit differ between
            # systems in store paths and nothing else. Running it twice
            # restates the same answer at the price of a second evaluation.
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

            # zot-referrers exercises the MODULE AT RUNTIME: DynamicUser,
            # LoadCredential-fed htpasswd, systemd hardening, StateDirectory,
            # and that the native Referrers API really answers. Its node is a
            # systemd-nspawn container, so it needs no /dev/kvm -- only a
            # builder advertising `uid-range`.
            #
            # Native only, and THE MERGE GATE DEPENDS ON IT. The derivation
            # requires `nixos-test`, and argunix counts that feature only on a
            # builder whose NATIVE system matches: a builder serving aarch64
            # through binfmt cannot run an aarch64 container test
            # meaningfully, so it is refused rather than scheduled. Exposed
            # anyway, the job lands in SkippedNoBuilder, which counts as
            # interrupted, which turns the whole `argunix: evaluation` status
            # to Error -- permanently red, on the one status branch protection
            # requires.
            #
            # The image's own behavioural test lives in the images repository,
            # which is the point of the split: a module regression and an
            # image regression are separately red.
            zot-referrers = pkgs.testers.runNixOSTest ./tests/zot-referrers.nix;
          };
        }
    );
}