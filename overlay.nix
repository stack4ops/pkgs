# Package overlay for this repository.
#
# Deliberately flat and free of any `prev.<set> or { }` composition: these are
# top-level package attributes, so the ordinary nixpkgs rule applies -- last
# overlay wins for a given name, and nothing needs merging.
#
# Image attributes are NOT defined here. They live in the images repository,
# whose overlay composes `ociImages` on top of whatever this one provides.
final: prev: {
  # Kept as a top-level attribute rather than scoped, because that is what the
  # NixOS module's `package` option defaults to (`pkgs.zot`) and what the
  # images repository builds its image from.
  zot = final.callPackage ./pkgs/zot.nix { };
}
