param(
    [ValidateSet('test', 'web-location-test', 'web', 'apk', 'release-apk', 'ui-apk', 'format', 'preview', 'map-preview')]
    [string]$Task = 'test'
)

$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path -Parent $PSScriptRoot
$previousDirectory = Get-Location
$aliasDrive = $null
$flutterCommand = 'C:\sr\Flutter\flutter\bin\flutter.bat'
try {
    # Flutter's generated test listener does not escape apostrophes in paths.
    # Use a temporary drive alias without changing or copying the project.
    foreach ($letter in @('Z', 'Y', 'X', 'W', 'V')) {
        if (-not (Test-Path -LiteralPath "${letter}:\")) {
            $aliasDrive = "${letter}:"
            break
        }
    }
    if (-not $aliasDrive) { throw 'No available drive letter for Flutter checks.' }
    & subst.exe $aliasDrive $projectDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Could not create temporary Flutter drive alias.' }
    Set-Location -LiteralPath "$aliasDrive\"
    switch ($Task) {
        'test' { & $flutterCommand test --no-pub }
        'web-location-test' { & $flutterCommand test --no-pub --platform chrome test/location_web.dart }
        'web' { & $flutterCommand build web --no-pub }
        'apk' { & $flutterCommand build apk --debug --no-pub }
        'release-apk' { & $flutterCommand build apk --release --no-pub }
        'ui-apk' { & $flutterCommand build apk --debug --no-pub -t tool/ui_preview.dart }
        'format' { & 'C:\sr\Flutter\flutter\bin\cache\dart-sdk\bin\dart.exe' format lib test }
        'preview' { & $flutterCommand test --no-pub --dart-define=CAPTURE_PREVIEWS=true test/mobile_preview_test.dart }
        'map-preview' { & $flutterCommand test --no-pub --dart-define=CAPTURE_ISLAND_MAPS=true test/island_map_test.dart }
    }
    $taskExit = $LASTEXITCODE
} finally {
    Set-Location -LiteralPath $previousDirectory.Path
    if ($aliasDrive) { & subst.exe $aliasDrive /D }
}
exit $taskExit
