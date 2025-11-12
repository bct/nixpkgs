{
  lib,
  stdenv,
  buildGoModule,
  fetchFromGitHub,
  installShellFiles,
  nixosTests,
  runCommand,
  go,
  coredns,
  vendorHash ? "sha256-W0F8oEm+OpoGEx8GpF3YdoFHwK7pAc3jqF8qe7v5MIQ=",
  externalPlugins ? [ ],
  externalPluginsHash ? "",
}:

let
  hasExternalPlugins = builtins.length externalPlugins > 0;

  attrsToSources = attrs: map ({ repo, version, ... }: "${repo}@${version}") attrs;
  sourcesSorted = lib.sort lib.lessThan (attrsToSources externalPlugins);

  # a fixed-output derivation that retrieves external plugins and their
  # dependencies in a format that can be used for a Go module proxy.
  pluginGoModules = stdenv.mkDerivation {
    pname = "coredns-plugins-go-modules";

    # ensure that this derivation is rebuilt when the list of plugins
    # changes, even if the caller forgot to update externalPluginsHash.
    version = builtins.hashString "md5" (builtins.concatStringsSep "/" sourcesSorted);

    nativeBuildInputs = [ go ];
    dontUnpack = true;

    buildPhase = ''
      export GOCACHE=$TMPDIR/go-cache
      export GOPATH="$TMPDIR/go"

      module_path=$(mktemp -d)
      cd $module_path

      # generate a dummy go module that depends on the desired plugins.
      go mod init _
      ${
        lib.concatMapStringsSep "\n"
          (source: "go get ${source}")
          (attrsToSources externalPlugins)
      }

      # download the plugins & their transitive dependencies
      # (including .info files)
      go mod download all
    '';

    installPhase = ''
      rm -rf "$GOPATH/pkg/mod/cache/download/sumdb"
      cp -r --reflink=auto "$GOPATH/pkg/mod/cache/download" $out
    '';

    outputHashMode = "recursive";
    outputHash = externalPluginsHash;
    # Handle empty `vendorHash`; avoid error:
    # empty hash requires explicit hash algorithm.
    outputHashAlgo = if externalPluginsHash == "" then "sha256" else null;
  };
in
buildGoModule (finalAttrs: {
  pname = "coredns";
  version = "1.13.1";

  src = fetchFromGitHub {
    owner = "coredns";
    repo = "coredns";
    tag = "v${finalAttrs.version}";
    hash = "sha256-rWa4xjHRREoMtvPqW6ZP6Ym9qNTa0l8Opd15FsmxraI=";
  };

  inherit vendorHash;

  # proxyVendor allows us to combine coredns' dependencies with the
  # external plugin dependencies, using the GOPROXY env var.
  proxyVendor = true;

  nativeBuildInputs = [ installShellFiles ];

  outputs = [
    "out"
    "man"
  ];

  # Configure coredns to build in external plugins
  postConfigure = lib.optionalString hasExternalPlugins ''
    export GOPROXY="file://$goModules,file://${pluginGoModules}"

    cp plugin.cfg plugin.cfg.orig
    ${
      (lib.concatMapStringsSep "\n" (
        plugin:
        let
          position = plugin.position or "end-of-file";
          formatPlugin = { name, repo, ... }: "${name}:${repo}";
        in
        if position == "end-of-file" then
          "echo '${formatPlugin plugin}' >> plugin.cfg"
        else if position == "start-of-file" then
          "sed -i '1i ${formatPlugin plugin}' plugin.cfg"
        else if lib.hasAttrByPath [ "before" ] position then
          ''
            if ! grep -q '^${position.before}:' plugin.cfg; then
              echo 'Failed to insert ${plugin.name} before ${position.before} in plugin.cfg: ${position.before} is not in plugin.cfg'
              exit 1
            fi
            sed -i '/^${position.before}:/i ${formatPlugin plugin}' plugin.cfg
          ''
        else if lib.hasAttrByPath [ "after" ] position then
          ''
            if ! grep -q '^${position.after}:' plugin.cfg; then
              echo 'Failed to insert ${plugin.name} after ${position.after} in plugin.cfg: ${position.after} is not in plugin.cfg'
              exit 1
            fi
            sed -i '/^${position.after}:/a ${formatPlugin plugin}' plugin.cfg
          ''
        else
          throw ''
            Unsupported position value in externalPlugin:
              ${builtins.toJSON plugin}.
            Valid values for position attr are:
              - position = "end-of-file" (the default)
              - position = "start-of-file"
              - position.before = "{other plugin}"
              - position.after = "{other plugin}"
          ''
      ) externalPlugins)
    }
    diff -u plugin.cfg.orig plugin.cfg || true
    GOOS= GOARCH= go generate
    for src in ${toString (attrsToSources externalPlugins)}; do go get $src; done
  '';

  postPatch = ''
    substituteInPlace test/file_cname_proxy_test.go \
      --replace-fail \
        "TestZoneExternalCNAMELookupWithProxy" \
        "SkipZoneExternalCNAMELookupWithProxy"

    substituteInPlace test/readme_test.go \
      --replace-fail "TestReadme" "SkipReadme"

    # this test fails if any external plugins were imported.
    # it's a lint rather than a test of functionality, so it's safe to disable.
    substituteInPlace test/presubmit_test.go \
      --replace-fail "TestImportOrdering" "SkipImportOrdering"
  ''
  + lib.optionalString stdenv.hostPlatform.isDarwin ''
    # loopback interface is lo0 on macos
    sed -E -i 's/\blo\b/lo0/' plugin/bind/setup_test.go

    # test is apparently outdated but only exhibits this on darwin
    substituteInPlace test/corefile_test.go \
      --replace-fail "TestCorefile1" "SkipCorefile1"
  '';

  __darwinAllowLocalNetworking = true;

  postInstall = ''
    installManPage man/*
  '';

  passthru.tests = {
    kubernetes-single-node = nixosTests.kubernetes.dns-single-node;
    kubernetes-multi-node = nixosTests.kubernetes.dns-multi-node;

    # test that we can build coredns without external plugins.
    # this helps ensure that tests.external-plugins is a valid test.
    no-plugins = runCommand "coredns-no-plugins-test" { } ''
      # the "example" plugin has _not_ been registered with coredns.
      ${coredns}/bin/coredns -plugins > $out
      if cat $out | grep example >/dev/null; then
        echo 'coredns -plugins unexpectedly contained "example"'
        exit 1
      fi
    '';

    # test that we can build coredns with external plugins
    external-plugins = let
      coredns-with-plugins = coredns.override {
        externalPlugins = [
          {
            name = "example";
            repo = "github.com/coredns/example";
            # the version string can be retrieved like this:
            # nix run nixpkgs#go -- \
            #   list -m -versions -json github.com/coredns/example@master \
            #   | grep Version
            version = "v0.0.0-20200925060636-a998e071a3a3";
            position = "start-of-file";
          }
        ];
        # this hash should not need to change when coredns is updated.
        externalPluginsHash = "sha256-BBMSVf4bC81SqtNwfjB+KkOZxMn93Tsz3ahOsSr7LrI=";
      };
    in runCommand "coredns-external-plugins-test" { } ''
      # the "example" plugin has been registered with coredns.
      ${coredns-with-plugins}/bin/coredns -plugins > $out
      cat $out | grep example >/dev/null
    '';
  };

  meta = {
    homepage = "https://coredns.io";
    description = "DNS server that runs middleware";
    mainProgram = "coredns";
    license = lib.licenses.asl20;
    maintainers = with lib.maintainers; [
      deltaevo
      djds
      rtreffer
      rushmorem
    ];
  };
})
