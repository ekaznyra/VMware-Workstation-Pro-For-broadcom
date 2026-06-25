<#
.SYNOPSIS
    Tải VMware Workstation Pro từ mirror Archive.org (vĩnh viễn, không cần tài khoản)
    và tự động kiểm tra MD5.

.DESCRIPTION
    Script truy vấn metadata công khai của bộ sưu tập "vmwareworkstationarchive" trên
    Archive.org, cho phép liệt kê / chọn phiên bản, tải về (có resume) và đối chiếu MD5
    với metadata để đảm bảo file toàn vẹn.

.PARAMETER Version
    Phiên bản cần tải, ví dụ: "26H1", "25H2u1", "17.6.4". Nếu bỏ trống sẽ hiện menu chọn.

.PARAMETER Platform
    "Windows" (mặc định) hoặc "Linux".

.PARAMETER OutDir
    Thư mục lưu file. Mặc định: %USERPROFILE%\Downloads

.PARAMETER List
    Chỉ liệt kê các phiên bản có sẵn rồi thoát.

.EXAMPLE
    .\Get-VMwareWorkstation.ps1
    Hiện menu tương tác (Windows).

.EXAMPLE
    .\Get-VMwareWorkstation.ps1 -Version 26H1
    Tải thẳng bản 26H1 cho Windows và kiểm tra MD5.

.EXAMPLE
    .\Get-VMwareWorkstation.ps1 -Platform Linux -List
    Liệt kê các bản Linux.
#>
[CmdletBinding()]
param(
    [string]$Version,
    [ValidateSet('Windows', 'Linux')]
    [string]$Platform = 'Windows',
    [string]$OutDir = (Join-Path $env:USERPROFILE 'Downloads'),
    [switch]$List
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Item        = 'vmwareworkstationarchive'
$MetadataUrl = "https://archive.org/metadata/$Item"
$DownloadBase = "https://archive.org/download/$Item"

function Get-WorkstationCatalog {
    Write-Host 'Đang lấy danh sách từ Archive.org...' -ForegroundColor DarkGray
    $meta = Invoke-RestMethod -Uri $MetadataUrl -TimeoutSec 60

    $ext = if ($Platform -eq 'Windows') { '\.exe$' } else { '\.bundle$' }

    $catalog = foreach ($f in $meta.files) {
        if ($f.name -notmatch $ext) { continue }
        if ($f.name -notmatch 'orkstation') { continue }            # bỏ qua Fusion/Player
        # Bản Linux nằm trong thư mục Linux/... ; bản Windows thì không.
        $isLinuxPath = $f.name -match '(^|/)Linux/'
        if ($Platform -eq 'Linux' -and -not $isLinuxPath) { continue }
        if ($Platform -eq 'Windows' -and $isLinuxPath) { continue }

        $leaf = Split-Path $f.name -Leaf
        $ver =
            if     ($leaf -match '-(\d{2}H\d(?:u\d)?)-')      { $matches[1] }   # 26H1, 25H2u1
            elseif ($leaf -match 'full-(\d+\.\d+\.\d+)-')     { $matches[1] }   # 17.6.4
            elseif ($leaf -match '-(\d+\.\d+\.\d+)-')         { $matches[1] }
            else                                              { $leaf }

        [PSCustomObject]@{
            Version  = $ver
            Platform = $Platform
            FileName = $leaf
            Path     = $f.name
            Md5      = $f.md5
            SizeMB   = if ($f.size) { [math]::Round([long]$f.size / 1MB, 2) } else { $null }
        }
    }
    # Sắp xếp mới nhất lên đầu: H-versions (26H1, 25H2...) trước, rồi semver giảm dần.
    $catalog | Sort-Object `
        @{ Expression = { if ($_.Version -match '^\d{2}H\d') { [version]'999.0.0' }
                          else { try { [version]$_.Version } catch { [version]'0.0.0' } } }; Descending = $true }, `
        @{ Expression = { $_.Version }; Descending = $true }
}

function Invoke-Download {
    param([Parameter(Mandatory)] $Entry)

    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $url     = "$DownloadBase/$($Entry.Path)"
    $outPath = Join-Path $OutDir $Entry.FileName

    Write-Host ''
    Write-Host "Phiên bản : $($Entry.Version) ($($Entry.Platform))" -ForegroundColor Cyan
    Write-Host "File      : $($Entry.FileName)  [$($Entry.SizeMB) MB]" -ForegroundColor Cyan
    Write-Host "Nguồn     : $url" -ForegroundColor Gray
    Write-Host "Lưu vào   : $outPath" -ForegroundColor Gray
    Write-Host ''

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source --location --fail --progress-bar --continue-at - --output $outPath $url
        if ($LASTEXITCODE -ne 0) { throw "curl thất bại (exit $LASTEXITCODE)" }
    }
    else {
        Write-Host 'Không tìm thấy curl.exe — dùng Invoke-WebRequest (không có thanh tiến trình resume).' -ForegroundColor Yellow
        Invoke-WebRequest -Uri $url -OutFile $outPath -TimeoutSec 0
    }

    Write-Host "`nĐang kiểm tra MD5..." -ForegroundColor DarkGray
    $actual = (Get-FileHash -Path $outPath -Algorithm MD5).Hash.ToLower()
    $expect = $Entry.Md5.ToLower()
    if ($actual -eq $expect) {
        Write-Host "✅ MD5 OK: $actual" -ForegroundColor Green
    }
    else {
        Write-Host "❌ MD5 KHÔNG KHỚP!" -ForegroundColor Red
        Write-Host "   Mong đợi: $expect" -ForegroundColor Red
        Write-Host "   Thực tế : $actual" -ForegroundColor Red
        throw 'File có thể bị hỏng — hãy tải lại.'
    }

    Write-Host "`nHoàn tất. File tại: $outPath" -ForegroundColor Cyan
}

# ---- Main ----
$catalog = Get-WorkstationCatalog
if (-not $catalog) { Write-Error "Không tìm thấy phiên bản nào cho $Platform."; exit 1 }

if ($List) {
    Write-Host "`nCác phiên bản $Platform có sẵn:" -ForegroundColor Cyan
    $catalog | Format-Table Version, SizeMB, FileName -AutoSize
    exit 0
}

if ($Version) {
    $entry = $catalog | Where-Object { $_.Version -ieq $Version } | Select-Object -First 1
    if (-not $entry) {
        Write-Error "Không tìm thấy phiên bản '$Version' cho $Platform. Dùng -List để xem danh sách."
        exit 1
    }
}
else {
    Write-Host "`nCác phiên bản $Platform có sẵn:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $catalog.Count; $i++) {
        '{0,3}. {1,-10} {2,8} MB  {3}' -f ($i + 1), $catalog[$i].Version, $catalog[$i].SizeMB, $catalog[$i].FileName
    }
    do {
        $choice = Read-Host "`nChọn số (1-$($catalog.Count), mặc định 1)"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }
    } until ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $catalog.Count)
    $entry = $catalog[[int]$choice - 1]
}

Invoke-Download -Entry $entry
