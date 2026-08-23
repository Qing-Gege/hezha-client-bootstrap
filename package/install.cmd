@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "SOURCE=%~dp0"
set "TARGET=%LOCALAPPDATA%\LegalSkills\runtime\1.0.0"
set "BASE=%LOCALAPPDATA%\LegalSkills"
set "BIN=%BASE%\bin"
set "STATE=%BASE%\environment.json"
set "STATE_TMP=%STATE%.tmp.%RANDOM%"
set "ENV_BIN=%TARGET%\runtime\Library\bin"
set "ENV_TESSDATA=%TARGET%\runtime\Library\share\tessdata"

if not defined LOCALAPPDATA (
  echo Document runtime install failed: LOCALAPPDATA is not available 1>&2
  exit /b 1
)

if not exist "%TARGET%" mkdir "%TARGET%" >nul 2>&1
if errorlevel 1 (
  echo Document runtime install failed: could not create runtime directory 1>&2
  exit /b 1
)
if not exist "%BIN%" mkdir "%BIN%" >nul 2>&1
if errorlevel 1 (
  echo Document runtime install failed: could not create bin directory 1>&2
  exit /b 1
)

for %%F in (pixi.exe officecli.exe pixi.toml pixi.lock environment.tar pixi-unpack.exe package.json) do (
  if not exist "%SOURCE%%%F" (
    echo Document runtime install failed: missing package file %%F 1>&2
    exit /b 1
  )
  copy /Y "%SOURCE%%%F" "%TARGET%\" >nul
  if errorlevel 1 (
    echo Document runtime install failed: could not copy %%F 1>&2
    exit /b 1
  )
)

xcopy /Y /Q "%SOURCE%officecli.exe" "%BIN%\" >nul
if errorlevel 1 (
  echo Document runtime install failed: could not publish OfficeCLI 1>&2
  exit /b 1
)

if not exist "%TARGET%\runtime\Library\bin\tesseract.exe" (
  "%TARGET%\pixi-unpack.exe" --output-directory "%TARGET%" --env-name runtime --shell cmd "%TARGET%\environment.tar"
  if errorlevel 1 (
    echo Document runtime install failed: could not unpack the locked environment 1>&2
    exit /b 1
  )
)

call "%TARGET%\activate.bat" >nul 2>&1
if errorlevel 1 (
  echo Document runtime install failed: could not activate environment 1>&2
  exit /b 1
)
for %%T in (pdftotext pdftoppm pdfseparate pdfunite tesseract) do (
  if not exist "%ENV_BIN%\%%T.exe" (
    echo Document runtime install failed: %%T is unavailable 1>&2
    exit /b 1
  )
)
"%ENV_BIN%\pdftotext.exe" -v >nul 2>&1 || exit /b 1
"%ENV_BIN%\pdftoppm.exe" -v >nul 2>&1 || exit /b 1
"%ENV_BIN%\pdfseparate.exe" -v >nul 2>&1 || exit /b 1
"%ENV_BIN%\pdfunite.exe" -v >nul 2>&1 || exit /b 1
"%TARGET%\officecli.exe" --version >nul 2>&1 || exit /b 1
"%TARGET%\officecli.exe" help >nul 2>&1 || exit /b 1
for /f "delims=" %%V in ('"%TARGET%\officecli.exe" --version 2^>nul') do if not defined OFFICE_VERSION set "OFFICE_VERSION=%%V"
if not defined OFFICE_VERSION exit /b 1
"%ENV_BIN%\tesseract.exe" --version >nul 2>&1 || exit /b 1
for %%L in (eng chi_sim chi_tra osd) do (
  "%ENV_BIN%\tesseract.exe" --list-langs 2>nul | findstr /R /C:"^%%L$" >nul
  if errorlevel 1 (
    echo Document runtime install failed: OCR language %%L is missing 1>&2
    exit /b 1
  )
)

set "PDFTOTEXT=%ENV_BIN%\pdftotext.exe"
set "PDFTOPPM=%ENV_BIN%\pdftoppm.exe"
set "PDFSEPARATE=%ENV_BIN%\pdfseparate.exe"
set "PDFUNITE=%ENV_BIN%\pdfunite.exe"
set "TESSERACT=%ENV_BIN%\tesseract.exe"

set "JSON_TARGET=%TARGET:\=\\%"
set "JSON_BIN=%BIN:\=\\%"
set "JSON_OFFICE=%JSON_TARGET%\officecli.exe"
set "JSON_PDFTOTEXT=%PDFTOTEXT:\=\\%"
set "JSON_PDFTOPPM=%PDFTOPPM:\=\\%"
set "JSON_PDFSEPARATE=%PDFSEPARATE:\=\\%"
set "JSON_PDFUNITE=%PDFUNITE:\=\\%"
set "JSON_TESSERACT=%TESSERACT:\=\\%"

for /f "tokens=2,*" %%A in ('reg query "HKCU\Environment" /v Path 2^>nul ^| findstr /i /r "^[ ]*Path[ ]"') do set "USER_PATH=%%B"
if not defined USER_PATH set "USER_PATH="
echo ;%USER_PATH%; | find /I ";%BIN%;" >nul
if errorlevel 1 (
  if defined USER_PATH (
    reg add "HKCU\Environment" /v Path /t REG_EXPAND_SZ /d "%BIN%;%USER_PATH%" /f >nul
  ) else (
    reg add "HKCU\Environment" /v Path /t REG_EXPAND_SZ /d "%BIN%" /f >nul
  )
  if errorlevel 1 exit /b 1
)

>"%STATE_TMP%" echo {
>>"%STATE_TMP%" echo   "schema_version": 1,
>>"%STATE_TMP%" echo   "status": "ready",
>>"%STATE_TMP%" echo   "runtime_version": "1.0.0",
>>"%STATE_TMP%" echo   "runtime_mode": "portable-package",
>>"%STATE_TMP%" echo   "os": "windows",
>>"%STATE_TMP%" echo   "arch": "x64",
>>"%STATE_TMP%" echo   "verified_at": "package",
>>"%STATE_TMP%" echo   "pixi_path": "%JSON_TARGET%\\pixi.exe",
>>"%STATE_TMP%" echo   "manifest_path": "%JSON_TARGET%\\pixi.toml",
>>"%STATE_TMP%" echo   "officecli_path": "%JSON_OFFICE%",
>>"%STATE_TMP%" echo   "officecli_command_path": "%JSON_BIN%\\officecli.exe",
>>"%STATE_TMP%" echo   "path_entry": "%JSON_BIN%",
>>"%STATE_TMP%" echo   "commands": {
>>"%STATE_TMP%" echo     "officecli": ["%JSON_OFFICE%"],
>>"%STATE_TMP%" echo     "pdftotext": ["%JSON_PDFTOTEXT%"],
>>"%STATE_TMP%" echo     "pdftoppm": ["%JSON_PDFTOPPM%"],
>>"%STATE_TMP%" echo     "pdfseparate": ["%JSON_PDFSEPARATE%"],
>>"%STATE_TMP%" echo     "pdfunite": ["%JSON_PDFUNITE%"],
>>"%STATE_TMP%" echo     "tesseract": ["%JSON_TESSERACT%"]
>>"%STATE_TMP%" echo   },
>>"%STATE_TMP%" echo   "versions": {"officecli": "%OFFICE_VERSION%", "poppler": "26.07.0", "tesseract": "5.5.3"},
>>"%STATE_TMP%" echo   "ocr_languages": ["eng", "chi_sim", "chi_tra", "osd"]
>>"%STATE_TMP%" echo }

move /Y "%STATE_TMP%" "%STATE%" >nul
if errorlevel 1 exit /b 1

echo Document runtime ready
exit /b 0
