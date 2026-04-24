# NixOS module for imcui service

## Goal

Run `imcui` as a systemd service on nyanza (and any other NixOS host)
via a module exported from this flake.

## Shape

- Add `nix/module.nix` in this repo (small, single file).
- Export as `nixosModules.default` from `flake.nix`.
- Consume from `~/nix-config` by adding this flake as an input and
  importing the module; machine config sets
  `services.imcui.enable = true;`.

Pattern for wiring the flake's package as the module default:

```nix
# flake.nix — inside outputs
nixosModules.default = import ./nix/module.nix self;
```

```nix
# nix/module.nix
self: { config, lib, pkgs, ... }: let
  cfg = config.services.imcui;
in {
  options.services.imcui = { ... };
  config = lib.mkIf cfg.enable { ... };
}
```

This keeps the module buildable across any system uv2nix supports —
consumers don't have to re-wire the package.

## Options

| option | type | default | purpose |
|---|---|---|---|
| `enable` | bool | `false` | turn the service on |
| `package` | package | flake's `packages.default` | override build |
| `listenAddress` | str | `"127.0.0.1"` | bind host |
| `port` | int | `7860` | bind port |
| `openFirewall` | bool | `false` | open `port` on the NixOS firewall |
| `configFile` | null \| path | `null` | if set, passed via `--config` |
| `extraArgs` | list str | `[]` | additional CLI flags |
| `stateDir` | str | `"/var/lib/imcui"` | persistent cache/datasets root |
| `enableCuda` | bool | `true` | grant `/dev/nvidia*` access and set CUDA env |
| `environment` | attrs of str | `{}` | extra env injected into the unit |

Deliberate omissions:
- No reverse-proxy / TLS options. Consumers add nginx/caddy if needed.
- No user/group options. Use `DynamicUser=true` + `StateDirectory`
  (cleaner; no uid management; state survives restart).

## systemd unit

```nix
systemd.services.imcui = {
  description = "Image Matching WebUI";
  wantedBy = [ "multi-user.target" ];
  after = [ "network-online.target" ];
  wants = [ "network-online.target" ];

  environment = {
    XDG_CACHE_HOME = "%S/imcui";       # → /var/lib/imcui/
    HF_HOME = "%S/imcui/huggingface";
    TORCH_HOME = "%S/imcui/torch";
  } // cfg.environment;

  serviceConfig = {
    ExecStart = let
      args = [
        "--server-name" cfg.listenAddress
        "--server-port" (toString cfg.port)
        "--example-data-root" "${cfg.stateDir}/datasets"
      ] ++ lib.optionals (cfg.configFile != null)
             [ "--config" cfg.configFile ]
        ++ cfg.extraArgs;
    in "${cfg.package}/bin/imcui ${lib.escapeShellArgs args}";

    DynamicUser = true;
    StateDirectory = "imcui";
    Restart = "on-failure";
    RestartSec = 5;

    # Hardening — conservative; torch JIT can trip aggressive sandboxing.
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    LockPersonality = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    # Leave MemoryDenyWriteExecute unset — torch AOT/inductor may need it.
  };
};

# GPU device access (only when cfg.enableCuda)
systemd.services.imcui.serviceConfig.DeviceAllow = lib.mkIf cfg.enableCuda [
  "/dev/nvidia0 rw"
  "/dev/nvidiactl rw"
  "/dev/nvidia-uvm rw"
  "/dev/nvidia-uvm-tools rw"
  "/dev/nvidia-modeset rw"
];
systemd.services.imcui.serviceConfig.PrivateDevices = lib.mkIf cfg.enableCuda false;

networking.firewall.allowedTCPPorts =
  lib.mkIf cfg.openFirewall [ cfg.port ];
```

## Open questions / things to verify

1. **NVIDIA device allow-list vs. driver userland**
   `DeviceAllow` lets the cgroup see the nodes, but CUDA also needs
   `libcuda.so.1` from the driver userland (the flake already prepends
   `/run/opengl-driver/lib` to `LD_LIBRARY_PATH` in the wrapper). The
   wrapper carries this through; the service should inherit it via the
   wrapper's shebang. Worth verifying with one test run that
   `nvidia-smi` inside the unit works.

2. **State dir size**
   HF model weights for the matcher_zoo can easily run 10s of GB if
   every matcher is exercised. `/var/lib/imcui/` is fine as long as
   nyanza has room; otherwise `stateDir` is the escape hatch.

3. **First-run dataset download**
   On first click, hloc downloads the example dataset (`sacre_coeur`
   etc.) from HF into `--example-data-root`. Needs network at runtime;
   `after=network-online.target` is enough.

4. **Multiple workers / GPU contention**
   One service instance is fine for personal use. If we later want
   queueing/multi-GPU, that's a follow-up.

5. **Config override flow**
   `configFile` lets a consumer drop in an `app.yaml` with fewer
   matchers enabled (e.g. only the ones whose submodule deps we've
   verified). Start with `null` → package-default 65-matcher list,
   expect some to fail at load time until step-5 dep work is done.

## Plan of execution

1. Write `nix/module.nix` per the shape above.
2. Wire `nixosModules.default` in `flake.nix`.
3. Commit on this branch.
4. Separately in `~/nix-config`: add this flake as an input on nyanza's
   machine config, enable the service, `bb switch`.
5. Test: `systemctl status imcui`, `curl http://127.0.0.1:7860`,
   click a preset → verify GPU is used (`nvidia-smi` shows python
   process).

Step 4 changes live in a different repo; I'll flag what goes where
when I get there.

## Non-goals for this pass

- Public-facing TLS / reverse proxy.
- Pinning a subset of matchers via `configFile` (can layer on later).
- Multi-user / auth. Gradio share links are off by default; LAN-only
  with `listenAddress = "0.0.0.0"` + `openFirewall = true` is the
  likely first setup.
