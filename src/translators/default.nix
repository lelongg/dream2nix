{
  coreutils,
  dlib,
  jq,
  lib,
  nix,
  pkgs,
  python3,
  callPackageDream,
  externals,
  dream2nixWithExternals,
  utils,
  ...
}: let
  b = builtins;

  l = lib // builtins;

  makeTranslator = translatorModule: let
    translator =
      translatorModule
      # for pure translators
      #   - import the `translate` function
      #   - generate `translateBin`
      // (lib.optionalAttrs (translatorModule ? translate) {
        translate = let
          translateOriginal = callPackageDream translatorModule.translate {
            translatorName = translatorModule.name;
          };
        in
          args:
            translateOriginal
            (
              (dlib.translators.getextraArgsDefaults
                (translatorModule.extraArgs or {}))
              // args
              // args.project.subsystemInfo
              // {
                tree =
                  args.tree or (dlib.prepareSourceTree {inherit (args) source;});
              }
            );
        translateBin =
          wrapPureTranslator
          (with translatorModule; [subsystem type name]);
      })
      # for impure translators:
      #   - import the `translateBin` function
      // (lib.optionalAttrs (translatorModule ? translateBin) {
        translateBin =
          callPackageDream translatorModule.translateBin
          {
            translatorName = translatorModule.name;
          };
      });
  in
    translator;

  translators = dlib.translators.mapTranslators makeTranslator;

  # adds a translateBin to a pure translator
  wrapPureTranslator = translatorAttrPath: let
    bin =
      utils.writePureShellScript
      [
        coreutils
        jq
        nix
        python3
      ]
      ''
        jsonInputFile=$(realpath $1)
        outputFile=$WORKDIR/$(jq '.outputFile' -c -r $jsonInputFile)

        nix eval \
          --option experimental-features "nix-command flakes"\
          --show-trace --impure --raw --expr "
          let
            dream2nix = import ${dream2nixWithExternals} {};

            translatorArgs =
              (builtins.fromJSON
                  (builtins.unsafeDiscardStringContext (builtins.readFile '''$1''')));

            dreamLock =
              dream2nix.translators.translators.${
          lib.concatStringsSep "." translatorAttrPath
        }.translate
                translatorArgs;
          in
            dream2nix.utils.dreamLock.toJSON
              # don't use nix to detect cycles, this will be more efficient in python
              (dreamLock // {
                _generic = builtins.removeAttrs dreamLock._generic [ \"cyclicDependencies\" ];
              })
        " | python3 ${../apps/cli/format-dream-lock.py} > out

        tmpOut=$(realpath out)
        cd $WORKDIR
        mkdir -p $(dirname $outputFile)
        cp $tmpOut $outputFile
      '';
  in
    bin.overrideAttrs (old: {
      name = "translator-${lib.concatStringsSep "-" translatorAttrPath}";
    });
in {
  inherit
    translators
    ;
}
