{
  description = "image-matching-webui — Gradio app for image-matching algorithms";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, devshell }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        ds = devshell.legacyPackages.${system};
        python = pkgs.python311;

        # Runtime libs the pip wheels (torch, opencv, onnxruntime, pycolmap, …)
        # link against. /run/opengl-driver/lib is where the NVIDIA driver lives
        # on NixOS; torch needs libcuda.so.1 from there at runtime.
        libPath =
          pkgs.lib.makeLibraryPath (with pkgs; [
            stdenv.cc.cc.lib
            zlib
            libGL
            glib
            ffmpeg
            libxcrypt-legacy
          ]) + ":/run/opengl-driver/lib";
      in
      {
        devShells.default = ds.mkShell {
          name = "imcui";

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
            { name = "LD_LIBRARY_PATH"; value = libPath; }
            { name = "UV_PYTHON"; value = "${python}/bin/python"; }
            { name = "UV_PYTHON_DOWNLOADS"; value = "never"; }
            { name = "UV_NO_SYNC"; value = "1"; }
          ];

          commands = [
            {
              name = "venv-init";
              help = "Create .venv and install the project + requirements.txt";
              command = ''
                set -e
                uv venv --python "$UV_PYTHON" --prompt imcui .venv
                uv pip install --python .venv/bin/python -e .
                echo
                echo "Activate with: source .venv/bin/activate"
              '';
            }
            {
              name = "run-app";
              help = "Run the Gradio image matching webui (app.py)";
              command = ''
                set -e
                test -d .venv || { echo "Run venv-init first"; exit 1; }
                exec .venv/bin/python app.py "$@"
              '';
            }
            {
              name = "run-tests";
              help = "Run pytest in the venv";
              command = ''
                set -e
                test -d .venv || { echo "Run venv-init first"; exit 1; }
                exec .venv/bin/python -m pytest "$@"
              '';
            }
          ];
        };
      });
}
