{ stdenv
, lib
, buildPackages
, cacert
, cargo
, diffutils
, fetchCargoTarball
, runCommandNoCC
, rustPlatform
, callPackage
, remarshal
, git
, rust
, rustc
, windows
}:

{ name ? "${args.pname}-${args.version}"

  # SRI hash
, cargoHash ? ""

  # Legacy hash
, cargoSha256 ? ""

, src ? null
, srcs ? null
, unpackPhase ? null
, cargoPatches ? []
, patches ? []
, sourceRoot ? null
, logLevel ? ""
, buildInputs ? []
, nativeBuildInputs ? []
, cargoUpdateHook ? ""
, cargoDepsHook ? ""
, cargoBuildFlags ? []
, buildType ? "release"
, meta ? {}
, target ? rust.toRustTargetSpec stdenv.hostPlatform
, cargoVendorDir ? null
, checkType ? buildType
, depsExtraArgs ? {}
, cargoParallelTestThreads ? true

# Toggles whether a custom sysroot is created when the target is a .json file.
, __internal_dontAddSysroot ? false

# Needed to `pushd`/`popd` into a subdir of a tarball if this subdir
# contains a Cargo.toml, but isn't part of a workspace (which is e.g. the
# case for `rustfmt`/etc from the `rust-sources).
# Otherwise, everything from the tarball would've been built/tested.
, buildAndTestSubdir ? null
, ... } @ args:

assert cargoVendorDir == null -> !(cargoSha256 == "" && cargoHash == "");
assert buildType == "release" || buildType == "debug";

let

  cargoDeps = if cargoVendorDir == null
    then fetchCargoTarball ({
        inherit name src srcs sourceRoot unpackPhase cargoUpdateHook;
        hash = cargoHash;
        patches = cargoPatches;
        sha256 = cargoSha256;
      } // depsExtraArgs)
    else null;

  # If we have a cargoSha256 fixed-output derivation, validate it at build time
  # against the src fixed-output derivation to check consistency.
  validateCargoDeps = !(cargoHash == "" && cargoSha256 == "");

  # Some cargo builds include build hooks that modify their own vendor
  # dependencies. This copies the vendor directory into the build tree and makes
  # it writable. If we're using a tarball, the unpackFile hook already handles
  # this for us automatically.
  setupVendorDir = if cargoVendorDir == null
    then (''
      unpackFile "$cargoDeps"
      cargoDepsCopy=$(stripHash $cargoDeps)
    '')
    else ''
      cargoDepsCopy="$sourceRoot/${cargoVendorDir}"
    '';

  targetIsJSON = lib.hasSuffix ".json" target;
  useSysroot = targetIsJSON && !__internal_dontAddSysroot;

  # see https://github.com/rust-lang/cargo/blob/964a16a28e234a3d397b2a7031d4ab4a428b1391/src/cargo/core/compiler/compile_kind.rs#L151-L168
  # the "${}" is needed to transform the path into a /nix/store path before baseNameOf
  shortTarget = if targetIsJSON then
      (lib.removeSuffix ".json" (builtins.baseNameOf "${target}"))
    else target;

  sysroot = (callPackage ./sysroot {}) {
    inherit target shortTarget;
    RUSTFLAGS = args.RUSTFLAGS or "";
    originalCargoToml = src + /Cargo.toml; # profile info is later extracted
  };

  ccForBuild="${buildPackages.stdenv.cc}/bin/${buildPackages.stdenv.cc.targetPrefix}cc";
  cxxForBuild="${buildPackages.stdenv.cc}/bin/${buildPackages.stdenv.cc.targetPrefix}c++";
  ccForHost="${stdenv.cc}/bin/${stdenv.cc.targetPrefix}cc";
  cxxForHost="${stdenv.cc}/bin/${stdenv.cc.targetPrefix}c++";
  releaseDir = "target/${shortTarget}/${buildType}";
  tmpDir = "${releaseDir}-tmp";

  # Specify the stdenv's `diff` by abspath to ensure that the user's build
  # inputs do not cause us to find the wrong `diff`.
  # The `.nativeDrv` stanza works like nativeBuildInputs and ensures cross-compiling has the right version available.
  diff = "${diffutils.nativeDrv or diffutils}/bin/diff";

in

# Tests don't currently work for `no_std`, and all custom sysroots are currently built without `std`.
# See https://os.phil-opp.com/testing/ for more information.
assert useSysroot -> !(args.doCheck or true);

stdenv.mkDerivation ((removeAttrs args ["depsExtraArgs"]) // lib.optionalAttrs useSysroot {
  RUSTFLAGS = "--sysroot ${sysroot} " + (args.RUSTFLAGS or "");
} // {
  inherit cargoDeps;

  patchRegistryDeps = ./patch-registry-deps;

  nativeBuildInputs = nativeBuildInputs ++ [ cacert git cargo rustc ];
  buildInputs = buildInputs ++ lib.optional stdenv.hostPlatform.isMinGW windows.pthreads;

  patches = cargoPatches ++ patches;

  PKG_CONFIG_ALLOW_CROSS =
    if stdenv.buildPlatform != stdenv.hostPlatform then 1 else 0;

  postUnpack = ''
    eval "$cargoDepsHook"

    ${setupVendorDir}

    mkdir .cargo
    config="$(pwd)/$cargoDepsCopy/.cargo/config";
    if [[ ! -e $config ]]; then
      config=${./fetchcargo-default-config.toml};
    fi;
    substitute $config .cargo/config \
      --subst-var-by vendor "$(pwd)/$cargoDepsCopy"

    cat >> .cargo/config <<'EOF'
    [target."${rust.toRustTarget stdenv.buildPlatform}"]
    "linker" = "${ccForBuild}"
    ${lib.optionalString (stdenv.buildPlatform.config != stdenv.hostPlatform.config) ''
    [target."${shortTarget}"]
    "linker" = "${ccForHost}"
    ${# https://github.com/rust-lang/rust/issues/46651#issuecomment-433611633
      lib.optionalString (stdenv.hostPlatform.isMusl && stdenv.hostPlatform.isAarch64) ''
    "rustflags" = [ "-C", "target-feature=+crt-static", "-C", "link-arg=-lgcc" ]
    ''}
    ''}
    EOF

    export RUST_LOG=${logLevel}
  '' + (args.postUnpack or "");

  # After unpacking and applying patches, check that the Cargo.lock matches our
  # src package. Note that we do this after the patchPhase, because the
  # patchPhase may create the Cargo.lock if upstream has not shipped one.
  postPatch = (args.postPatch or "") + lib.optionalString validateCargoDeps ''
    cargoDepsLockfile=$NIX_BUILD_TOP/$cargoDepsCopy/Cargo.lock
    srcLockfile=$NIX_BUILD_TOP/$sourceRoot/Cargo.lock

    echo "Validating consistency between $srcLockfile and $cargoDepsLockfile"
    if ! ${diff} $srcLockfile $cargoDepsLockfile; then

      # If the diff failed, first double-check that the file exists, so we can
      # give a friendlier error msg.
      if ! [ -e $srcLockfile ]; then
        echo "ERROR: Missing Cargo.lock from src. Expected to find it at: $srcLockfile"
        echo "Hint: You can use the cargoPatches attribute to add a Cargo.lock manually to the build."
        exit 1
      fi

      if ! [ -e $cargoDepsLockfile ]; then
        echo "ERROR: Missing lockfile from cargo vendor. Expected to find it at: $cargoDepsLockfile"
        exit 1
      fi

      echo
      echo "ERROR: cargoSha256 is out of date"
      echo
      echo "Cargo.lock is not the same in $cargoDepsCopy"
      echo
      echo "To fix the issue:"
      echo '1. Use "0000000000000000000000000000000000000000000000000000" as the cargoSha256 value'
      echo "2. Build the derivation and wait for it to fail with a hash mismatch"
      echo "3. Copy the 'got: sha256:' value back into the cargoSha256 field"
      echo

      exit 1
    fi
  '' + ''
    unset cargoDepsCopy
  '';

  configurePhase = args.configurePhase or ''
    runHook preConfigure
    runHook postConfigure
  '';

  buildPhase = with builtins; args.buildPhase or ''
    ${lib.optionalString (buildAndTestSubdir != null) "pushd ${buildAndTestSubdir}"}
    runHook preBuild

    (
    set -x
    env \
      "CC_${rust.toRustTarget stdenv.buildPlatform}"="${ccForBuild}" \
      "CXX_${rust.toRustTarget stdenv.buildPlatform}"="${cxxForBuild}" \
      "CC_${rust.toRustTarget stdenv.hostPlatform}"="${ccForHost}" \
      "CXX_${rust.toRustTarget stdenv.hostPlatform}"="${cxxForHost}" \
      cargo build -j $NIX_BUILD_CORES \
        ${lib.optionalString (buildType == "release") "--release"} \
        --target ${target} \
        --frozen ${concatStringsSep " " cargoBuildFlags}
    )

    runHook postBuild

    ${lib.optionalString (buildAndTestSubdir != null) "popd"}

    # This needs to be done after postBuild: packages like `cargo` do a pushd/popd in
    # the pre/postBuild-hooks that need to be taken into account before gathering
    # all binaries to install.
    mkdir -p $tmpDir
    cp -r $releaseDir/* $tmpDir/
    bins=$(find $tmpDir \
      -maxdepth 1 \
      -type f \
      -executable ! \( -regex ".*\.\(so.[0-9.]+\|so\|a\|dylib\)" \))
  '';

  checkPhase = args.checkPhase or (let
    argstr = "${lib.optionalString (checkType == "release") "--release"} --target ${target} --frozen";
    threads = if cargoParallelTestThreads then "$NIX_BUILD_CORES" else "1";
  in ''
    ${lib.optionalString (buildAndTestSubdir != null) "pushd ${buildAndTestSubdir}"}
    runHook preCheck
    echo "Running cargo test ${argstr} -- ''${checkFlags} ''${checkFlagsArray+''${checkFlagsArray[@]}}"
    cargo test -j $NIX_BUILD_CORES ${argstr} -- --test-threads=${threads} ''${checkFlags} ''${checkFlagsArray+"''${checkFlagsArray[@]}"}
    runHook postCheck
    ${lib.optionalString (buildAndTestSubdir != null) "popd"}
  '');

  doCheck = args.doCheck or true;

  strictDeps = true;

  inherit releaseDir tmpDir;

  installPhase = args.installPhase or ''
    runHook preInstall

    # rename the output dir to a architecture independent one
    mapfile -t targets < <(find "$NIX_BUILD_TOP" -type d | grep '${tmpDir}$')
    for target in "''${targets[@]}"; do
      rm -rf "$target/../../${buildType}"
      ln -srf "$target" "$target/../../"
    done
    mkdir -p $out/bin $out/lib

    xargs -r cp -t $out/bin <<< $bins
    find $tmpDir \
      -maxdepth 1 \
      -regex ".*\.\(so.[0-9.]+\|so\|a\|dylib\)" \
      -print0 | xargs -r -0 cp -t $out/lib
    rmdir --ignore-fail-on-non-empty $out/lib $out/bin
    runHook postInstall
  '';

  passthru = { inherit cargoDeps; } // (args.passthru or {});

  meta = {
    # default to Rust's platforms
    platforms = rustc.meta.platforms;
  } // meta;
})
