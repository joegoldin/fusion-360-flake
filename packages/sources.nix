# Every byte the prefix build needs, pinned.
#
# The nix build sandbox has no network, so a build-time wine prefix means each
# winetricks payload has to be in the store before winetricks runs. winetricks
# publishes the sha256 it verifies for every download, so these hashes are
# taken from the winetricks script itself rather than guessed — see
# `load_<verb>` in the winetricks source.
#
# Layout matches what winetricks expects to find in its cache:
# $XDG_CACHE_HOME/winetricks/<verb>/<filename>. Seeding that directory is what
# lets `winetricks -q` run offline.
{
  lib,
  fetchurl,
  linkFarm,
  # Off by default because the payload has no reachable source: Microsoft 404s
  # msxml.msi and winetricks' only fallback is web.archive.org, which cannot be
  # relied on to be up at build time. Flip this on if the Wayback Machine is
  # reachable or you have the file in your store; the prefix builds fine
  # without it, and msxml6 (pinned unconditionally) covers Fusion's XML needs.
  withMsxml4 ? false,
}:
let
  # sha256 values are winetricks' own, in the hex form it prints them.
  p = dir: name: urls: sha256: {
    name = "${dir}/${name}";
    path = fetchurl { inherit urls sha256 name; };
  };

  payloads = [
    # atmlib and winhttp are both extracted out of the Windows 2000 SP4
    # package (helper_win2ksp4).
    (p "win2ksp4" "W2KSP4_EN.EXE" [
      "http://x3270.bgp.nu/download/specials/W2KSP4_EN.EXE"
    ] "167bb78d4adc957cc39fb4902517e1f32b1e62092353be5f8fb9ee647642de7e")

    # gdiplus comes out of Windows 7 SP1 (helper_win7sp1{,_x64}). These two
    # are the bulk of the closure: ~1.4GB between them.
    (p "win7sp1" "windows6.1-KB976932-X86.exe" [
      "http://download.windowsupdate.com/msdownload/update/software/svpk/2011/02/windows6.1-kb976932-x86_c3516bc5c9e69fee6d9ac4f981f5b95977a8a2fa.exe"
    ] "e5449839955a22fc4dd596291aff1433b998f9797e1c784232226aba1f8abd97")
    (p "win7sp1" "windows6.1-KB976932-X64.exe" [
      "http://download.windowsupdate.com/msdownload/update/software/svpk/2011/02/windows6.1-kb976932-x64_74865ef2562006e51d7f9333b4a8d45b7a749dab.exe"
    ] "f4d1d418d91b1619688a482680ee032ffd2b65e420c6d2eaecf8aa3762aa64c8")

    # dotnet20sp1 rather than upstream's dotnet20: on a win64 prefix it needs
    # only NetFx20SP1_x64.exe, which is still served directly by Microsoft,
    # whereas dotnet20's x64 half (NetFx64.exe) is 404 at the source and only
    # survives on web.archive.org. Same .NET 2.0 runtime, live URL.
    (p "dotnet20sp1" "NetFx20SP1_x64.exe" [
      "https://download.microsoft.com/download/9/8/6/98610406-c2b7-45a4-bdc3-9db1b1c5f7e2/NetFx20SP1_x64.exe"
    ] "1731e53de5f48baae0963677257660df1329549e81c48b4d7db7f7f3f2329aab")

    (p "dotnet40" "dotNetFx40_Full_x86_x64.exe" [
      "https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe"
    ] "65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f")
    (p "dotnet48" "ndp48-x86-x64-allos-enu.exe" [
      "https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe"
    ] "95889d6de3f2070c07790ad6cf2000d33d9a1bdfc6a381725ab82ab1c314fd53")

    (p "msxml6" "msxml6-KB2957482-enu-amd64.exe" [
      "https://download.microsoft.com/download/2/7/7/277681BE-4048-4A58-ABBA-259C465B1699/msxml6-KB2957482-enu-amd64.exe"
    ] "260cd870851ffc3c6d10b71691f134e20d8d03ac26073bb36951eacb7aa85897")

    (p "vcrun2022" "vc_redist.x86.exe" [
      "https://aka.ms/vs/17/release/vc_redist.x86.exe"
    ] "0c09f2611660441084ce0df425c51c11e147e6447963c3690f97e0b25c55ed64")
    (p "vcrun2022" "vc_redist.x64.exe" [
      "https://aka.ms/vs/17/release/vc_redist.x64.exe"
    ] "cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b")

    # cjkfonts expands to fakechinese/fakejapanese/fakekorean/unifont, which
    # between them need just these two.
    (p "sourcehansans" "SourceHanSans.ttc.zip" [
      "https://github.com/adobe-fonts/source-han-sans/releases/download/2.004R/SourceHanSans.ttc.zip"
    ] "6f59118a9adda5a7fe4e9e6bb538309f7e1d3c5411f9a9d32af32a79501b7e4f")
    (p "unifont" "unifont-13.0.06.ttf" [
      "https://unifoundry.com/pub/unifont/unifont-13.0.06/font-builds/unifont-13.0.06.ttf"
    ] "d73c0425811ffd366b0d1973e9338bac26fe7cf085760a12e10c61241915e742")
  ]
  ++ lib.optionals withMsxml4 [
    # The only payload with no live source: Microsoft 404s it and winetricks
    # falls back to the Wayback Machine. Set withMsxml4 = false to build
    # without it if archive.org is unreachable.
    (p "msxml4" "msxml.msi" [
      "https://web.archive.org/web/20210506101448/http://download.microsoft.com/download/A/2/D/A2D8587D-0027-4217-9DAD-38AFDB0A177E/msxml.msi"
      "http://download.microsoft.com/download/A/2/D/A2D8587D-0027-4217-9DAD-38AFDB0A177E/msxml.msi"
    ] "47c2ae679c37815da9267c81fc3777de900ad2551c11c19c2840938b346d70bb")
  ]
  ++
    map
      (f: p "corefonts" f.name [ "https://github.com/pushcx/corefonts/raw/master/${f.name}" ] f.sha256)
      [
        {
          name = "andale32.exe";
          sha256 = "0524fe42951adc3a7eb870e32f0920313c71f170c859b5f770d82b4ee111e970";
        }
        {
          name = "arial32.exe";
          sha256 = "85297a4d146e9c87ac6f74822734bdee5f4b2a722d7eaa584b7f2cbf76f478f6";
        }
        {
          name = "arialb32.exe";
          sha256 = "a425f0ffb6a1a5ede5b979ed6177f4f4f4fdef6ae7c302a7b7720ef332fec0a8";
        }
        {
          name = "comic32.exe";
          sha256 = "9c6df3feefde26d4e41d4a4fe5db2a89f9123a772594d7f59afd062625cd204e";
        }
        {
          name = "courie32.exe";
          sha256 = "bb511d861655dde879ae552eb86b134d6fae67cb58502e6ff73ec5d9151f3384";
        }
        {
          name = "georgi32.exe";
          sha256 = "2c2c7dcda6606ea5cf08918fb7cd3f3359e9e84338dc690013f20cd42e930301";
        }
        {
          name = "impact32.exe";
          sha256 = "6061ef3b7401d9642f5dfdb5f2b376aa14663f6275e60a51207ad4facf2fccfb";
        }
        {
          name = "times32.exe";
          sha256 = "db56595ec6ef5d3de5c24994f001f03b2a13e37cee27bc25c58f6f43e8f807ab";
        }
        {
          name = "trebuc32.exe";
          sha256 = "5a690d9bb8510be1b8b4fe49f1f2319651fe51bbe54775ddddd8ef0bd07fdac9";
        }
        {
          name = "verdan32.exe";
          sha256 = "c1cb61255e363166794e47664e2f21af8e3a26cb6346eb8d2ae2fa85dd5aad96";
        }
        {
          name = "webdin32.exe";
          sha256 = "64595b5abc1080fba8610c5c34fab5863408e806aafe84653ca8575bed17d75a";
        }
      ];
in
{
  inherit payloads;

  # prefix.nix drops the msxml4 verb when its payload is not pinned; winetricks
  # would otherwise try to download it and fail in the sandbox.
  hasMsxml4 = withMsxml4;

  winetricksCache = linkFarm "fusion360-winetricks-cache" payloads;

  # Pinned rather than the rolling "Fusion Admin Install.exe": a build-time
  # install has to hash its input. The tarball holds exactly one file,
  # FusionClientInstaller.exe (1.4GB, dated 2026-03-24), which is the same
  # artifact the rolling URL serves, frozen at a known build.
  fusionInstaller = fetchurl {
    url = "https://github.com/Lolig4/Autodesk-Fusion-360-for-Linux/releases/download/Fusion_24.03.2026/Fusion_24.03.2026.tar.gz";
    hash = "sha256-E3S/418dio2uBtd0RSZI2nFc7GqY/9FgulxCT9pHkfg=";
  };

  webview2 = fetchurl {
    url = "https://github.com/aedancullen/webview2-evergreen-standalone-installer-archive/releases/download/109.0.1518.78/MicrosoftEdgeWebView2RuntimeInstallerX64.exe";
    hash = "sha256-8sxJhj4iFALUZk2fqUSkfyJUPaLcs2NDjD5Zh4m5/Vs=";
  };
}
