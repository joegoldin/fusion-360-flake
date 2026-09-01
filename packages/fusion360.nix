# Launcher for the store-built Fusion prefix.
#
# The prefix is built by nix and lives in /nix/store, where everything is mode
# 444/555 and owned by root. A wine prefix has to be writable — wine rewrites
# system.reg and user.reg on every run, and Fusion rewrites plenty besides.
#
# Overlaying a writable layer over the store copy does not work, and not for
# want of the right options: opening a mode-444 lower file for writing is
# refused at the permission check before any overlay implementation gets the
# chance to copy it up, and renaming over one fails with EPERM. unionfs-fuse
# and fuse-overlayfs behave identically here, including with squash_to_uid and
# noacl. Pre-creating the directory tree in the upper layer buys new files in
# existing directories, but nothing can be *modified*, so wine cannot save the
# registry and Fusion never finishes starting.
#
# So the prefix is materialized once into a writable copy under $XDG_DATA_HOME.
# It costs ~10GB of disk and a couple of minutes on first run, and in exchange
# everything downstream is ordinary: no FUSE, no mount lifecycle, no permission
# games, and Fusion's own in-place updates work the way it expects.
#
# The build-time install is still doing the real work: this copy is a file
# copy, with nothing downloaded, no winetricks and no wine install.

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
  glibc,
  gnused,
  rsync,
  vulkan-loader,
  util-linux,
  coreutils,
  findutils,
}:
let
  # Fusion's bootstrap options: graphics driver (VirtualDeviceDx11), the Qt
  # rendering API, and TrustAllServers. Upstream's installer copies this into
  # the user profile, and Fusion hangs on the splash without it.
  machineOptions = "${installerSrc}/files/setup/resource/video_driver/DXVK/NMachineSpecificOptions.xml";

  launcher = writeShellApplication {
    name = "fusion360";

    runtimeInputs = [
      wine
      glibc.bin
      gnused
      rsync
      util-linux
      coreutils
      findutils
    ];

    text = ''
      store_prefix="${prefix}"
      data="''${XDG_DATA_HOME:-$HOME/.local/share}/fusion360"
      prefix="$data/prefix"
      stamp="$data/prefix-source"

      mkdir -p "$data"

      # An earlier version of this launcher mounted the store prefix as a
      # read-only overlay lower layer with a writable upper layer. That could
      # never work (see the note above), so drop the leftovers rather than
      # leave orphaned state sitting in the user's data directory.
      if [ -e "$data/prefix-path" ] || [ -d "$data/upper" ]; then
        echo "fusion360: removing state from the old overlay layout" >&2
        rm -rf "$data/upper" "$data/work" "$data/prefix-path"
      fi

      # Materialize (or re-materialize) the writable prefix. Keyed on the store
      # path so a package bump is noticed; the copy goes to a scratch directory
      # and is swapped into place at the end, so an interrupted copy can never
      # leave a half-populated prefix behind that looks complete.
      if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$store_prefix" ]; then
        echo "fusion360: preparing the wine prefix, this takes a couple of minutes" >&2
        rm -rf "$prefix.new"
        mkdir -p "$prefix.new"
        # --chmod gives the copy real write bits; the store originals are 444.
        rsync -a --chmod=u+rwX,go-w "$store_prefix/" "$prefix.new/"

        if [ -d "$prefix" ]; then
          # Carry the user profile across so a package bump does not throw away
          # local settings, then drop the old tree.
          for u in "$prefix"/drive_c/users/*/; do
            [ -d "$u" ] || continue
            name="$(basename "$u")"
            [ "$name" = "Public" ] && continue
            rsync -a --chmod=u+rwX "$u" "$prefix.new/drive_c/users/$name/" 2>/dev/null || true
          done
          rm -rf "$prefix.old"
          mv "$prefix" "$prefix.old"
        fi
        mv "$prefix.new" "$prefix"
        rm -rf "$prefix.old"
        printf '%s' "$store_prefix" > "$stamp"
        echo "fusion360: prefix ready" >&2
      fi

      # Fusion reads its bootstrap options — graphics driver, Qt rendering API,
      # TLS behaviour — from the *running* user's profile. The prefix is built
      # by the nix build user, so the copy written at build time lands under a
      # profile Fusion never reads, and without these options it falls back to
      # probing for a graphics driver and hangs on the splash at "Initializing".
      #
      # Seed them here, where the user is known. Only fills in what is missing,
      # so preferences changed inside Fusion are left alone.
      user="$(id -un)"
      for d in \
        "AppData/Roaming/Autodesk/Neutron Platform/Options" \
        "AppData/Local/Autodesk/Neutron Platform/Options" \
        "Application Data/Autodesk/Neutron Platform/Options"
      do
        opts="$prefix/drive_c/users/$user/$d/NMachineSpecificOptions.xml"
        if [ ! -f "$opts" ]; then
          mkdir -p "$(dirname "$opts")"
          install -m 644 "${machineOptions}" "$opts"
        fi
      done

      # Hide the navigation bar.
      #
      # It is drawn by AdCefWebBrowser as a CEF surface composited over the
      # D3D viewport, and each repaint clobbers the presented frame: the
      # viewport flashes black whenever the application goes idle, and stops
      # the moment the bar is hidden. Upstream ships fix-navbar-flicker.sh for
      # this and expects the user to run it by hand.
      #
      # Done on every launch rather than once, because the layout file only
      # appears after an account has logged in and lives under a per-account
      # profile directory — neither of which the prefix can know at build time.
      # Only ever flips True to False, so re-showing the bar from the View menu
      # survives until the next launch.
      for opts in \
        "$prefix/drive_c/users/$user/AppData/Roaming/Autodesk/Neutron Platform/Options" \
        "$prefix/drive_c/users/$user/AppData/Local/Autodesk/Neutron Platform/Options" \
        "$prefix/drive_c/users/$user/Application Data/Autodesk/Neutron Platform/Options"
      do
        [ -d "$opts" ] || continue
        for profile in "$opts"/*/; do
          layout="$profile/NULastDisplayedLayout.xml"
          [ -f "$layout" ] || continue
          # The file is UTF-16LE; work on a UTF-8 copy and convert back.
          decoded=$(iconv -f UTF-16LE -t UTF-8 "$layout" 2>/dev/null) || continue
          case "$decoded" in
            *'Contents="NavToolbar"'*)
              # [^>] keeps the substitution inside the NavToolbar tag; a greedy
              # .* would run past it and rewrite an unrelated Visible= later in
              # what is effectively one long line.
              printf '%s' "$decoded" \
                | sed 's/\(Contents="NavToolbar"[^>]*\)Visible="True"/\1Visible="False"/' \
                | iconv -f UTF-8 -t UTF-16LE > "$layout".tmp \
                && mv "$layout".tmp "$layout"
              ;;
          esac
        done
      done

      export WINEPREFIX="$prefix"
      export WINEARCH=win64
      export WINEDEBUG=-all,+err
      export DXVK_LOG_LEVEL=none

      # winevulkan dlopen()s libvulkan.so.1 rather than linking it, and NixOS
      # ships no libvulkan on any default search path — /run/opengl-driver/lib
      # carries the ICDs but not the loader, and every Vulkan program here
      # finds its own through an RPATH. Without this DXVK fails at
      # "Failed to create Vulkan 1.1 instance" and Fusion loses hardware
      # rendering even though the host has a working Vulkan driver.
      # Fusion embeds Chromium through QtWebEngine for its in-app panels (the
      # "what's new" dialogs, the app store, parts of the help). Chromium's
      # sandbox relies on Linux namespaces and seccomp reached through syscalls
      # wine does not provide, so QtWebEngineProcess.exe dies immediately and
      # those panels render blank. The sandbox is not buying anything here
      # anyway: everything already runs inside the user's own wine prefix.
      export QTWEBENGINE_CHROMIUM_FLAGS="--no-sandbox ''${QTWEBENGINE_CHROMIUM_FLAGS:-}"

      export LD_LIBRARY_PATH="${vulkan-loader}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      export DXVK_STATE_CACHE_PATH="''${XDG_CACHE_HOME:-$HOME/.cache}/fusion360-dxvk"
      mkdir -p "$DXVK_STATE_CACHE_PATH"

      # Autodesk's browser sign-in hands back an adskidmgr: URL; when invoked
      # as the scheme handler, route it to the identity manager rather than
      # starting a second Fusion.
      # Only the main launch owns the prefix's lifetime. The scheme handler
      # runs *while* Fusion is up, so it must not tear the prefix down on the
      # way out.
      owns_prefix=1

      case "''${1:-}" in
        adskidmgr:*)
          target="$(find "$prefix" -name AdskIdentityManager.exe | head -n 1)"
          owns_prefix=0
          ;;
        *)
          # Newest build wins: Fusion leaves older ones in place when it
          # updates itself.
          target="$(find "$prefix" -name Fusion360.exe -printf '%T+ %p\n' \
            | sort -r | head -n 1 | cut -d' ' -f2-)"
          ;;
      esac

      if [ -z "$target" ]; then
        echo "fusion360: no executable found in $prefix" >&2
        exit 1
      fi

      # Wine does not exit when the application does. services.exe,
      # winedevice.exe, plugplay, rpcss, svchost, explorer and Autodesk's own
      # cer_service.exe all stay resident, each holding a system D-Bus
      # connection, and a new set accumulates on every launch.
      #
      # That is not merely untidy. dbus-broker accounts its byte quota per UID
      # and splits it across that UID's peers, so enough abandoned peers starve
      # the share of everything else: after a day of launches here, Steam was
      # dropped on connect with "does not have the resources to receive a reply
      # it requested" and plasma-powerdevil had failed to start 237 times.
      #
      # So tear the prefix down when Fusion exits. `wineserver -k` takes the
      # whole tree with it; the wait first gives anything mid-write a chance to
      # finish, since this is where Fusion flushes its layout and preferences.
      cleanup_prefix() {
        [ "$owns_prefix" = 1 ] || return 0
        timeout 15 wineserver -w 2>/dev/null || true
        wineserver -k 2>/dev/null || true
      }
      trap cleanup_prefix EXIT INT TERM

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
