# Launcher for the store-built Fusion prefix.
#
# The prefix lives in /nix/store and is read-only, but wine writes to its
# prefix constantly and Fusion keeps user settings and documents there. So the
# store prefix is the read-only lower layer of a union mount, and everything
# written at runtime lands in a writable upper layer under $XDG_DATA_HOME.
#
# fuse-overlayfs rather than kernel overlayfs: it needs no privileges beyond
# the setuid fusermount helper, which is already present wherever FUSE is
# enabled. unionfs-fuse was tried first and rejected — see the note about
# store permissions in the launcher below, which it cannot work around either.
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
  fuse-overlayfs,
  util-linux,
  coreutils,
  findutils,
}:
let
  launcher = writeShellApplication {
    name = "fusion360";

    runtimeInputs = [
      wine
      fuse-overlayfs
      util-linux
      coreutils
      findutils
    ];

    text = ''
      prefix="${prefix}"
      data="''${XDG_DATA_HOME:-$HOME/.local/share}/fusion360"
      upper="$data/upper"
      work="$data/work"
      merged="''${XDG_RUNTIME_DIR:-/tmp}/fusion360-prefix"
      stamp="$data/prefix-path"

      mkdir -p "$upper" "$work" "$merged"

      # Everything in /nix/store is mode 555 and owned by root, and no overlay
      # option can conjure a write bit that isn't there: creating a file inside
      # a directory whose only copy is the read-only lower layer fails with
      # EACCES, and wine writes to its prefix constantly.
      #
      # So the writable layer gets its own copy of the directory tree — the
      # directories only, never the file data. Writes then land in a mode-755
      # upper directory while every file is still read straight from the store.
      # For this prefix that is ~10k directories, about 40MB and a few seconds,
      # against ~10GB and minutes for copying the prefix itself.
      #
      # Re-run whenever the prefix changes, and only ever additive, so a
      # package update never destroys the user data already in the upper layer.
      if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$prefix" ]; then
        echo "fusion360: preparing writable layer for $prefix" >&2
        (cd "$prefix" && find . -type d -exec mkdir -p "$upper/{}" \;)
        chmod -R u+rwX "$upper"
        printf '%s' "$prefix" > "$stamp"
      fi

      if mountpoint -q "$merged" 2>/dev/null; then
        echo "fusion360: $merged is already mounted; is Fusion already running?" >&2
        exit 1
      fi

      # fusermount is setuid and must come from the system wrapper directory,
      # NOT from a nixpkgs fuse package: pulling `fuse` into runtimeInputs
      # shadows /run/wrappers/bin/fusermount with an unprivileged copy from the
      # store, and every unmount then fails silently while the mount survives
      # to block the next launch. fuse-overlayfs speaks fuse3, so prefer
      # fusermount3 and keep fusermount as the fallback.
      unmount_merged() {
        fusermount3 -u "$merged" 2>/dev/null || fusermount -u "$merged" 2>/dev/null
      }

      cleanup() {
        # wine has to be gone before the overlay can be unmounted, or the
        # mount stays busy and the next launch aborts on the check above.
        #
        # `wineserver -k` starts a server if none is running, just to kill it,
        # and that server holds the mount for a moment after the command
        # returns — so unmounting immediately fails with EBUSY. Retry for a few
        # seconds, then fall back to a lazy unmount so a wedged server can
        # never strand the mount.
        WINEPREFIX="$merged" wineserver -k 2>/dev/null || true
        for _ in $(seq 20); do
          if unmount_merged; then
            return
          fi
          sleep 0.5
        done
        # Lazy detach, so a wedged wine process can never strand the mount and
        # block the next launch.
        fusermount3 -uz "$merged" 2>/dev/null || fusermount -uz "$merged" 2>/dev/null || true
      }

      fuse-overlayfs -o "lowerdir=$prefix,upperdir=$upper,workdir=$work" "$merged"
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
