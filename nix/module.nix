self: { config, lib, pkgs, ... }:

let
  cfg = config.services.imcui;
in
{
  options.services.imcui = {
    enable = lib.mkEnableOption "Image Matching WebUI";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression
        "image-matching-webui.packages.\${system}.default";
      description = "The imcui package to run.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        Host to bind the Gradio server to. Use "0.0.0.0" for LAN access
        (pair with openFirewall = true).
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 7860;
      description = "TCP port for the Gradio server.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open `port` on the NixOS firewall.";
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./my-app.yaml";
      description = ''
        Path to a custom app.yaml. If null, the package default is used.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--verbose" ];
      description = "Extra arguments appended to the imcui CLI.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/imcui";
      description = ''
        Persistent directory for example datasets and model caches
        (HuggingFace, torch). Created and owned by the service.
      '';
    };

    enableCuda = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Grant the service access to NVIDIA device nodes and allow
        writable /dev so CUDA userland works.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { CUDA_VISIBLE_DEVICES = "0"; };
      description = "Extra environment variables for the service.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.imcui = {
      description = "Image Matching WebUI";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        XDG_CACHE_HOME = "%S/imcui";
        HF_HOME = "%S/imcui/huggingface";
        TORCH_HOME = "%S/imcui/torch";
      } // cfg.environment;

      serviceConfig = {
        ExecStart =
          let
            args =
              [
                "--server-name" cfg.listenAddress
                "--server-port" (toString cfg.port)
                "--example-data-root" "${cfg.stateDir}/datasets"
              ]
              ++ lib.optionals (cfg.configFile != null)
                [ "--config" (toString cfg.configFile) ]
              ++ cfg.extraArgs;
          in
          "${cfg.package}/bin/imcui ${lib.escapeShellArgs args}";

        DynamicUser = true;
        StateDirectory = "imcui";
        # imcui/hloc/__init__.py opens "log.txt" relative to cwd at
        # import time. Point cwd at the state dir so that write lands
        # inside the writable StateDirectory instead of read-only /.
        WorkingDirectory = "%S/imcui";
        Restart = "on-failure";
        RestartSec = 5;

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        LockPersonality = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      } // lib.optionalAttrs cfg.enableCuda {
        PrivateDevices = false;
        DeviceAllow = lib.mkDefault [
          "/dev/nvidia0 rw"
          "/dev/nvidiactl rw"
          "/dev/nvidia-uvm rw"
          "/dev/nvidia-uvm-tools rw"
          "/dev/nvidia-modeset rw"
        ];
      };
    };

    networking.firewall.allowedTCPPorts =
      lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
