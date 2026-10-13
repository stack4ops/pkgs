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
      # Unlike the images repository, this one has no structural reason to be
      # Linux-only: nothing here goes through dockerTools, and zot's meta
      # declares darwin platforms. The list is short because that is what gets
      # built and tested, not because more is impossible. Uncomment when there
      # is a builder for it -- argunix only walks the systems in
      # `services.argunix.systems`, so an entry here stays invisible to CI
      # until that option lists it too.
      # "aarch64-linux"
      # "aarch64-darwin"
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
            # Updating the package: nix-prefetch-github for src.hash,
            # go for inspecting the module graph behind vendorHash.
            pkgs.nix-prefetch-github
            pkgs.go
          ];
        };
      }
      // lib.optionalAttrs (system == "x86_64-linux") {
        # zot-referrers exercises the NixOS MODULE: DynamicUser,
        # LoadCredential-fed htpasswd, systemd hardening, StateDirectory,
        # and the anonymous-pull/authenticated-push access policy.
        #
        # Needs KVM: runNixOSTest is VM-based. A shared-vCPU cloud instance
        # may not expose /dev/kvm at all, and an argunix builder that cannot
        # verify it no longer advertises the feature, so this check will sit
        # unscheduled rather than fail fast. Uncomment once a builder with
        # /dev/kvm is enrolled.
        #
        # The image's own behavioural test lives in the images repository,
        # which is the point of the split: a module regression and an image
        # regression are now separately red.
        checks.zot-referrers = pkgs.testers.runNixOSTest ./tests/zot-referrers.nix;
      }
    );
}
