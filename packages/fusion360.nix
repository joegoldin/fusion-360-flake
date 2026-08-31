# Launcher for the store-built Fusion prefix.
#
# The prefix lives in /nix/store and is read-only, but wine writes to its
# prefix constantly and Fusion keeps user settings and documents there. So the
# store prefix is the read-only lower layer of a union mount, and everything
# written at runtime lands in a writable upper layer under $XDG_DATA_HOME.
#
# unionfs-fuse rather than kernel overlayfs: it needs no privileges beyond the
# setuid fusermount helper that is already present wherever FUSE is enabled,
# and it is the same mechanism mkWindowsApp used, so it is known to work here.
{
  lib,
  stdenv,
  wine,
  prefix,
  installerSrc,
  makeDesktopItem,
  copyDesktopItems,
  makeWrapper,
  writeShellApplication,
  unionfs-fuse,
  fuse,
  coreutils,
  findutils,
}:
let
  launcher = writeShellApplication {
    name = "fusion360";

    runtimeInputs = [
      wine
      unionfs-fuse
      fuse
      coreutils
      findutils
    ];

    text = ''
      data="''${XDG_DATA_HOME:-$HOME/.local/share}/fusion360"
      upper="$data/upper"
      merged="''${XDG_RUNTIME_DIR:-/tmp}/fusion360-prefix"

      mkdir -p "$upper" "$merged"

      # A prefix from an older build is not compatible with this one's layout,
      # so the upper layer is keyed to the prefix it was created against.
      stamp="$data/prefix-path"
      if [ -f "$stamp" ] && [ "$(cat "$stamp")" != "${prefix}" ]; then
        echo "fusion360: prefix changed since this profile was created." >&2
        echo "fusion360: previous $(cat "$stamp")" >&2
        echo "fusion360: current  ${prefix}" >&2
        echo "fusion360: move or delete $upper to start from the new prefix." >&2
      fi
      printf '%s' "${prefix}" > "$stamp"

      cleanup() {
        # Wine must be gone before the union can be unmounted, or the mount
        # stays busy and the next launch inherits a stale merged directory.
        WINEPREFIX="$merged" wineserver -k || true
        fusermount -u "$merged" 2>/dev/null || true
      }

      if mountpoint -q "$merged" 2>/dev/null; then
        echo "fusion360: $merged is already mounted; is Fusion already running?" >&2
        exit 1
      fi

      unionfs -o cow,hide_meta_files "$upper=RW:${prefix}=RO" "$merged"
      trap cleanup EXIT INT TERM

      export WINEPREFIX="$merged"
      export WINEARCH=win64
      export WINEDEBUG=-all,+err
      export DXVK_LOG_LEVEL=none

      # Autodesk's browser sign-in hands back an adskidmgr: URL; when invoked
      # as the scheme handler, route it to the identity manager rather than
      # starting a second Fusion.
      case "''${1:-}" in
        adskidmgr:*)
          target="$(find "$merged" -name AdskIdentityManager.exe | head -n 1)"
          ;;
        *)
          # Newest build wins: Fusion leaves older ones in place when it
          # updates itself into the upper layer.
          target="$(find "$merged" -name Fusion360.exe -printf '%T+ %p\n' \
            | sort -r | head -n 1 | cut -d' ' -f2-)"
          ;;
      esac

      if [ -z "$target" ]; then
        echo "fusion360: no executable found in the prefix" >&2
        exit 1
      fi

      wine "$target" "$@"
    '';
  };
in
stdenv.mkDerivation {
  pname = "fusion360";
  version = "24.03.2026";

  dontUnpack = true;

  nativeBuildInputs = [
    copyDesktopItems
    makeWrapper
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    ln -s ${lib.getExe launcher} $out/bin/fusion360

    install -Dm444 ${installerSrc}/files/setup/resource/graphics/autodesk_fusion.svg \
      $out/share/icons/hicolor/scalable/apps/autodesk-fusion.svg

    runHook postInstall
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "autodesk-fusion";
      exec = "fusion360 %u";
      icon = "autodesk-fusion";
      desktopName = "Autodesk Fusion";
      comment = "3D CAD/CAM/CAE";
      categories = [
        "Graphics"
        "Engineering"
      ];
      startupWMClass = "fusion360.exe";
    })
    (makeDesktopItem {
      name = "adskidmgr-opener";
      exec = "fusion360 %u";
      desktopName = "Autodesk Identity Manager Scheme Handler";
      noDisplay = true;
      mimeTypes = [ "x-scheme-handler/adskidmgr" ];
    })
  ];

  passthru = { inherit prefix launcher; };

  meta = {
    description = "Autodesk Fusion (CAD/CAM/CAE) on wine, installed at build time";
    homepage = "https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "fusion360";
  };
}
