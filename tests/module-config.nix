# Assertions on what the module GENERATES, as opposed to how it behaves once
# running.
#
# No VM and therefore no /dev/kvm, so this runs on any builder -- which is the
# point: tests/zot-referrers.nix cannot run on the dev instance yet, and most
# of what breaks in a NixOS module breaks at evaluation, not at runtime. The
# generated config file and the unit are both pure evaluation results, so they
# can be read without booting anything.
#
# What this cannot tell you: whether zot accepts the config it is handed, and
# whether the referrers endpoint answers. That is zot-referrers' job.
#
# The config file is reached through the unit's ExecStart rather than being
# exported by the module: `serve ${configFile}` carries the store path, and
# putting that string in the builder's environment makes the file a dependency
# of this derivation.
{
  lib,
  runCommand,
  jq,
  nixosSystem,
}:

let
  # Just enough for a NixOS evaluation to complete. Nothing here is built --
  # only `config` is read -- so no bootloader or real filesystem is needed.
  base = {
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
    };
    documentation.enable = false;
  };

  evalWith =
    extra:
    (nixosSystem [
      ../modules/zot.nix
      base
      extra
    ]).config;

  good = evalWith {
    services.zot = {
      enable = true;
      htpasswdFile = "/run/secrets/zot-htpasswd";
      pushUsers = [ "argunix" ];
    };
  };

  svc = good.systemd.services.zot.serviceConfig;

  # Filtered to this module's own assertions. A stripped-down NixOS evaluation
  # trips assertions of its own (bootloader, filesystems), and counting those
  # would make this check pass or fail for reasons that have nothing to do with
  # services.zot.
  zotAssertionFailures =
    extra:
    map (a: a.message) (
      lib.filter (
        a: !a.assertion && lib.hasInfix "services.zot" a.message
      ) (evalWith extra).assertions
    );

  pushUsersMissing = zotAssertionFailures {
    services.zot = {
      enable = true;
      htpasswdFile = "/run/secrets/zot-htpasswd";
    };
  };

  openWithoutAuth = zotAssertionFailures {
    services.zot = {
      enable = true;
      listenAddress = "0.0.0.0";
    };
  };
in

runCommand "zot-module-config"
  {
    nativeBuildInputs = [ jq ];

    execStart = svc.ExecStart;
    loadCredential = lib.concatStringsSep " " (svc.LoadCredential or [ ]);
    dynamicUser = lib.boolToString (svc.DynamicUser or false);
    stateDirectory = svc.StateDirectory or "";
    protectSystem = toString (svc.ProtectSystem or "");

    pushUsersMissingCount = toString (lib.length pushUsersMissing);
    openWithoutAuthCount = toString (lib.length openWithoutAuth);
  }
  ''
    fail=0
    note() {
      echo "FAIL: $1" >&2
      fail=1
    }

    # ExecStart is "<zot> serve <config>", so the config is its last field.
    configPath=''${execStart##* }
    case "$configPath" in
      /nix/store/*.json) ;;
      *) echo "FAIL: ExecStart does not end in a generated config: $execStart" >&2; exit 1 ;;
    esac
    test -f "$configPath" || { echo "FAIL: $configPath is not a file" >&2; exit 1; }

    # --- the generated zot configuration ------------------------------------

    # zot wants the port as a STRING. A number here is accepted by the NixOS
    # option (it is typed `port`) and rejected by zot at startup with an
    # unhelpful message, which makes this the single most valuable assertion
    # in the file.
    jq -e '.http.port == "5000"' "$configPath" >/dev/null \
      || note "http.port is not the string \"5000\""

    # systemd exposes LoadCredential at this fixed path. "%d/..." would be a
    # unit specifier, which zot never expands -- it would look for a directory
    # literally named %d.
    jq -e '.http.auth.htpasswd.path == "/run/credentials/zot.service/htpasswd"' "$configPath" >/dev/null \
      || note "htpasswd path is not the systemd credentials path"

    jq -e '.distSpecVersion == "1.1.1"' "$configPath" >/dev/null \
      || note "distSpecVersion changed"

    jq -e '.storage.rootDirectory == "/var/lib/zot"' "$configPath" >/dev/null \
      || note "storage.rootDirectory does not match the StateDirectory"

    jq -e '.storage.gc == true and .storage.dedupe == true' "$configPath" >/dev/null \
      || note "gc or dedupe is off; both matter where disk is the binding constraint"

    # Referrers are how SBOMs and signatures attach to a manifest. Deleting
    # them would discard exactly the artefacts this registry exists to serve.
    jq -e '.storage.retention.policies[0].deleteReferrers == false' "$configPath" >/dev/null \
      || note "retention would delete referrers"

    jq -e '.http.accessControl.repositories["**"].anonymousPolicy == ["read"]' "$configPath" >/dev/null \
      || note "anonymous pull is no longer allowed"

    # --- the generated unit -------------------------------------------------

    [ "$dynamicUser" = "true" ] || note "DynamicUser is $dynamicUser"
    [ "$stateDirectory" = "zot" ] || note "StateDirectory is '$stateDirectory'"
    [ "$protectSystem" = "strict" ] || note "ProtectSystem is '$protectSystem'"

    case "$loadCredential" in
      htpasswd:*) ;;
      *) note "LoadCredential is '$loadCredential', expected htpasswd:<path>" ;;
    esac

    # --- the module's own assertions ----------------------------------------

    [ "$pushUsersMissingCount" = "1" ] \
      || note "htpasswdFile without pushUsers raised $pushUsersMissingCount assertions, expected 1"

    [ "$openWithoutAuthCount" = "1" ] \
      || note "listening on 0.0.0.0 without auth raised $openWithoutAuthCount assertions, expected 1"

    # ------------------------------------------------------------------------

    if [ "$fail" -ne 0 ]; then
      echo "" >&2
      echo "generated configuration was:" >&2
      jq . "$configPath" >&2
      exit 1
    fi

    echo "generated config and unit match what the module promises"
    touch "$out"
  ''
