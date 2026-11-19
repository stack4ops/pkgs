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
      # ONE SYSTEM, ON PURPOSE. aarch64 used to be in here, served by binfmt
      # emulation, and it cost an hour per build: `go test` compiles a test
      # binary before running it, and compiling under qemu-user is where the
      # time goes. zot is pure Go, so the right tool is cross-compilation --
      # see `zot-aarch64` below, which produces the same artefact at native
      # speed on this one system.
      #
      # Adding a system here means a builder of that architecture, or
      # emulation. Neither is needed for a Go binary.
      #
      # Two gates have to agree before any of this reaches CI: this list, and
      # `services.argunix.systems` on the coordinator. argunix only walks the
      # systems named there, so an entry here alone stays invisible.
      systems = [
        "x86_64-linux"
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
      #
      # That holds for the cross case too. A consumer wanting an aarch64 zot
      # applies this overlay to its own instance and reaches for
      # `pkgsCross.aarch64-multiplatform.zot` -- overlays propagate into
      # `pkgsCross`, so nothing extra is exported for it. `zot-aarch64` below
      # exists to prove that path still compiles, not to be consumed.
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
        packages = {
          zot = pkgs.zot;
          default = pkgs.zot;

          # The aarch64 binary, cross-compiled on this x86_64 system rather
          # than built under emulation.
          #
          # Go's compiler targets any architecture from any host, so this
          # costs roughly what the native build costs. Emulating it instead
          # cost an hour, almost all of it compiling -- the test binary
          # included, since `go test` has to build one before it can run it.
          #
          # Cross also settles the test question by itself: nixpkgs does not
          # run a check phase for a cross build, because the resulting test
          # binary cannot execute on the build machine. Nothing has to be
          # overridden to get that, which is why the doCheck plumbing this
          # file used to carry is gone.
          #
          # Cross works here because zot is pure Go: no cgo, no C
          # dependency, nothing that would need a cross C toolchain. Should a
          # future zot pull in cgo, this attribute is where it breaks, and it
          # breaks on a native builder with a readable error rather than
          # somewhere inside qemu.
          #
          # NOT WHAT THE IMAGES REPOSITORY CONSUMES. It applies the overlay to
          # its own nixpkgs and takes `pkgsCross.aarch64-multiplatform.zot`
          # from there, for the closure reason given at `overlays.default`.
          # This attribute is the canary: it fails here, in the repository that
          # owns the package, instead of one step downstream.
          zot-aarch64 = pkgs.pkgsCross.aarch64-multiplatform.zot;
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

        checks = {
          # Assertions on what the module GENERATES: the zot config file and
          # the systemd unit, both read straight out of the evaluation. It
          # asserts on the things that break silently -- the port as a string
          # rather than a number, the credentials path rather than a %d
          # specifier, deleteReferrers, anonymous pull, DynamicUser,
          # StateDirectory, ProtectSystem.
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
          # There is no aarch64 counterpart and there cannot be a useful one
          # until a native aarch64 builder exists: the derivation requires
          # `nixos-test`, and argunix counts that feature only on a builder
          # whose native system matches. A container test is the one thing
          # cross-compilation cannot stand in for -- it has to execute, not
          # just compile.
          #
          # The image's own behavioural test lives in the images repository,
          # which is the point of the split: a module regression and an image
          # regression are separately red.
          zot-referrers = pkgs.testers.runNixOSTest ./tests/zot-referrers.nix;
        };
      }
    );
}
