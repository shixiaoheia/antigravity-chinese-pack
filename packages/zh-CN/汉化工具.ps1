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
    if ($manifest.format -ne 1 -or $manifest.version -ne '2.22.0') { throw '汉化包格式或版本不匹配。' }
    if (-not $AppPath) {
        $candidates = @((Join-Path $env:LOCALAPPDATA 'Programs\antigravity'), (Join-Path $env:ProgramFiles 'Antigravity'))
        if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'Antigravity' }
        $AppPath = $candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'resources\app.asar') } | Select-Object -First 1
        if (-not $AppPath) { $AppPath = Read-Host '未自动找到安装目录，请粘贴包含 Antigravity.exe 的文件夹路径' }
    }
    $AppPath = (Resolve-Path -LiteralPath ($AppPath.Trim('"'))).Path
    $target = Join-Path $AppPath 'resources\app.asar'
    $backup = Join-Path $AppPath 'resources\app.asar.agy-zh-CN-2.22.0.original'
    if (-not (Test-Path -LiteralPath (Join-Path $AppPath 'Antigravity.exe')) -or -not (Test-Path -LiteralPath $target)) {
        throw '所选文件夹不是 Antigravity 桌面程序安装目录。'
    }
    $currentHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Action -eq 'Install') {
        if ($currentHash -eq $manifest.patchedSha256) { Write-Host '已安装本汉化包，无需重复安装。'; exit 0 }
        $isCompatibleUpgrade = @($manifest.compatiblePreviousHashes) -contains $currentHash
        if ($currentHash -ne $manifest.baseSha256 -and -not $isCompatibleUpgrade) { throw '原文件与本汉化包适配的 2.22.0 构建不一致。为避免误覆盖，本次未修改文件。' }
        $baseSource = $target
        if ($isCompatibleUpgrade) {
            if (-not (Test-Path -LiteralPath $backup)) { throw '检测到上一版汉化，但未找到原版备份。请先找回安装时的原版备份，再升级。' }
            if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.baseSha256) { throw '原版备份与适配版本不一致，本次未升级。' }
            $baseSource = $backup
        }
        $patchFile = Join-Path $packageRoot 'patch.dat'
        if ((Get-FileHash -LiteralPath $patchFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.patchSha256) { throw '汉化补丁校验失败，请重新解压完整压缩包。' }
        $original = [System.IO.File]::ReadAllBytes($baseSource)
        $patch = [System.IO.File]::ReadAllBytes($patchFile)
        $stream = New-Object System.IO.MemoryStream
        try {
            foreach ($operation in $manifest.operations) {
                if ($operation.type -eq 'copy') { $sourceBytes = $original }
                elseif ($operation.type -eq 'insert') { $sourceBytes = $patch }
                else { throw '补丁中包含未知操作。' }
                $offset = [int]$operation.offset
                $length = [int]$operation.length
                if ($offset -lt 0 -or $length -lt 0 -or ([long]$offset + $length) -gt $sourceBytes.Length) { throw '补丁范围校验失败。' }
                $stream.Write($sourceBytes, $offset, $length)
                if ($stream.Length -gt [int]$manifest.patchedSize) { throw '补丁输出大小异常。' }
            }
            $result = $stream.ToArray()
        } finally { $stream.Dispose() }
        $expectedHash = $manifest.patchedSha256
        if ($result.Length -ne [int]$manifest.patchedSize) { throw '重建后的文件大小不匹配。' }
    } else {
        if ($currentHash -eq $manifest.baseSha256) { Write-Host '当前已经是原版，无需还原。'; exit 0 }
        if ($currentHash -ne $manifest.patchedSha256 -and -not (@($manifest.compatiblePreviousHashes) -contains $currentHash)) { throw '当前文件已被更新或其他补丁修改，不能使用旧备份覆盖。' }
        if (-not (Test-Path -LiteralPath $backup)) { throw '未找到安装时创建的原版备份。' }
        if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.baseSha256) { throw '原版备份校验失败，不能还原。' }
        $result = [System.IO.File]::ReadAllBytes($backup)
        $expectedHash = $manifest.baseSha256
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $resultHash = ([System.BitConverter]::ToString($sha.ComputeHash($result))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    if ($resultHash -ne $expectedHash) { throw '重建文件的 SHA256 校验失败。' }
    if ($VerifyOnly) { Write-Host '验证通过：版本、补丁、重建文件均匹配；未修改安装目录。'; exit 0 }
    $appExecutable = Join-Path $AppPath 'Antigravity.exe'
    $runningTarget = Get-Process -Name 'Antigravity' -ErrorAction SilentlyContinue | Where-Object { -not $_.Path -or $_.Path -eq $appExecutable }
    if ($runningTarget) { throw '请先保存工作，并彻底退出 Antigravity 后再运行。安装器不会强制关闭程序。' }
    if ($Action -eq 'Install') {
        if (Test-Path -LiteralPath $backup) {
            if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.baseSha256) { throw '已有同名备份与原版不一致，本次未覆盖备份。' }
        } else {
            Copy-Item -LiteralPath $target -Destination $backup
            if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.baseSha256) { throw '备份校验失败，未修改原文件。' }
        }
    }
    $temporary = Join-Path (Split-Path -Parent $target) ('app.asar.agy-zh-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $previous = $temporary + '.previous'
    try {
        [System.IO.File]::WriteAllBytes($temporary, $result)
        if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) { throw '写入后的临时文件校验失败。' }
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $currentHash) { throw '安装文件刚刚发生变化，本次未覆盖，请重试。' }
        [System.IO.File]::Replace($temporary, $target, $previous)
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) {
            [System.IO.File]::Copy($previous, $target, $true)
            throw '最终文件校验失败，已恢复安装前文件。'
        }
        Remove-Item -LiteralPath $previous
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) { throw '最终文件校验失败，请使用原版备份恢复。' }
    if ($Action -eq 'Install') { Write-Host '汉化安装成功。现在可以启动 Antigravity。原版备份已保存在 resources 目录。' }
    else { Write-Host '已恢复原版英文界面，原版备份保留。' }
    exit 0
} catch {
    Write-Host ('操作未完成：' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
