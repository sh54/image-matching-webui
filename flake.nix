{
  description = "image-matching-webui — Gradio app for image-matching algorithms";

  # Fetch git submodules when this flake is built from its own source.
  # imcui/third_party/* submodules ship matcher/extractor Python packages
  # that imcui adds to sys.path at runtime; without this the nix build
  # copies empty submodule dirs. Needs nix ≥ 2.27.
  inputs.self.submodules = true;

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix_hammer_overrides = {
      url = "github:TyberiusPrime/uv2nix_hammer_overrides";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    , devshell
    , pyproject-nix
    , uv2nix
    , pyproject-build-systems
    , uv2nix_hammer_overrides
    }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        ds = devshell.legacyPackages.${system};
        lib = pkgs.lib;
        python = pkgs.python311;

        workspace = uv2nix.lib.workspace.loadWorkspace {
          workspaceRoot = ./.;
        };

        overlay = workspace.mkPyprojectOverlay {
          sourcePreference = "wheel";
        };

        hammerOverrides = uv2nix_hammer_overrides.overrides_strict pkgs;

        # Thin overlay on top of hammer. Hammer handles torch's postFixup
        # (symlinks nvidia .so into $out/lib) and the common nvidia-*
        # fixups; we add what's missing for torch 2.8 cu128.
        # Pattern lifted from ~/src/phind/models/cuda-test/package.nix.
        projectOverrides = final: prev: lib.optionalAttrs pkgs.stdenv.isLinux {
          torch = prev.torch.overrideAttrs (old: {
            buildInputs = (old.buildInputs or [ ]) ++ [
              pkgs.cudaPackages.libcusparse_lt
              pkgs.cudaPackages.libcufile
            ];
            autoPatchelfIgnoreMissingDeps =
              (old.autoPatchelfIgnoreMissingDeps or [ ]) ++ [ "libcuda.so.1" ];
          });
          nvidia-cufile-cu12 = prev.nvidia-cufile-cu12.overrideAttrs (old: {
            buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.rdma-core ];
          });
        };

        pythonSet =
          (pkgs.callPackage pyproject-nix.build.packages {
            inherit python;
          }).overrideScope (lib.composeManyExtensions [
            pyproject-build-systems.overlays.default
            overlay
            (lib.composeExtensions hammerOverrides projectOverrides)
          ]);

        env = pythonSet.mkVirtualEnv "imcui-env" workspace.deps.default;

        # Runtime lib path so pip-wheels' dlopen calls resolve.
        # /run/opengl-driver/lib supplies libcuda.so.1 on NixOS.
        runtimeLibs = [
          pkgs.stdenv.cc.cc.lib
          pkgs.zlib
          pkgs.libGL
          pkgs.glib
          pkgs.ffmpeg
          pkgs.libxcrypt-legacy
        ];
        runtimeLibPath =
          lib.makeLibraryPath runtimeLibs + ":/run/opengl-driver/lib";

        # Wrap the virtualenv so $out/bin exposes only the imcui binary.
        # The wrapper:
        #   - sets LD_LIBRARY_PATH for CUDA + C libs that the wheels dlopen
        #   - defaults --example-data-root to a writable user cache dir
        #     (the bundled datasets/ ships in the read-only nix store and
        #     the app writes into it on first run)
        imcui-app = pkgs.runCommand "imcui"
          {
            meta = {
              description = "Image Matching WebUI CLI";
              mainProgram = "imcui";
            };
          } ''
          mkdir -p $out/bin
          cat > $out/bin/imcui <<'EOF'
          #!${pkgs.runtimeShell}
          export LD_LIBRARY_PATH="@RUNTIME_LIB_PATH@''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          : "''${XDG_CACHE_HOME:=$HOME/.cache}"
          cache_dir="$XDG_CACHE_HOME/imcui/datasets"
          mkdir -p "$cache_dir"
          if [[ "$*" == *--example-data-root* || "$*" == *" -d "* ]]; then
            exec @IMCUI@ "$@"
          else
            exec @IMCUI@ --example-data-root "$cache_dir" "$@"
          fi
          EOF
          substituteInPlace $out/bin/imcui \
            --replace-fail '@RUNTIME_LIB_PATH@' '${runtimeLibPath}' \
            --replace-fail '@IMCUI@' '${env}/bin/imcui'
          chmod +x $out/bin/imcui
        '';

        # Impure devshell (phase a) — has uv for iteration on pyproject.toml.
        impureShell = ds.mkShell {
          name = "imcui-impure";
          packages = with pkgs; [
            python
            uv
            git-lfs
            pkg-config
            cmake
            colmap
            ffmpeg
          ];
          env = [
            { name = "LD_LIBRARY_PATH"; value = runtimeLibPath; }
            { name = "UV_PYTHON"; value = "${python}/bin/python"; }
            { name = "UV_PYTHON_DOWNLOADS"; value = "never"; }
            { name = "UV_NO_SYNC"; value = "1"; }
          ];
          commands = [
            {
              name = "venv-init";
              help = "Create .venv and install the project + deps from uv.lock";
              command = ''
                set -e
                uv venv --python "$UV_PYTHON" --prompt imcui .venv
                uv pip install --python .venv/bin/python -e .
              '';
            }
            {
              name = "run-app";
              help = "Run app.py from the impure .venv";
              command = ''
                set -e
                test -d .venv || { echo "Run venv-init first"; exit 1; }
                exec .venv/bin/python app.py "$@"
              '';
            }
          ];
        };

        # Pure devshell backed by the uv2nix-built env.
        pureShell = ds.mkShell {
          name = "imcui";
          packages = [ env pkgs.git-lfs pkgs.ffmpeg pkgs.colmap ];
          env = [
            { name = "LD_LIBRARY_PATH"; value = runtimeLibPath; }
            { name = "PYTHONDONTWRITEBYTECODE"; value = "1"; }
          ];
          commands = [
            {
              name = "run-app";
              help = "Run app.py using the pure Nix-built env";
              command = ''exec ${env}/bin/python app.py "$@"'';
            }
            {
              name = "run-imcui";
              help = "Run the imcui CLI";
              command = ''exec ${imcui-app}/bin/imcui "$@"'';
            }
          ];
        };
      in
      {
        packages = {
          default = imcui-app;
          imcui = imcui-app;
          env = env;
        };

        apps.default = {
          type = "app";
          program = "${imcui-app}/bin/imcui";
        };

        devShells = {
          default = pureShell;
          impure = impureShell;
        };
      });
}
