# The Autodesk Fusion wine prefix, built as an ordinary derivation.
#
# This is the whole point of the build-time approach: the prefix is produced by
# `nix build` and ships in the closure, so `switch` gives you a machine that
# can already run Fusion. Nothing is downloaded or installed on first launch.
#
# It works because the sandbox never needs network: ./sources.nix pins every
# winetricks payload into the store, and seeding $XDG_CACHE_HOME/winetricks
# with them makes `winetricks -q` an offline operation.
#
# Built in stages rather than one script. Each stage is a derivation that
# copies the previous one, so a change late in the recipe (a registry tweak,
# the Fusion build) doesn't re-run the expensive .NET and font work ahead of
# it. The stage boundaries are chosen for cache value, not tidiness.
{
  lib,
  runCommand,
  writeText,
  xvfb-run,
  wine,
  winetricks,
  fetchFromGitHub,
  glibcLocales,
  sources,
  installerSrc,
}:
let
  # winetricks is pinned rather than taken from nixpkgs, because the payload
  # hashes in ./sources.nix come out of the winetricks script's own download
  # table. If the two versions drift, winetricks rejects the pre-seeded cache
  # as a checksum mismatch and tries to re-download — which fails in the
  # sandbox. nixpkgs shipped 20250102 here while the table was read from
  # 20260125, and that is exactly what went wrong.
  #
  # Bumping this means re-extracting the hashes in sources.nix from the same
  # tag. They are one unit.
  winetricksPinned = winetricks.overrideAttrs (_: rec {
    version = "20260125";
    src = fetchFromGitHub {
      owner = "Winetricks";
      repo = "winetricks";
      rev = version;
      hash = "sha256-uIBVESebsH7rXnxWd/qlrZxcG7Y486PctHzcLz29HDk=";
    };
  });

  # Every stage runs wine, and wine wants a writable HOME and no network
  # chatter. Kept in one place so the stages can't drift apart.
  wineEnv = ''
    set -eux

    export HOME="$TMPDIR/home"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    mkdir -p "$HOME" "$XDG_CACHE_HOME"

    export WINEPREFIX="$out"
    export WINEARCH=win64
    export WINEDEBUG=-all
    # esync/fsync need eventfd limits the sandbox doesn't grant.
    export WINEESYNC=0
    export WINEFSYNC=0
    export WINETRICKS_UPDATE_CHECK=0
    export WINETRICKS_LATEST_VERSION_CHECK=disabled
    export W_OPT_UNATTENDED=1
  '';

  copyPrev = prev: ''
    mkdir -p "$out"
    cp -a ${prev}/. "$out"
    chmod -R +w "$out"
  '';

  wine' = lib.getExe wine;
  winetricks' = lib.getExe winetricksPinned;

  # Stage 1: a bare win64 prefix with winemenubuilder disabled.
  #
  # winemenubuilder writes .desktop files into the *user's* home when the
  # prefix is used later; the desktop entries here are declared in nix
  # instead, so it is turned off at creation time rather than cleaned up after.
  stage1 = runCommand "fusion360-prefix-1-boot" { nativeBuildInputs = [ wine ]; } ''
    ${wineEnv}
    mkdir -p "$out"

    ${wine'} wineboot --init
    ${wine'} regedit /S ${writeText "no-menubuilder.reg" ''
      Windows Registry Editor Version 5.00

      [HKEY_CURRENT_USER\Software\Wine\DllOverrides]
      "winemenubuilder.exe"=""

      [HKEY_CURRENT_USER\Software\Wine\FileOpenAssociations]
      "Enable"="N"
    ''}
    wineserver -w
  '';

  # Stage 2: the winetricks verbs. Slowest stage by far (.NET 4.8 alone is
  # minutes) and the one most worth keeping out of later rebuilds.
  #
  # The verb list is upstream's, with two deliberate changes:
  #   - dotnet20 -> dotnet20sp1, because dotnet20's x64 half is only reachable
  #     via web.archive.org (see sources.nix).
  #   - win10 dropped; upstream sets win10 then immediately re-sets win11, and
  #     only the final value matters.
  verbs = [
    "atmlib"
    "gdiplus"
    "corefonts"
    "cjkfonts"
    "dotnet20sp1"
    "dotnet48"
  ]
  ++ lib.optional sources.hasMsxml4 "msxml4"
  ++ [
    "msxml6"
    "vcrun2022"
    "winhttp"
    "fontsmooth=rgb"
    "win11"
  ];

  stage2 =
    runCommand "fusion360-prefix-2-winetricks"
      {
        nativeBuildInputs = [
          wine
          winetricksPinned
          xvfb-run
        ];
      }
      ''
        ${wineEnv}
        ${copyPrev stage1}

        # Seed the winetricks cache so nothing reaches for the network.
        mkdir -p "$XDG_CACHE_HOME/winetricks"
        cp -RL ${sources.winetricksCache}/* "$XDG_CACHE_HOME/winetricks/"
        chmod -R +w "$XDG_CACHE_HOME/winetricks"

        # Several of these verbs put up a window even under -q.
        xvfb-run -a ${winetricks'} -q ${lib.escapeShellArgs verbs}
        wineserver -w
      '';

  # Stage 3: Fusion's own wine configuration — the DLL overrides and X11
  # settings from upstream's wine_autodesk_fusion_install(), plus WebView2.
  #
  # Split from stage 2 because these are the lines most likely to need
  # tweaking, and they cost seconds rather than the tens of minutes above.
  stage3 =
    runCommand "fusion360-prefix-3-config"
      {
        nativeBuildInputs = [
          wine
          xvfb-run
        ];
      }
      ''
        ${wineEnv}
        ${copyPrev stage2}

        ${wine'} regedit /S ${writeText "fusion-overrides.reg" ''
          Windows Registry Editor Version 5.00

          [HKEY_CURRENT_USER\Software\Wine\DllOverrides]
          "adpclientservice.exe"="native"
          "AdCefWebBrowser.exe"="builtin"
          "msvcp140"="native"
          "mfc140u"="native"
          "bcp47langs"=""

          [HKEY_CURRENT_USER\Software\Wine\X11 Driver]
          "Managed"="Y"
          "Decorated"="Y"
        ''}
        wineserver -w

        # WebView2 backs Fusion's sign-in view. It insists on a display, and
        # WebView2 109 refuses to install unless the prefix reports win7.
        cp ${sources.webview2} "$TMPDIR/webview2.exe"
        chmod +w "$TMPDIR/webview2.exe"
        ${wine'} winecfg -v win7
        xvfb-run -a timeout -k 2m 10m ${wine'} "$TMPDIR/webview2.exe" /silent /install || true
        ${wine'} winecfg -v win11

        # The Edge updater installs itself as a resident service. It has to be
        # disabled AND killed before waiting on wineserver: `wineserver -w` waits
        # for every process in the prefix to exit, and the updater never does, so
        # waiting first deadlocks the build.
        ${wine'} reg add 'HKLM\System\CurrentControlSet\Services\edgeupdate' /v Start /t REG_DWORD /d 4 /f || true
        ${wine'} reg add 'HKLM\System\CurrentControlSet\Services\edgeupdatem' /v Start /t REG_DWORD /d 4 /f || true
        ${wine'} reg add 'HKCU\Software\Wine\AppDefaults\msedgewebview2.exe' /v Version /t REG_SZ /d win7 /f || true
        ${wine'} taskkill /f /im MicrosoftEdgeUpdate.exe || true

        # -k rather than -w: nothing here needs to outlive the stage, and killing
        # the server cannot deadlock the way waiting can.
        wineserver -k || true
      '';
in
# Stage 4: Fusion itself.
runCommand "fusion360-prefix"
  {
    nativeBuildInputs = [
      wine
      xvfb-run
    ];
    passthru = { inherit stage1 stage2 stage3; };
  }
  ''
    ${wineEnv}
    ${copyPrev stage3}

    # Fusion ships files with non-ASCII names (e.g. an ngspice test fixture
    # called "стекло"). wine encodes Windows filenames onto the Unix
    # filesystem using the process locale, and nix build sandboxes run with no
    # LANG at all, so under the C locale that file cannot be created: the
    # streamer dies with WinError 2 and unwinds the entire install. This is
    # why the same installer succeeds when run by hand from a UTF-8 session
    # and fails in the sandbox.
    # The sandbox exports no USER, and `set -u` turns the bare reference below
    # into a build failure. wine names the profile directory after the build
    # user, so ask the system rather than hardcoding "nixbld".
    USER=$(id -un)
    export USER

    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
    export LOCALE_ARCHIVE=${glibcLocales}/lib/locale/locale-archive

    tar -xzf ${sources.fusionInstaller} -C "$TMPDIR"
    installer="$TMPDIR/FusionClientInstaller.exe"

    # Autodesk's installer leaves services running (adpclientservice and
    # friends), so an unbounded `wineserver -w` would deadlock exactly the way
    # the WebView2 updater deadlocked stage 3. Wait briefly for a clean exit,
    # then force the server down.
    settle() { timeout 120 wineserver -w || wineserver -k || true; }

    # Run twice, as upstream does: the first pass stages the payload and exits
    # before registration completes, the second finishes it. Both are bounded
    # because the installer does not reliably exit on its own, and a non-zero
    # status is the normal outcome rather than a failure.
    xvfb-run -a timeout -k 5m 35m ${wine'} "$installer" --quiet || true
    settle
    xvfb-run -a timeout -k 5m 10m ${wine'} "$installer" --quiet || true
    settle

    if ! find "$out" -name Fusion360.exe | grep -q .; then
      echo "=== streamer log ===" >&2
      find "$out" -name "autodesk.webdeploy.streamer.log" \
        -exec tail -n 60 {} \; >&2 || true
      echo "=== any Autodesk logs ===" >&2
      find "$out" -ipath "*Autodesk*" -name "*.log" >&2 || true
      echo "=== installer temp dirs ===" >&2
      ls -la "$out"/drive_c/users/*/AppData/Local/Temp/ >&2 2>/dev/null || true
      echo "=== /dev/shm ===" >&2
      ls -la /dev/shm >&2 2>/dev/null || echo "no /dev/shm" >&2
      echo "=== passwd ===" >&2
      cat /etc/passwd >&2 2>/dev/null || echo "no /etc/passwd" >&2
      echo "Fusion360.exe is missing: the client installer did not complete" >&2
      exit 1
    fi

    # Graphics defaults. Fusion reads whichever of these three paths its build
    # happens to use, so all three get the file.
    for d in \
      "AppData/Roaming/Autodesk/Neutron Platform/Options" \
      "AppData/Local/Autodesk/Neutron Platform/Options" \
      "Application Data/Autodesk/Neutron Platform/Options"
    do
      mkdir -p "$out/drive_c/users/$USER/$d"
      install -m 644 \
        ${installerSrc}/files/setup/resource/video_driver/DXVK/NMachineSpecificOptions.xml \
        "$out/drive_c/users/$USER/$d/NMachineSpecificOptions.xml"
    done

    # Nothing should reference $TMPDIR or the build user's home afterwards.
    rm -rf "$out/drive_c/windows/temp"/* || true
  ''
