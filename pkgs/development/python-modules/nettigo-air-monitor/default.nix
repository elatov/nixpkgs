{ lib
, aiohttp
, aioresponses
, buildPythonPackage
, dacite
, fetchFromGitHub
, pytest-asyncio
, pytest-error-for-skips
, pytestCheckHook
, pythonOlder
}:

buildPythonPackage rec {
  pname = "nettigo-air-monitor";
  version = "1.2.3";
  format = "setuptools";

  disabled = pythonOlder "3.8";

  src = fetchFromGitHub {
    owner = "bieniu";
    repo = pname;
    rev = version;
    sha256 = "sha256-aCDw3JwX8LVrJp3jYvuYQ3ycRHjSnWU0n1LdTjV08VA=";
  };

  propagatedBuildInputs = [
    aiohttp
    dacite
  ];

  checkInputs = [
    aioresponses
    pytest-asyncio
    pytest-error-for-skips
    pytestCheckHook
  ];

  postPatch = ''
    substituteInPlace setup.py \
      --replace "pytest-runner" ""
    substituteInPlace setup.cfg \
      --replace "--cov --cov-report term-missing " ""
  '';

  pythonImportsCheck = [
    "nettigo_air_monitor"
  ];

  meta = with lib; {
    description = "Python module to get air quality data from Nettigo Air Monitor devices";
    homepage = "https://github.com/bieniu/nettigo-air-monitor";
    license = with licenses; [ asl20 ];
    maintainers = with maintainers; [ fab ];
  };
}
