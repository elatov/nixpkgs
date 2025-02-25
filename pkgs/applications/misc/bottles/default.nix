{ lib, fetchFromGitHub
, meson, ninja, pkg-config, wrapGAppsHook
, desktop-file-utils, gsettings-desktop-schemas, libnotify, libhandy, webkitgtk
, python3Packages, gettext
, appstream-glib, gdk-pixbuf, glib, gobject-introspection, gspell, gtk3, gtksourceview4, gnome
, steam, xdg-utils, pciutils, cabextract, wineWowPackages
, freetype, p7zip, gamemode, mangohud
, bottlesExtraLibraries ? pkgs: [ ] # extra packages to add to steam.run multiPkgs
, bottlesExtraPkgs ? pkgs: [ ] # extra packages to add to steam.run targetPkgs
}:

let
  steam-run = (steam.override {
    # required by wine runner `caffe`
    extraLibraries = pkgs: with pkgs; [ libunwind libusb1 gnutls ]
      ++ bottlesExtraLibraries pkgs;
    extraPkgs = pkgs: [ ]
      ++ bottlesExtraPkgs pkgs;
  }).run;
in
python3Packages.buildPythonApplication rec {
  pname = "bottles";
  version = "2022.5.2-trento";

  src = fetchFromGitHub {
    owner = "bottlesdevs";
    repo = pname;
    rev = version;
    sha256 = "sha256-9auQm8rmySjPQmhueGMRj4DsQiKhCGtE97byc/h+v84=";
  };

  postPatch = ''
    chmod +x build-aux/meson/postinstall.py
    patchShebangs build-aux/meson/postinstall.py

    substituteInPlace src/backend/wine/winecommand.py \
      --replace \
        'self.__get_runner()' \
        '(lambda r: (f"${steam-run}/bin/steam-run {r}", r)[r == "wine" or r == "wine64"])(self.__get_runner())'
  '';

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    wrapGAppsHook
    gettext
    appstream-glib
    desktop-file-utils
  ];

  buildInputs = [
    gdk-pixbuf
    glib
    gobject-introspection
    gsettings-desktop-schemas
    gspell
    gtk3
    gtksourceview4
    libhandy
    libnotify
    webkitgtk
    gnome.adwaita-icon-theme
  ];

  propagatedBuildInputs = with python3Packages; [
    pyyaml
    pytoml
    requests
    pycairo
    pygobject3
    lxml
    dbus-python
    gst-python
    liblarch
    patool
    markdown
  ] ++ [
    steam-run
    xdg-utils
    pciutils
    cabextract
    wineWowPackages.minimal
    freetype
    p7zip
    gamemode # programs.gamemode.enable
    mangohud
  ];

  format = "other";
  strictDeps = false; # broken with gobject-introspection setup hook, see https://github.com/NixOS/nixpkgs/issues/56943
  dontWrapGApps = true; # prevent double wrapping

  preFixup = ''
    makeWrapperArgs+=("''${gappsWrapperArgs[@]}")
  '';

  meta = with lib; {
    description = "An easy-to-use wineprefix manager";
    homepage = "https://usebottles.com/";
    downloadPage = "https://github.com/bottlesdevs/Bottles/releases";
    license = licenses.gpl3Only;
    maintainers = with maintainers; [ bloomvdomino psydvl shamilton ];
    platforms = platforms.linux;
  };
}
