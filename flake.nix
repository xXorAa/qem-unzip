{
  inputs = {
    fenix.url = "github:nix-community/fenix";
    fenix.inputs.nixpkgs.follows = "nixpkgs";
    naersk.url = "github:nix-community/naersk/master";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.11";
  };

  outputs = { self, nixpkgs, naersk, fenix }: let

      newBuildTarget = {
        nixPkgsSystem,
        rustTarget ? nixPkgsSystem,
        nativeBuildInputs ? pkgsCross: [],
        rustFlags ? pkgsCross: [],
      }: {
        inherit nixPkgsSystem rustTarget nativeBuildInputs rustFlags;
      };

      buildTargets = {
        "x86_64-linux" = newBuildTarget {
          nixPkgsSystem = "x86_64-unknown-linux-musl";
        };

        "i686-linux" = newBuildTarget {
          nixPkgsSystem = "i686-unknown-linux-musl";
        };

        "aarch64-linux" = newBuildTarget {
          nixPkgsSystem = "aarch64-unknown-linux-musl";
        };

        # Old Raspberry Pi's
        "armv6l-linux" = newBuildTarget {
          nixPkgsSystem = "armv6l-unknown-linux-musleabihf";
          rustTarget = "arm-unknown-linux-musleabihf";
        };

        "x86_64-windows" = newBuildTarget {
          nixPkgsSystem = "x86_64-w64-mingw32";
          rustTarget = "x86_64-pc-windows-gnu";
          nativeBuildInputs = pkgsCross: [
            pkgsCross.stdenv.cc
            pkgsCross.windows.pthreads
          ];
          rustFlags = pkgsCross: [
            "-C" "link-arg=-L${pkgsCross.windows.pthreads}/lib"
          ];
        };
      };

      # eachSystem [system] (system: ...)
      #
      # Returns an attrset with a key for every system in the given array, with
      # the key's value being the result of calling the callback with that key.
      eachSystem = supportedSystems: callback: builtins.foldl'
        (overall: system: overall // { ${system} = callback system; })
        {}
        supportedSystems;

      # eachCrossSystem [system] ({buildSystem, targetSystem, isDefault }: ...)
      #
      # Returns an attrset with a key "$buildSystem.cross-$targetSystem" for
      # every combination of the elements of the array of system strings. The
      # value of the attrs will be the result of calling the callback with each
      # combination.
      #
      # There will also be keys "$system.default", which are aliases of
      # "$system.cross-$system" for every system.
      #
      eachCrossSystem = supportedSystems: callback:
        eachSystem supportedSystems (buildSystem: let
          pkgs = mkPkgs buildSystem null;
          crosses = builtins.foldl'
            (inner: targetSystem: inner // {
              "cross-${targetSystem}" = callback {
                inherit buildSystem targetSystem;
                isDefault = false;
              };
            })
            {}
            supportedSystems;
        in
          crosses // (rec {
            default = callback {
              inherit buildSystem;
              targetSystem = buildSystem;
              isDefault = true;
            };
            release = let
              bins = pkgs.symlinkJoin {
                name = "${default.name}-all-bins";
                paths = builtins.attrValues crosses;
              };
            in
              pkgs.runCommand "${default.name}-release" {} ''
                cp -rL "${bins}" "$out"
                chmod +w "$out"/bin
                (cd "$out"/bin && sha256sum * > sha256.txt)
              '';
          })
        );

      mkPkgs = buildSystem: targetSystem: import nixpkgs ({
        system = buildSystem;
      } // (if targetSystem == null then {} else {
        # The nixpkgs cache doesn't have any packages where cross-compiling has
        # been enabled, even if the target platform is actually the same as the
        # build platform (and therefore it's not really cross-compiling). So we
        # only set up the cross-compiling config if the target platform is
        # different.
        crossSystem.config = buildTargets.${targetSystem}.nixPkgsSystem;
      }));

      mkToolchain = buildSystem: targetSystem: let
        buildTarget = buildTargets.${targetSystem};
        rustTarget = buildTarget.rustTarget;
        fenixPkgs = fenix.packages.${buildSystem};

        # TODO I'd prefer to use the toolchain file
        # https://github.com/nix-community/fenix/issues/123
        fenixToolchain = fenixTarget: (builtins.getAttr "toolchainOf" fenixTarget) {
          channel = "1.76.0";
          sha256 = "sha256-e4mlaJehWBymYxJGgnbuCObVlqMlQSilZ8FljG9zPHY=";
        };
      in
        fenixPkgs.combine [
          (fenixToolchain fenixPkgs).rustc
          (fenixToolchain fenixPkgs).rustfmt
          (fenixToolchain fenixPkgs).cargo
          (fenixToolchain fenixPkgs).clippy
          (fenixToolchain (fenixPkgs.targets).${rustTarget}).rust-std
        ];

      buildEnv = buildSystem: targetSystem: let
        pkgs = mkPkgs buildSystem null;
        pkgsCross = mkPkgs buildSystem targetSystem;
        buildTarget = buildTargets.${targetSystem};
      in
        rec {
          nativeBuildInputs = (buildTarget.nativeBuildInputs pkgsCross) ++ [
            (mkToolchain buildSystem targetSystem)

            # Required for shell because of rust dependency build scripts which
            # must run on the build system.
            pkgs.stdenv.cc
          ];

          OPENSSL_STATIC = "1";
          OPENSSL_LIB_DIR = "${pkgsCross.pkgsStatic.openssl.out}/lib";
          OPENSSL_INCLUDE_DIR = "${pkgsCross.pkgsStatic.openssl.dev}/include";

          # Required because ring crate is special. This also seems to have
          # fixed some issues with the x86_64-windows cross-compile :shrug:
          TARGET_CC = "${pkgsCross.stdenv.cc}/bin/${pkgsCross.stdenv.cc.targetPrefix}cc";

          CARGO_BUILD_TARGET = buildTarget.rustTarget;
          CARGO_BUILD_RUSTFLAGS = [
            "-C" "target-feature=+crt-static"

            # -latomic is required to build openssl-sys for armv6l-linux, but
            # it doesn't seem to hurt any other builds.
            "-C" "link-args=-static -latomic"

            # https://github.com/rust-lang/cargo/issues/4133
            "-C" "linker=${TARGET_CC}"
          ] ++ (buildTarget.rustFlags pkgsCross);
        };

    in {

      packages = eachCrossSystem
        (builtins.attrNames buildTargets)
        ({ buildSystem, targetSystem, isDefault }: let
          pkgs = mkPkgs buildSystem null;
          toolchain = mkToolchain buildSystem targetSystem;
          naersk-lib = pkgs.callPackage naersk {
            cargo = toolchain;
            rustc = toolchain;
          };
        in
          naersk-lib.buildPackage (rec {
            src = ./.;
            strictDeps = true;
            doCheck = false;
            release = true;
            postInstall = if isDefault then "" else ''
              cd "$out"/bin
              for f in "$(ls)"; do
                if ext="$(echo "$f" | grep -oP '\.[a-z]+$')"; then
                  base="$(echo "$f" | cut -d. -f1)"
                  mv "$f" "$base-${targetSystem}$ext"
                else
                  mv "$f" "$f-${targetSystem}"
                fi
              done
            '';
          } // (buildEnv buildSystem targetSystem))
        );

      devShells = eachCrossSystem
        (builtins.attrNames buildTargets)
        ({ buildSystem, targetSystem, isDefault }: let
          pkgs = mkPkgs buildSystem null;
          toolchain = mkToolchain buildSystem targetSystem;
        in
          pkgs.mkShell ({
            buildInputs = [
              pkgs.nmap
              pkgs.websocat
            ];
            shellHook = ''
              export CARGO_HOME=$(pwd)/.cargo

              if [ -f "config-dev.yml" ]; then
                export DOMANI_CONFIG_PATH=config-dev.yml
              fi
            '';
          } // (buildEnv buildSystem targetSystem))
        );
    };
}
