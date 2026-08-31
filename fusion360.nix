# Autodesk Fusion via mkWindowsApp.
#
# This replaces the upstream shell installer's Wine handling
# (`wine_autodesk_fusion_install()` in files/setup/autodesk_fusion_installer_x86-64.sh).
# Everything that script does for distro detection, package-manager installs,
# interactive menus and wineprefixes.log bookkeeping is dropped: under Nix the
# dependency closure is the derivation, and mkWindowsApp owns the prefix.
#
# What's left is the recipe itself, which mkWindowsApp materializes into a
# cached layer under ~/.cache/mkWindowsApp on first launch.
{
  lib,
  mkWindowsApp,
  wine,
  installerSrc,
  fetchurl,
  makeDesktopItem,
  copyDesktopItems,
  curl,
  coreutils,
  gnugrep,
  findutils,
}:
let
  # Pinned: upstream's default WEBVIEW2_INSTALLER_URL is the evergreen
  # go.microsoft.com redirect, but its own commented-out alternative names
  # 109.0.1518.78 as the known-good build. Pin that one — it is the version
  # the rest of this recipe was developed against, and it is archived at a
  # stable URL, so there is no reason to take a rolling dependency here.
  webview2 = fetchurl {
    url = "https://github.com/aedancullen/webview2-evergreen-standalone-installer-archive/releases/download/109.0.1518.78/MicrosoftEdgeWebView2RuntimeInstallerX64.exe";
    hash = "sha256-8sxJhj4iFALUZk2fqUSkfyJUPaLcs2NDjD5Zh4m5/Vs=";
  };

  # NOT pinned, deliberately. Fusion is a cloud product and Autodesk enforces a
  # minimum client version server-side, so a hash-pinned installer goes stale
  # and gets refused at login. The layer is built from whatever Autodesk is
  # shipping at build time, and `persistRuntimeLayer` below lets Fusion's own
  # in-place updater keep it current afterwards.
  autodeskInstallerUrl = "https://dl.appstreaming.autodesk.com/production/installers/Fusion%20Admin%20Install.exe";

  # Upstream ships one of these per renderer; we always use DXVK (enableVulkan).
  machineOptions = "${installerSrc}/files/setup/resource/video_driver/DXVK/NMachineSpecificOptions.xml";

  icon = "${installerSrc}/files/setup/resource/graphics/autodesk_fusion.svg";
in
mkWindowsApp rec {
  inherit wine;

  pname = "fusion360";
  version = "2.1.6-alpha";

  src = installerSrc;
  dontUnpack = true;

  wineArch = "win64";

  # DXVK on Vulkan. Replaces the script's `winetricks -q dxvk` + DXVK.reg step:
  # mkWindowsApp's dxvk-vulkan renderer sets HKCU\Software\Wine\Direct3D and
  # runs setup_dxvk.sh itself.
  enableVulkan = true;

  # The install is headless, so the Mono prompt would hang it.
  enableMonoBootPrompt = false;

  # Fusion updates itself in place on launch whenever Autodesk ships a new
  # build. Without a persistent run layer every update would be discarded on
  # exit and re-downloaded on the next start.
  persistRuntimeLayer = true;

  # Must stay false: mkWindowsApp refuses persistRegistry together with
  # enableVulkan (it breaks the DXVK install).
  persistRegistry = false;

  nativeBuildInputs = [ copyDesktopItems ];

  buildInputs = [
    curl
    coreutils
    gnugrep
    findutils
  ];

  winAppInstall = ''
    # 1. Runtime libraries and fonts. dotnet20 is required even though Fusion
    #    targets .NET 4.8 — see https://bugs.winehq.org/show_bug.cgi?id=41727#c5
    winetricks -q atmlib gdiplus corefonts cjkfonts dotnet20 dotnet48 \
      msxml4 msxml6 vcrun2022 fontsmooth=rgb winhttp win10

    # cjkfonts and the Windows version are reapplied because some of the verbs
    # above reset them (upstream hits the same thing and does the same).
    winetricks -q cjkfonts
    winetricks -q win11

    # 2. DLL overrides.
    #    adpclientservice  - Autodesk telemetry; native stub stops it calling home.
    #    AdCefWebBrowser   - the navigation bar only renders correctly on builtin DX9.
    #    msvcp140/mfc140u  - use the redistributable Fusion bundles, not Wine's.
    #    bcp47langs        - empty override; without it the login flow fails.
    $WINE reg add 'HKCU\Software\Wine\DllOverrides' /v adpclientservice.exe /t REG_SZ /d native /f
    $WINE reg add 'HKCU\Software\Wine\DllOverrides' /v AdCefWebBrowser.exe /t REG_SZ /d builtin /f
    $WINE reg add 'HKCU\Software\Wine\DllOverrides' /v msvcp140 /t REG_SZ /d native /f
    $WINE reg add 'HKCU\Software\Wine\DllOverrides' /v mfc140u /t REG_SZ /d native /f
    $WINE reg add 'HKCU\Software\Wine\DllOverrides' /v bcp47langs /t REG_SZ /d "" /f
    $WINE reg add 'HKCU\Software\Wine\X11 Driver' /v Managed /t REG_SZ /d Y /f
    $WINE reg add 'HKCU\Software\Wine\X11 Driver' /v Decorated /t REG_SZ /d Y /f
    wineserver -w

    # 3. WebView2 runtime, which Fusion's sign-in view depends on.
    cp ${webview2} "$WINEPREFIX/drive_c/webview2.exe"
    $WINE 'C:\webview2.exe' /silent /install || true
    wineserver -w
    rm -f "$WINEPREFIX/drive_c/webview2.exe"

    # 4. The Fusion client itself. Run twice on purpose: the first pass stages
    #    the payload and exits before it has finished registering, the second
    #    completes the install. Upstream bounds both with `timeout` because the
    #    installer does not reliably exit on its own; the same applies here, and
    #    a non-zero status is expected rather than fatal.
    curl -fL --retry 3 -o "$WINEPREFIX/drive_c/FusionClientInstaller.exe" \
      '${autodeskInstallerUrl}'
    timeout -k 10m 9m $WINE 'C:\FusionClientInstaller.exe' --quiet || true
    wineserver -w
    timeout -k 5m 1m $WINE 'C:\FusionClientInstaller.exe' --quiet || true
    wineserver -w
    rm -f "$WINEPREFIX/drive_c/FusionClientInstaller.exe"

    # 5. Graphics defaults. Fusion reads this from whichever of the three
    #    locations its build happens to use, so write all three.
    for d in \
      "AppData/Roaming/Autodesk/Neutron Platform/Options" \
      "AppData/Local/Autodesk/Neutron Platform/Options" \
      "Application Data/Autodesk/Neutron Platform/Options"
    do
      mkdir -p "$WINEPREFIX/drive_c/users/$USER/$d"
      install -m 644 ${machineOptions} \
        "$WINEPREFIX/drive_c/users/$USER/$d/NMachineSpecificOptions.xml"
    done

    # Quick Launch dir; Fusion's installer expects it to exist.
    mkdir -p "$WINEPREFIX/drive_c/users/$USER/AppData/Roaming/Microsoft/Internet Explorer/Quick Launch/User Pinned"
  '';

  winAppRun = ''
    # Autodesk's browser sign-in hands back an adskidmgr: URL. When we are
    # invoked as the scheme handler, route it to the identity manager instead
    # of starting a second Fusion. Structured as if/else rather than an early
    # return so mkWindowsApp's post-run persist step still runs either way.
    case "$ARGS" in
      adskidmgr:*)
        TARGET="$(find "$WINEPREFIX" -name AdskIdentityManager.exe | head -n 1)"
        ;;
      *)
        # Pick the most recently installed Fusion360.exe: the client keeps old
        # builds beside the new one after a self-update, so an unordered find
        # would start a stale version.
        TARGET="$(find "$WINEPREFIX" -name Fusion360.exe -printf '%T+ %p\n' \
          | sort -r | head -n 1 | cut -d' ' -f2-)"
        ;;
    esac

    if [ -z "$TARGET" ]; then
      echo "fusion360: no executable found in $WINEPREFIX for args: $ARGS" >&2
      echo "fusion360: if the install did not finish, re-run with WA_CLEAN_APP=1 to rebuild the layer." >&2
    else
      DXVK_LOG_LEVEL=none WINEDEBUG=-all,+err $WINE "$TARGET" $ARGS
    fi
  '';

  installPhase = ''
    runHook preInstall

    ln -s $out/bin/.launcher $out/bin/fusion360

    install -Dm444 ${icon} \
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
    # Handles the adskidmgr: callback the Autodesk login page redirects to.
    (makeDesktopItem {
      name = "adskidmgr-opener";
      exec = "fusion360 %u";
      desktopName = "Autodesk Identity Manager Scheme Handler";
      noDisplay = true;
      mimeTypes = [ "x-scheme-handler/adskidmgr" ];
    })
  ];

  meta = {
    description = "Autodesk Fusion (CAD/CAM/CAE) on Wine, via mkWindowsApp";
    homepage = "https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "fusion360";
  };
}
