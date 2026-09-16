param(
    [Parameter(Mandatory = $true)][ValidateRange(2, 2100000000)][int]$VersionCode,
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$VersionName
)
$ErrorActionPreference = 'Stop'
$projectPath = Split-Path $PSScriptRoot -Parent
Push-Location $projectPath
try {
    $distributionPath = Join-Path $projectPath 'build/android-updates'
    $metadataDirectory = Join-Path $projectPath 'build/android-update-metadata'
    $metadataPath = Join-Path $metadataDirectory 'latest.json'
    if (Test-Path -LiteralPath $metadataPath) {
        $previous = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        if ($VersionCode -le $previous.versionCode) { throw 'VersionCode must exceed the previous prepared update.' }
    }
    & flutter build apk --release --build-number $VersionCode --build-name $VersionName --dart-define=EMPLOYEE_API_URL=https://attendance-employee-api.lynje.workers.dev/employee/api
    if ($LASTEXITCODE -ne 0) { throw 'APK build failed.' }

    $localSettings = Get-Content android/local.properties
    $sdkLine = $localSettings | Where-Object { $_ -match '^sdk.dir=' } | Select-Object -First 1
    $sdkPath = ($sdkLine -replace '^sdk.dir=', '').Replace('\\', '\').Replace('\:', ':')
    $buildTools = Get-ChildItem (Join-Path $sdkPath 'build-tools') -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (-not $buildTools) { throw 'Android build-tools not found.' }
    $apkPath = Join-Path $projectPath 'build/app/outputs/flutter-apk/app-release.apk'
    $certificate = & (Join-Path $buildTools.FullName 'apksigner.bat') verify --print-certs $apkPath
    if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed.' }
    $expectedCertificate = '96ddbf476eda6e9afac773f31a367e316e54304ea2584e87e2ae031d0037d4d3'
    if (-not ($certificate -match "SHA-256 digest: $expectedCertificate$")) {
        throw 'Certificate differs from the APK installed by employees. Do not distribute.'
    }
    $badging = & (Join-Path $buildTools.FullName 'aapt.exe') dump badging $apkPath
    if ($LASTEXITCODE -ne 0) { throw 'APK inspection failed.' }
    if (-not ($badging -match "^package: name='com.kbattendance.app' versionCode='$VersionCode' versionName='$VersionName' ")) {
        throw 'Unexpected APK package or version.'
    }
    if ($badging -match '^application-debuggable') { throw 'Expected an optimized, non-debuggable release build.' }
    $size = (Get-Item -LiteralPath $apkPath).Length
    if ($size -gt 200MB) { throw 'APK exceeds the updater size limit.' }

    New-Item -ItemType Directory -Force $distributionPath, $metadataDirectory | Out-Null
    $filename = "attendance-$VersionCode.apk"
    Copy-Item -LiteralPath $apkPath -Destination (Join-Path $distributionPath $filename)
    $metadata = [ordered]@{
        versionCode = $VersionCode
        versionName = $VersionName
        apkUrl = "https://github.com/lynje35/attendance-app-updates/releases/download/v$VersionName-$VersionCode/$filename"
        sha256 = (Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
        sizeBytes = $size
    }
    [IO.File]::WriteAllText($metadataPath, ($metadata | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Write-Output "Prepared and verified: $distributionPath"
    Write-Output 'Nothing has been uploaded. Upload the APK to its matching GitHub Release first.'
    Write-Output 'Then publish only the metadata with firebase.updates.json.'
} finally {
    Pop-Location
}
