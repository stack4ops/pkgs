# Behavioural integration test: run zot from the NixOS module, push an
# artifact, attach a referrer to it, and assert the referrer is discoverable
# BOTH through oras and through the native Referrers API endpoint.
#
# The second assertion is the one that carries weight. `oras discover` also
# succeeds against an OCI 1.0 registry, because oras falls back to the
# Referrers Tag Schema when the endpoint 404s. Only the direct call to
# /v2/<name>/referrers/<digest> distinguishes a genuine OCI 1.1 implementation
# from that fallback — and knowing which one is in front of you is the entire
# reason this registry exists (ADR-006).
#
# Also pins the module's access-control defaults: anonymous pull, authenticated
# push. That policy is easy to break silently while editing storage settings.
#
# Scope: the MODULE, not the published image. The image has its own
# behavioural test in the images repository, so a regression in one does not
# turn the other red.
#
# ---------------------------------------------------------------------------
# The node is a CONTAINER, not a VM
# ---------------------------------------------------------------------------
#
# `containers.<name>` runs the node as a systemd-nspawn container inside the
# Nix build rather than booting a virtual machine. It therefore needs no
# /dev/kvm, which is what kept this test commented out: it now runs on any
# builder that offers `uid-range`, including natively on aarch64 — where a VM
# test cannot go, because an x86_64 builder running aarch64 under binfmt
# cannot accelerate an aarch64 guest.
#
# The builder needs:
#   auto-allocate-uids = true;
#   extra-experimental-features = [ "auto-allocate-uids" "cgroups" ];
#   extra-system-features = [ "uid-range" ];
#
# `uid-range` is what gives the build root inside a user namespace with 65536
# UIDs, which is what nspawn needs. The driver adds `nixos-test` and
# `uid-range` to the derivation's requiredSystemFeatures itself; nothing here
# declares them.
#
# No `requiredFeatures.devnet`: that is only needed when a test mixes VM and
# container nodes and they have to reach each other. There is one container
# here and no VM.
#
# What changes by not being a VM:
#
#   - The node shares the host kernel. Nothing here depends on a custom one.
#   - There is no setuid. The Nix sandbox does not permit it, so NixOS's
#     suid-sgid-wrappers service cannot create /run/wrappers and fails. A
#     module that genuinely needs a wrapper belongs in a VM test.
#   - The build filesystem has no ACLs, which is what resolvconf trips over.
#     Both services are therefore disabled explicitly on the node below,
#     rather than being left to fail in the journal.
#   - systemd hardening is not identical. Directives such as ProtectSystem can
#     be skipped when the container lacks the privileges to apply them, and
#     systemd logs when that happens. This test asserts none of them — the
#     generated unit is checked in tests/module-config.nix, which is the right
#     place for it — so the loss is smaller than it looks. But do not add a
#     hardening assertion here and read it as equivalent to a VM's.
#   - Hardlinks, and therefore zot's dedupe, depend on the filesystem the
#     container's state lands on rather than on a VM's own ext4. The last
#     subtest is the one to watch on a new builder; see the note there.
#
# ---------------------------------------------------------------------------
# Which driver
# ---------------------------------------------------------------------------
#
# This is nixpkgs' own test driver. `containers` is documented at
# https://applicative.systems/nixos-test-driver-manual/features/container/,
# which is a manual for the nixpkgs driver rather than for a separate project
# — there is no extra flake input to add. If evaluation rejects the
# `containers` attribute, the pinned nixpkgs predates the feature and the fix
# is a newer nixpkgs, not another input.
{ pkgs, ... }:
let
  pushUser = "argunix";
  pushPassword = "testsecret";

  # Generated at build time rather than checked in: a bcrypt hash with a fixed
  # salt would be a credential-shaped constant in the repo, and there is no
  # reason to have one.
  htpasswd = pkgs.runCommand "zot-test-htpasswd" { nativeBuildInputs = [ pkgs.apacheHttpd ]; } ''
    htpasswd -Bbc "$out" ${pushUser} ${pushPassword}
  '';
in
{
  name = "zot-referrers";

  globalTimeout = 5 * 60;

  # Declared rather than left to default: `devnet` sets up a VDE bridge so that
  # VM and container nodes can reach each other, and it costs `/dev/net` in the
  # builder's extra-sandbox-paths, which the manual notes may weaken sandbox
  # security. There is one container here, no VM, and everything the test does
  # goes to 127.0.0.1 inside it. Without this the driver attempts the bridge
  # anyway and warns that the TAP device is missing.
  requiredFeatures.devnet = false;

  containers.machine =
    { lib, ... }:
    {
      imports = [ ../modules/zot.nix ];

      # Neither of these can work in the Nix sandbox, and both fail loudly on
      # every run if left enabled: suid-sgid-wrappers cannot chmod a setuid
      # bit, and resolvconf cannot set an ACL on /run/resolvconf. Turning them
      # off states the constraint instead of printing it.
      #
      # The cost is the signal: a module added here later that actually needs
      # a wrapper will no longer fail loudly, it will quietly find a missing
      # binary. That is what this comment is for — if you hit that, the module
      # needs a VM node, not a workaround.
      security.wrappers = lib.mkForce { };
      networking.resolvconf.enable = false;

      services.zot = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 5000;
        htpasswdFile = htpasswd;
        pushUsers = [ pushUser ];
      };

      environment.systemPackages = [
        pkgs.oras
        pkgs.jq
        pkgs.curl
      ];

      # Kept from the VM version: nothing here talks to the outside, and a
      # DHCP client racing the test is a source of flakes either way.
      networking.dhcpcd.enable = false;
    };

  testScript = ''
    machine.wait_for_unit("zot.service")
    machine.wait_for_open_port(5000)

    with subtest("the registry answers the OCI base endpoint"):
        machine.succeed("curl -fsS http://127.0.0.1:5000/v2/ -o /dev/null")

    with subtest("anonymous push is rejected"):
        machine.succeed("echo hello > /tmp/payload.txt")
        machine.fail(
            "cd /tmp && oras push --plain-http "
            "127.0.0.1:5000/test:v1 payload.txt"
        )

    with subtest("authenticated push succeeds"):
        machine.succeed(
            "cd /tmp && oras push --plain-http "
            "-u ${pushUser} -p ${pushPassword} "
            "127.0.0.1:5000/test:v1 payload.txt"
        )

    with subtest("anonymous pull is allowed"):
        machine.succeed(
            "cd /tmp && oras manifest fetch --plain-http "
            "127.0.0.1:5000/test:v1 -o /dev/null"
        )

    with subtest("attach a referrer to the pushed manifest"):
        machine.succeed("echo '{\"sbom\":true}' > /tmp/sbom.json")
        machine.succeed(
            "cd /tmp && oras attach --plain-http "
            "-u ${pushUser} -p ${pushPassword} "
            "--artifact-type application/vnd.test.sbom "
            "127.0.0.1:5000/test:v1 sbom.json"
        )

    with subtest("oras discovers the referrer"):
        out = machine.succeed(
            "oras discover --plain-http 127.0.0.1:5000/test:v1"
        )
        assert "vnd.test.sbom" in out, f"referrer not discoverable: {out!r}"

    with subtest("the native Referrers API serves it"):
        # An OCI 1.0 registry would 404 here and still have passed the
        # subtest above, via the Referrers Tag Schema fallback.
        digest = machine.succeed(
            "oras manifest fetch --plain-http --descriptor "
            "127.0.0.1:5000/test:v1 | jq -r .digest"
        ).strip()
        refs = machine.succeed(
            f"curl -fsS http://127.0.0.1:5000/v2/test/referrers/{digest}"
        )
        assert "vnd.test.sbom" in refs, (
            f"native referrers API did not return the referrer: {refs!r}"
        )

    with subtest("storage lives where the module says it does"):
        machine.succeed("test -d /var/lib/zot/test")

    with subtest("dedupe is not silently disabled"):
        # Hardlink-backed dedupe is one reason zot is affordable on a
        # disk-constrained host; a filesystem without it disables the feature
        # silently, with only a warning at startup.
        #
        # In a VM this ran on the guest's own ext4. In a container the state
        # directory lands on whatever the builder's filesystem offers, so this
        # is the assertion most likely to come out differently on a new
        # builder. A failure here is informative rather than a sign the test
        # is wrong: it says dedupe would not work on a host like that one.
        #
        # Known weakness, true of the VM version as well: zot runs its dedupe
        # pass at startup, before this test has pushed anything, and logs
        # "no repositories found in storage, finished." So this asserts that
        # zot did not refuse dedupe up front -- not that hardlinks actually
        # work. Making it mean the stronger thing needs the same blob pushed
        # under two tags and a look at the link count under /var/lib/zot.
        machine.fail("journalctl -u zot.service | grep -q 'disabling dedupe'")
  '';
}
