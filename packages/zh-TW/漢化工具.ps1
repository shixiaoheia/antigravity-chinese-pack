[CmdletBinding()]
param(
    [ValidateSet('Install','Restore')][string]$Action = 'Install',
    [string]$AppPath,
    [switch]$VerifyOnly
)
$ErrorActionPreference = 'Stop'
try {
    $packageRoot = $PSScriptRoot
    $manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.format -ne 1 -or $manifest.version -ne '2.22.0') { throw '漢化包格式或版本不匹配。' }
    if (-not $AppPath) {
        $candidates = @((Join-Path $env:LOCALAPPDATA 'Programs\antigravity'), (Join-Path $env:ProgramFiles 'Antigravity'))
        if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'Antigravity' }
        $AppPath = $candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'resources\app.asar') } | Select-Object -First 1
        if (-not $AppPath) { $AppPath = Read-Host '未自動找到安裝目錄，請貼上包含 Antigravity.exe 的資料夾路徑' }
    }
    $AppPath = (Resolve-Path -LiteralPath ($AppPath.Trim('"'))).Path
    $target = Join-Path $AppPath 'resources\app.asar'
    $backup = Join-Path $AppPath 'resources\app.asar.agy-zh-CN-2.22.0.original'
    if (-not (Test-Path -LiteralPath (Join-Path $AppPath 'Antigravity.exe')) -or -not (Test-Path -LiteralPath $target)) {
        throw '所選資料夾不是 Antigravity 桌面程式安裝目錄。'
    }
    $currentHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Action -eq 'Install') {
        if ($currentHash -eq $manifest.patchedSha256) { Write-Host '已安裝本漢化包，無需重複安裝。'; exit 0 }
        $isCompatibleUpgrade = @($manifest.compatiblePreviousHashes) -contains $currentHash
        if ($currentHash -ne $manifest.baseSha256 -and -not $isCompatibleUpgrade) { throw '原檔案與本漢化包適配的 2.22.0 構建不一致。為避免誤覆蓋，本次未修改檔案。' }
        $baseSource = $target
        if ($isCompatibleUpgrade) {
            if (-not (Test-Path -LiteralPath $backup)) { throw '檢測到上一版漢化，但未找到原版備份。請先找回安裝時的原版備份，再升級。' }
            if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.baseSha256) { throw '原版備份與適配版本不一致，本次未升級。' }
            $baseSource = $backup
        }
        $patchFile = Join-Path $packageRoot 'patch.dat'
        if ((Get-FileHash -LiteralPath $patchFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.patchSha256) { throw '漢化補丁校驗失敗，請重新解壓完整壓縮包。' }
        $original = [System.IO.File]::ReadAllBytes($baseSource)
        $patch = [System.IO.File]::ReadAllBytes($patchFile)
        $stream = New-Object System.IO.MemoryStream
        try {
            foreach ($operation in $manifest.operations) {
                if ($operation.type -eq 'copy') { $sourceBytes = $original }
                elseif ($operation.type -eq 'insert') { $sourceBytes = $patch }
                else { throw '補丁中包含未知操作。' }
                $offset = [int]$operation.offset
                $length = [int]$operation.length
                if ($offset -lt 0 -or $length -lt 0 -or ([long]$offset + $length) -gt $sourceBytes.Length) { throw '補丁範圍校驗失敗。' }
                $stream.Write($sourceBytes, $offset, $length)
                if ($stream.Length -gt [int]$manifest.patchedSize) { throw '補丁輸出大小異常。' }
            }
            $result = $stream.ToArray()
        } finally { $stream.Dispose() }
        $expectedHash = $manifest.patchedSha256
        if ($result.Length -ne [int]$manifest.patchedSize) { throw '重建後的檔案大小不匹配。' }
    } else {
        if ($currentHash -eq $manifest.baseSha256) { Write-Host '目前已經是原版，無需還原。'; exit 0 }
        if ($currentHash -ne $manifest.patchedSha256 -and -not (@($manifest.compatiblePreviousHashes) -contains $currentHash)) { throw '目前檔案已被更新或其他補丁修改，不能使用舊備份覆蓋。' }
        if (-not (Test-Path -LiteralPath $backup)) { throw '未找到安裝時建立的原版備份。' }
        if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.baseSha256) { throw '原版備份校驗失敗，不能還原。' }
        $result = [System.IO.File]::ReadAllBytes($backup)
        $expectedHash = $manifest.baseSha256
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $resultHash = ([System.BitConverter]::ToString($sha.ComputeHash($result))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    if ($resultHash -ne $expectedHash) { throw '重建檔案的 SHA256 校驗失敗。' }
    if ($VerifyOnly) { Write-Host '驗證透過：版本、補丁、重建檔案均匹配；未修改安裝目錄。'; exit 0 }
    $appExecutable = Join-Path $AppPath 'Antigravity.exe'
    $runningTarget = Get-Process -Name 'Antigravity' -ErrorAction SilentlyContinue | Where-Object { -not $_.Path -or $_.Path -eq $appExecutable }
    if ($runningTarget) { throw '請先儲存工作，並徹底退出 Antigravity 後再執行。安裝器不會強制關閉程式。' }
    if ($Action -eq 'Install') {
        if (Test-Path -LiteralPath $backup) {
            if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.baseSha256) { throw '已有同名備份與原版不一致，本次未覆蓋備份。' }
        } else {
            Copy-Item -LiteralPath $target -Destination $backup
            if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.baseSha256) { throw '備份校驗失敗，未修改原檔案。' }
        }
    }
    $temporary = Join-Path (Split-Path -Parent $target) ('app.asar.agy-zh-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $previous = $temporary + '.previous'
    try {
        [System.IO.File]::WriteAllBytes($temporary, $result)
        if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) { throw '寫入後的臨時檔案校驗失敗。' }
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $currentHash) { throw '安裝檔案剛剛發生變化，本次未覆蓋，請重試。' }
        [System.IO.File]::Replace($temporary, $target, $previous)
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) {
            [System.IO.File]::Copy($previous, $target, $true)
            throw '最終檔案校驗失敗，已恢復安裝前檔案。'
        }
        Remove-Item -LiteralPath $previous
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) { throw '最終檔案校驗失敗，請使用原版備份恢復。' }
    if ($Action -eq 'Install') { Write-Host '漢化安裝成功。現在可以啟動 Antigravity。原版備份已儲存在 resources 目錄。' }
    else { Write-Host '已恢復原版英文介面，原版備份保留。' }
    exit 0
} catch {
    Write-Host ('操作未完成：' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
