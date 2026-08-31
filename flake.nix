{
  description = "Autodesk Fusion 360 Installer for Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    fusion360-installer-src = {
      url = "git+https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux.git";
      flake = false;
    };
    # Provides mkWindowsApp, which the `fusion360` package below builds on.
    erosanix = {
      url = "github:emmanuelrosa/erosanix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      fusion360-installer-src,
      erosanix,
    }:
    let
      systems = [ "x86_64-linux" ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = self.packages.${system}.fusion360;

          # mkWindowsApp-based package: the Wine prefix is described
          # declaratively and materialized into a cached layer on first launch.
          fusion360 = pkgs.callPackage ./fusion360.nix {
            inherit (erosanix.lib.${system}) mkWindowsApp;
            installerSrc = fusion360-installer-src;
            wine = pkgs.wineWow64Packages.stable;
          };

          # Original wrapper around upstream's shell installer. Kept so the
          # imperative `fusion install` path stays available.
          fusion360-installer = pkgs.callPackage ./package.nix {
            installerSrc = fusion360-installer-src;
          };
        }
      );

      apps = forAllSystems (system: {
        default = self.apps.${system}.fusion360;
        fusion360 = {
          type = "app";
          program = "${self.packages.${system}.fusion360}/bin/fusion360";
        };
        fusion = {
          type = "app";
          program = "${self.packages.${system}.fusion360-installer}/bin/fusion";
        };
      });
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            name = "fusion360-dev-shell";

            buildInputs = with pkgs; [
              gawk
              cabextract
              coreutils
              curl
              lsb-release
              mesa-demos
              p7zip
              polkit
              samba
              spacenavd
              wget
              samba
              xdg-utils
              bc
              xorg.xrandr
              mokutil
              gettext

              wineWowPackages.stable
              winetricks

              self.packages.${system}.fusion360-installer
            ];

            shellHook = ''
              echo "Fusion 360 development environment loaded"
              echo "All required dependencies are available"
              echo ""
              echo "The 'fusion' command is now available:"
              echo "  fusion          - Check if installed and run"
              echo "  fusion install  - Install Fusion 360"
              echo "  fusion --help   - Show all commands"
              echo ""
              export WINEPREFIX="$HOME/.autodesk_fusion/wineprefixes/default"
            '';
          };
        }
      );
    };
}
