with import <nixpkgs> {};

let
  unstable = import
    (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/55fcb63b2c3c245f5f9d1aafa68671c4d6304881.tar.gz")
    # reuse the current configuration
    { config = config; };
in
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    unstable.zls
    unstable.zig_0_13
    gdb
    valgrind
    # For linter script on push hook
    python3
    wabt
    cmake
    clang-tools
    nodePackages.typescript-language-server
    vscode-langservers-extracted
    nodePackages.prettier
    nodePackages.jshint
    rustup
    binaryen
    openssl
    curl
    sqlite
    sqlitebrowser
    pyright
    black
    rustPlatform.bindgenHook
    blender
  ];
}

