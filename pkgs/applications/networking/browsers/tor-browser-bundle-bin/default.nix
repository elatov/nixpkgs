{ lib, stdenv
, fetchurl
, makeDesktopItem

# Common run-time dependencies
, zlib

# libxul run-time dependencies
, atk
, cairo
, dbus
, dbus-glib
, fontconfig
, freetype
, gdk-pixbuf
, glib
, gtk3
, libxcb
, libX11
, libXext
, libXrender
, libXt
, pango

, audioSupport ? mediaSupport
, pulseaudioSupport ? mediaSupport
, libpulseaudio
, apulse

# Media support (implies audio support)
, mediaSupport ? true
, ffmpeg

, gmp

# Wrapper runtime
, coreutils
, glibcLocales
, gnome
, runtimeShell
, shared-mime-info
, gsettings-desktop-schemas

# Hardening
, graphene-hardened-malloc
# Whether to use graphene-hardened-malloc
, useHardenedMalloc ? true

# Whether to disable multiprocess support
, disableContentSandbox ? false

# Extra preferences
, extraPrefs ? ""
}:

with lib;

let
  libPath = makeLibraryPath libPkgs;

  libPkgs = [
    atk
    cairo
    dbus
    dbus-glib
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    libxcb
    libX11
    libXext
    libXrender
    libXt
    pango
    stdenv.cc.cc
    stdenv.cc.libc
    zlib
  ]
  ++ optionals pulseaudioSupport [ libpulseaudio ]
  ++ optionals mediaSupport [
    ffmpeg
  ];

  # Library search path for the fte transport
  fteLibPath = makeLibraryPath [ stdenv.cc.cc gmp ];

  # Upstream source
  version = "11.0.10";

  lang = "en-US";

  srcs = {
    x86_64-linux = fetchurl {
      urls = [
        "https://dist.torproject.org/torbrowser/${version}/tor-browser-linux64-${version}_${lang}.tar.xz"
        "https://tor.eff.org/dist/torbrowser/${version}/tor-browser-linux64-${version}_${lang}.tar.xz"
        "https://tor.calyxinstitute.org/dist/torbrowser/${version}/tor-browser-linux64-${version}_${lang}.tar.xz"
      ];
      sha256 = "1j39v01bb97hkhkfvz7xyfmv6y0sjjcymvn3sa9ahz2av1xlrplp";
    };

    i686-linux = fetchurl {
      urls = [
        "https://dist.torproject.org/torbrowser/${version}/tor-browser-linux32-${version}_${lang}.tar.xz"
        "https://tor.eff.org/dist/torbrowser/${version}/tor-browser-linux32-${version}_${lang}.tar.xz"
        "https://tor.calyxinstitute.org/dist/torbrowser/${version}/tor-browser-linux32-${version}_${lang}.tar.xz"
      ];
      sha256 = "0vh913z828ncb8pwz461xx61ylxqp44rf9iah7n6lzda7hcw79r3";
    };
  };
in
stdenv.mkDerivation rec {
  pname = "tor-browser-bundle-bin";
  inherit version;

  src = srcs.${stdenv.hostPlatform.system} or (throw "unsupported system: ${stdenv.hostPlatform.system}");

  preferLocalBuild = true;
  allowSubstitutes = false;

  desktopItem = makeDesktopItem {
    name = "torbrowser";
    exec = "tor-browser";
    icon = "torbrowser";
    desktopName = "Tor Browser";
    genericName = "Web Browser";
    comment = meta.description;
    categories = [ "Network" "WebBrowser" "Security" ];
  };

  buildCommand = ''
    # For convenience ...
    TBB_IN_STORE=$out/share/tor-browser
    interp=$(< $NIX_CC/nix-support/dynamic-linker)

    # Unpack & enter
    mkdir -p "$TBB_IN_STORE"
    tar xf "$src" -C "$TBB_IN_STORE" --strip-components=2
    pushd "$TBB_IN_STORE"

    # Set ELF interpreter
    for exe in firefox.real TorBrowser/Tor/tor ; do
      echo "Setting ELF interpreter on $exe ..." >&2
      patchelf --set-interpreter "$interp" "$exe"
    done

    # firefox is a wrapper that checks for a more recent libstdc++ & appends it to the ld path
    mv firefox.real firefox

    # The final libPath.  Note, we could split this into firefoxLibPath
    # and torLibPath for accuracy, but this is more convenient ...
    libPath=${libPath}:$TBB_IN_STORE:$TBB_IN_STORE/TorBrowser/Tor

    # apulse uses a non-standard library path.  For now special-case it.
    ${optionalString (audioSupport && !pulseaudioSupport) ''
      libPath=${apulse}/lib/apulse:$libPath
    ''}

    # Fixup paths to pluggable transports.
    sed -i TorBrowser/Data/Tor/torrc-defaults \
        -e "s,./TorBrowser,$TBB_IN_STORE/TorBrowser,g"

    # Fixup obfs transport.  Work around patchelf failing to set
    # interpreter for pre-compiled Go binaries by invoking the interpreter
    # directly.
    sed -i TorBrowser/Data/Tor/torrc-defaults \
        -e "s|\(ClientTransportPlugin meek_lite,obfs2,obfs3,obfs4,scramblesuit\) exec|\1 exec $interp|"

    # Similarly fixup snowflake
    sed -i TorBrowser/Data/Tor/torrc-defaults \
        -e "s|\(ClientTransportPlugin snowflake\) exec|\1 exec $interp|"


    # Prepare for autoconfig.
    #
    # See https://developer.mozilla.org/en-US/Firefox/Enterprise_deployment
    cat >defaults/pref/autoconfig.js <<EOF
    //
    pref("general.config.filename", "mozilla.cfg");
    pref("general.config.obscure_value", 0);
    EOF

    # Hard-coded Firefox preferences.
    cat >mozilla.cfg <<EOF
    // First line must be a comment

    // Always update via Nixpkgs
    lockPref("app.update.auto", false);
    lockPref("app.update.enabled", false);
    lockPref("extensions.update.autoUpdateDefault", false);
    lockPref("extensions.update.enabled", false);
    lockPref("extensions.torbutton.versioncheck_enabled", false);

    // User should never change these.  Locking prevents these
    // values from being written to prefs.js, avoiding Store
    // path capture.
    lockPref("extensions.torlauncher.torrc-defaults_path", "$TBB_IN_STORE/TorBrowser/Data/Tor/torrc-defaults");
    lockPref("extensions.torlauncher.tor_path", "$TBB_IN_STORE/TorBrowser/Tor/tor");

    // Reset pref that captures store paths.
    clearPref("extensions.xpiState");

    // Stop obnoxious first-run redirection.
    lockPref("noscript.firstRunRedirection", false);

    // Insist on using IPC for communicating with Tor
    //
    // Defaults to creating \$TBB_HOME/TorBrowser/Data/Tor/{socks,control}.socket
    lockPref("extensions.torlauncher.control_port_use_ipc", true);
    lockPref("extensions.torlauncher.socks_port_use_ipc", true);

    // Optionally disable multiprocess support.  We always set this to ensure that
    // toggling the pref takes effect.
    lockPref("browser.tabs.remote.autostart.2", ${if disableContentSandbox then "false" else "true"});

    // Allow sandbox access to sound devices if using ALSA directly
    ${if (audioSupport && !pulseaudioSupport) then ''
      pref("security.sandbox.content.write_path_whitelist", "/dev/snd/");
    '' else ''
      clearPref("security.sandbox.content.write_path_whitelist");
    ''}

    ${optionalString (extraPrefs != "") ''
      ${extraPrefs}
    ''}
    EOF

    # Hard-code path to TBB fonts; see also FONTCONFIG_FILE in
    # the wrapper below.
    FONTCONFIG_FILE=$TBB_IN_STORE/TorBrowser/Data/fontconfig/fonts.conf
    sed -i "$FONTCONFIG_FILE" \
        -e "s,<dir>fonts</dir>,<dir>$TBB_IN_STORE/fonts</dir>,"

    # Preload extensions by moving into the runtime instead of storing under the
    # user's profile directory.
    # See https://support.mozilla.org/en-US/kb/deploying-firefox-with-extensions
    mkdir -p "$TBB_IN_STORE/distribution/extensions"
    mv "$TBB_IN_STORE/TorBrowser/Data/Browser/profile.default/extensions/"* \
      "$TBB_IN_STORE/distribution/extensions"

    # Hard-code paths to geoip data files.  TBB resolves the geoip files
    # relative to torrc-defaults_path but if we do not hard-code them
    # here, these paths end up being written to the torrc in the user's
    # state dir.
    cat >>TorBrowser/Data/Tor/torrc-defaults <<EOF
    GeoIPFile $TBB_IN_STORE/TorBrowser/Data/Tor/geoip
    GeoIPv6File $TBB_IN_STORE/TorBrowser/Data/Tor/geoip6
    EOF

    WRAPPER_LD_PRELOAD=${optionalString useHardenedMalloc
      "${graphene-hardened-malloc}/lib/libhardened_malloc.so"}

    WRAPPER_XDG_DATA_DIRS=${concatMapStringsSep ":" (x: "${x}/share") [
      gnome.adwaita-icon-theme
      shared-mime-info
    ]}
    WRAPPER_XDG_DATA_DIRS+=":"${concatMapStringsSep ":" (x: "${x}/share/gsettings-schemas/${x.name}") [
      glib
      gsettings-desktop-schemas
      gtk3
    ]};

    # Generate wrapper
    mkdir -p $out/bin
    cat > "$out/bin/tor-browser" << EOF
    #! ${runtimeShell}
    set -o errexit -o nounset

    PATH=${makeBinPath [ coreutils ]}
    export LC_ALL=C
    export LOCALE_ARCHIVE=${glibcLocales}/lib/locale/locale-archive

    # Enter local state directory.
    REAL_HOME=\$HOME
    TBB_HOME=\''${TBB_HOME:-''${XDG_DATA_HOME:-\$REAL_HOME/.local/share}/tor-browser}
    HOME=\$TBB_HOME

    mkdir -p "\$HOME"
    cd "\$HOME"

    # Initialize empty TBB local state directory hierarchy.  We
    # intentionally mirror the layout that TBB would see if executed from
    # the unpacked bundle dir.
    mkdir -p "\$HOME/TorBrowser" "\$HOME/TorBrowser/Data"

    # Initialize the Tor data directory.
    mkdir -p "\$HOME/TorBrowser/Data/Tor"

    # TBB will fail if ownership is too permissive
    chmod 0700 "\$HOME/TorBrowser/Data/Tor"

    # Initialize the browser profile state.  Note that the only data
    # copied from the Store payload is the initial bookmark file, which is
    # never updated once created.  All other files under user's profile
    # dir are generated by TBB.
    mkdir -p "\$HOME/TorBrowser/Data/Browser/profile.default"
    cp -u --no-preserve=mode,owner "$TBB_IN_STORE/TorBrowser/Data/Browser/profile.default/bookmarks.html" \
      "\$HOME/TorBrowser/Data/Browser/profile.default/bookmarks.html"

    # Clear some files if the last known store path is different from the new one
    : "\''${KNOWN_STORE_PATH:=\$HOME/known-store-path}"
    if ! [ "\$KNOWN_STORE_PATH" -ef $out ]; then
      echo "Cleanup files with outdated store references"
      ln -Tsf $out "\$KNOWN_STORE_PATH"

      # Clear out some files that tend to capture store references but are
      # easily generated by firefox at startup.
      rm -f "\$HOME/TorBrowser/Data/Browser/profile.default"/{addonStartup.json.lz4,compatibility.ini,extensions.ini,extensions.json}
      rm -f "\$HOME/TorBrowser/Data/Browser/profile.default"/startupCache/*
    fi

    # XDG
    : "\''${XDG_RUNTIME_DIR:=/run/user/\$(id -u)}"
    : "\''${XDG_CONFIG_HOME:=\$REAL_HOME/.config}"

    ${optionalString pulseaudioSupport ''
      # Figure out some envvars for pulseaudio
      : "\''${PULSE_SERVER:=\$XDG_RUNTIME_DIR/pulse/native}"
      : "\''${PULSE_COOKIE:=\$XDG_CONFIG_HOME/pulse/cookie}"
    ''}

    # Font cache files capture store paths; clear them out on the off
    # chance that TBB would continue using old font files.
    rm -rf "\$HOME/.cache/fontconfig"

    # Manually specify data paths (by default TB attempts to create these in the store)
    {
      echo "user_pref(\"extensions.torlauncher.toronionauthdir_path\", \"\$HOME/TorBrowser/Data/Tor/onion-auth\");"
      echo "user_pref(\"extensions.torlauncher.torrc_path\", \"\$HOME/TorBrowser/Data/Tor/torrc\");"
      echo "user_pref(\"extensions.torlauncher.tordatadir_path\", \"\$HOME/TorBrowser/Data/Tor\");"
    } >> "\$HOME/TorBrowser/Data/Browser/profile.default/prefs.js"

    # Lift-off
    #
    # XAUTHORITY and DISPLAY are required for TBB to work at all.
    #
    # DBUS_SESSION_BUS_ADDRESS is inherited to avoid auto-launch; to
    # prevent that, set it to an empty/invalid value prior to running
    # tor-browser.
    #
    # PULSE_SERVER is necessary for audio playback.
    #
    # Setting FONTCONFIG_FILE is required to make fontconfig read the TBB
    # fonts.conf; upstream uses FONTCONFIG_PATH, but FC_DEBUG=1024
    # indicates the system fonts.conf being used instead.
    #
    # XDG_DATA_DIRS is set to prevent searching system dirs (looking for .desktop & icons)
    exec env -i \
      LD_PRELOAD=$WRAPPER_LD_PRELOAD \
      \
      TZ=":" \
      TZDIR="\''${TZDIR:-}" \
      LOCALE_ARCHIVE="\$LOCALE_ARCHIVE" \
      \
      TMPDIR="\''${TMPDIR:-/tmp}" \
      HOME="\$HOME" \
      XAUTHORITY="\''${XAUTHORITY:-\$HOME/.Xauthority}" \
      DISPLAY="\$DISPLAY" \
      DBUS_SESSION_BUS_ADDRESS="\''${DBUS_SESSION_BUS_ADDRESS:-unix:path=\$XDG_RUNTIME_DIR/bus}" \\
      \
      XDG_DATA_HOME="\$HOME/.local/share" \
      XDG_DATA_DIRS="$WRAPPER_XDG_DATA_DIRS" \
      \
      PULSE_SERVER="\''${PULSE_SERVER:-}" \
      PULSE_COOKIE="\''${PULSE_COOKIE:-}" \
      \
      MOZ_ENABLE_WAYLAND=\$MOZ_ENABLE_WAYLAND \
      WAYLAND_DISPLAY="\$WAYLAND_DISPLAY" \
      XDG_RUNTIME_DIR="\$XDG_RUNTIME_DIR" \
      XCURSOR_PATH="\$XCURSOR_PATH" \
      \
      APULSE_PLAYBACK_DEVICE="\''${APULSE_PLAYBACK_DEVICE:-plug:dmix}" \
      \
      TOR_SKIP_LAUNCH="\''${TOR_SKIP_LAUNCH:-}" \
      TOR_CONTROL_PORT="\''${TOR_CONTROL_PORT:-}" \
      TOR_SOCKS_PORT="\''${TOR_SOCKS_PORT:-}" \
      \
      FONTCONFIG_FILE="$FONTCONFIG_FILE" \
      \
      LD_LIBRARY_PATH="$libPath" \
      \
      "$TBB_IN_STORE/firefox" \
        --class "Tor Browser" \
        -no-remote \
        -profile "\$HOME/TorBrowser/Data/Browser/profile.default" \
        "\''${@}"
    EOF
    chmod +x $out/bin/tor-browser

    # Easier access to docs
    mkdir -p $out/share/doc
    ln -s $TBB_IN_STORE/TorBrowser/Docs $out/share/doc/tor-browser

    # Install .desktop item
    mkdir -p $out/share/applications
    cp $desktopItem/share/applications"/"* $out/share/applications
    sed -i $out/share/applications/torbrowser.desktop \
        -e "s,Exec=.*,Exec=$out/bin/tor-browser," \
        -e "s,Icon=.*,Icon=tor-browser,"
    for i in 16 32 48 64 128; do
      mkdir -p $out/share/icons/hicolor/''${i}x''${i}/apps/
      ln -s $out/share/tor-browser/browser/chrome/icons/default/default$i.png $out/share/icons/hicolor/''${i}x''${i}/apps/tor-browser.png
    done

    # Check installed apps
    echo "Checking bundled Tor ..."
    LD_LIBRARY_PATH=$libPath $TBB_IN_STORE/TorBrowser/Tor/tor --version >/dev/null

    echo "Checking tor-browser wrapper ..."
    DISPLAY="" MOZ_ENABLE_WAYLAND="" WAYLAND_DISPLAY="" XAUTHORITY="" \
      XCURSOR_PATH="" XDG_RUNTIME_DIR="" XDG_SESSION_TYPE="" \
      DBUS_SESSION_BUS_ADDRESS="" TBB_HOME=$(mktemp -d) \
      $out/bin/tor-browser --version >/dev/null
  '';

  meta = with lib; {
    description = "Tor Browser Bundle built by torproject.org";
    longDescription = ''
      Tor Browser Bundle is a bundle of the Tor daemon, Tor Browser (heavily patched version of
      Firefox), several essential extensions for Tor Browser, and some tools that glue those
      together with a convenient UI.

      `tor-browser-bundle-bin` package is the official version built by torproject.org patched with
      `patchelf` to work under nix and with bundled scripts adapted to the read-only nature of
      the `/nix/store`.
    '';
    homepage = "https://www.torproject.org/";
    changelog = "https://gitweb.torproject.org/builders/tor-browser-build.git/plain/projects/tor-browser/Bundle-Data/Docs/ChangeLog.txt?h=maint-${version}";
    platforms = attrNames srcs;
    maintainers = with maintainers; [ offline matejc thoughtpolice joachifm hax404 KarlJoad ];
    mainProgram = "tor-browser";
    hydraPlatforms = [];
    # MPL2.0+, GPL+, &c.  While it's not entirely clear whether
    # the compound is "libre" in a strict sense (some components place certain
    # restrictions on redistribution), it's free enough for our purposes.
    license = licenses.free;
  };
}
