# The zot binary itself. Kept as a top-level overlay attribute so both the
# image and any NixOS consumer reuse the identical derivation.
{
  lib,
  buildGo127Module,
  fetchFromGitHub,
}:

# zot 2.1.22 verlangt Go >= 1.27, der Default dieses nixpkgs-Zweigs ist 1.26.
# Ein Release-Branch bewegt seinen Default-Go nicht mehr, also wird die
# Toolchain hier explizit benannt statt auf nixpkgs zu warten. Beim naechsten
# Sprung der zot-Anforderung wandert diese Zeile mit.
buildGo127Module rec {
  pname = "zot";

  # The '# renovate:' comment is what the shared preset's regex manager keys
  # on; without it this line is invisible to Renovate. The leading 'v' in
  # upstream tags is stripped by the preset's extractVersionTemplate, and
  # src.rev puts it back.
  #
  # renovate: datasource=github-releases depName=project-zot/zot
  version = "2.1.22";

  src = fetchFromGitHub {
    owner = "project-zot";
    repo = "zot";
    rev = "v${version}";
    hash = "sha256-b6b1wQI1KjiNDZUuo5bQ1oFEov3rdBv99mM7gpjSwmI=";
  };

  vendorHash = "sha256-jfHzB7kRiMfrUQrNHrKuAROQ0OPCf/r97jSp1DwWLEc=";

  subPackages = [ "cmd/zot" ];

  # Minimal build: the core registry as defined by the OCI Distribution
  # Specification, without extensions. The Referrers API is part of that core,
  # so SBOM and signature discovery works here -- the extensions add the web
  # UI, GraphQL search, CVE scanning and friends, none of which this
  # deployment needs.
  #
  # For the full flavour:
  # tags = [ "sync" "search" "scrub" "metrics" "lint" "ui" "mgmt" "imagetrust" "events" ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/project-zot/zot/pkg/api/config.ReleaseTag=v${version}"
  ];

  meta = {
    description = "OCI-native container image registry";
    homepage = "https://zotregistry.dev";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "zot";
  };
}
