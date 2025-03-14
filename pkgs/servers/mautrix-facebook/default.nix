{ enableSystemd ? stdenv.isLinux
, fetchFromGitHub
, lib
, python3
, stdenv
}:

python3.pkgs.buildPythonPackage rec {
  pname = "mautrix-facebook";
  version = "0.4.0";

  src = fetchFromGitHub {
    owner = "mautrix";
    repo = "facebook";
    rev = "v${version}";
    hash = "sha256-Yc8W8A11dnXrJdLtu/rJHTVlu2pEawXn5xuT8Ez+h9U=";
  };

  propagatedBuildInputs = with python3.pkgs; [
    CommonMark
    aiohttp
    asyncpg
    mautrix
    paho-mqtt
    pillow
    prometheus-client
    pycryptodome
    python-olm
    python-magic
    ruamel-yaml
    unpaddedbase64
    yarl
    zstandard
  ] ++ lib.optional enableSystemd systemd;

  postPatch = ''
    # Drop version limiting so that every dependency update doesn't break this package.
    sed -i -e 's/,<.*//' requirements.txt
  '';

  postInstall = ''
    mkdir -p $out/bin

    cat <<-END >$out/bin/mautrix-facebook
    #!/bin/sh
    PYTHONPATH="$PYTHONPATH" exec ${python3}/bin/python -m mautrix_facebook "\$@"
    END
    chmod +x $out/bin/mautrix-facebook
  '';

  checkPhase = ''
    $out/bin/mautrix-facebook --help
  '';

  meta = with lib; {
    homepage = "https://github.com/mautrix/facebook";
    description = "A Matrix-Facebook Messenger puppeting bridge";
    license = licenses.agpl3Plus;
    platforms = platforms.linux;
    maintainers = with maintainers; [ kevincox ];
  };
}
