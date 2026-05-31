param(
    [Parameter(Mandatory=$true)]
    [string]$InputVideo,

    [string]$OutputDir = "",

    [int]$MaxFrames = 150,

    [double]$MaxSizeMB = 30,

    [string]$FPS = "",

    [ValidateSet("none", "blend", "minterpolate")]
    [string]$Interpolate = "none",

    # 解像度リサイズ: 倍率 "0.5" / 解像度 "1280:-1" / "1920:1080"
    [string]$Scale = "",

    # -Force時のデフォルト出力フォーマット（対話時はメニューで選択）
    [ValidateSet("jpg", "webp", "png")]
    [string]$Format = "jpg",

    # -Force時の品質プリセット
    [ValidateSet("recommended", "maximum")]
    [string]$Preset = "maximum",

    # プレビューGIFを生成
    [switch]$Gif,
    # GIFのfps（0=抽出fpsと同じ＝150枚分割時のfpsを使用）
    [double]$GifFps = 0,

    # 予測と比較画像のみ（抽出しない）
    [switch]$DryRun,

    # 比較画像を生成しない
    [switch]$NoCompare,

    # raw/を使って final/ だけ作り直す
    [switch]$Rebuild,

    # final/ が最新でもスキップせず必ず再生成する
    [switch]$NoSkip,

    # 確認・選択プロンプト・自動オープンをスキップ
    [switch]$Force
)

# ─── 依存確認 ─────────────────────────────────────────────────
foreach ($cmd in @("ffmpeg", "ffprobe")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "$cmd が見つかりません。"; exit 1
    }
}
# pngquant は任意（あればPNG減色の品質が向上、無ければffmpegパレットで代替）
$HasPngquant = [bool](Get-Command pngquant -ErrorAction SilentlyContinue)

# ─── 出力フォルダ（実行中カレント基準） ──────────────────────
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $VideoName = [System.IO.Path]::GetFileNameWithoutExtension($InputVideo)
    $OutputDir = Join-Path (Get-Location).Path "${VideoName}_frames"
}

$MetaFile    = Join-Path $OutputDir "_meta.json"
$RawDir      = Join-Path $OutputDir "raw"
$FinalDir    = Join-Path $OutputDir "final"
$CompareFile = Join-Path $OutputDir "preview_compare.png"
$GifFile     = Join-Path $OutputDir "preview.gif"

# ─── ヘルパー関数 ─────────────────────────────────────────────

function Get-TotalMB([string]$Dir, [string]$Filter) {
    $files = Get-ChildItem -Path $Dir -Filter $Filter -ErrorAction SilentlyContinue
    if (-not $files) { return 0 }
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    return [math]::Round($bytes / 1MB, 2)
}

function Get-Ext([string]$fmt) {
    switch ($fmt) { "webp" { "webp" } "png" { "png" } default { "jpg" } }
}

# ffmpeg JPGのq:v値はquality=1(最高)～31(最低)
function Quality-ToQV([int]$quality) {
    return [math]::Max(1, [math]::Min(31, [int][math]::Round((100 - $quality) * 30 / 99 + 1)))
}

# 1フレームを指定フォーマット・品質でエンコード
function Encode-Frame([string]$src, [string]$dst, [int]$quality, [string]$fmt) {
    switch ($fmt) {
        "webp" { ffmpeg -y -i $src -c:v libwebp -quality $quality -compression_level 6 $dst 2>$null }
        "png" {
            if ($quality -ge 100) {
                # 無劣化（トゥルーカラー）
                ffmpeg -y -i $src -compression_level 9 $dst 2>$null
            } elseif ($HasPngquant) {
                # pngquant で減色（quality%を上限品質に）
                pngquant --quality=0-$quality --speed 1 --strip --force --output $dst $src 2>$null
                if (-not (Test-Path $dst)) { ffmpeg -y -i $src -compression_level 9 $dst 2>$null }
            } else {
                # ffmpegパレット減色（quality%→色数 2～256）
                $colors = [math]::Max(2, [math]::Min(256, [int][math]::Round($quality / 100 * 256)))
                ffmpeg -y -i $src -vf "split[a][b];[a]palettegen=max_colors=${colors}[p];[b][p]paletteuse=dither=sierra2_4a" $dst 2>$null
            }
        }
        default { ffmpeg -y -i $src -q:v (Quality-ToQV $quality) $dst 2>$null }
    }
}

# サンプル1枚を指定設定でエンコードしたバイト数を返す
function Measure-SampleBytes([string]$sample, [int]$quality, [string]$fmt) {
    $tmp = Join-Path $env:TEMP ("ev_m_{0}.{1}" -f (Get-Random), (Get-Ext $fmt))
    Encode-Frame $sample $tmp $quality $fmt
    $b = if (Test-Path $tmp) { (Get-Item $tmp).Length } else { 0 }
    Remove-Item $tmp -ErrorAction SilentlyContinue
    return $b
}

# 上限以内に収まる最大qualityを二分探索
function Find-MaxQuality([string]$sample, [int]$count, [double]$limit, [string]$fmt) {
    $low = 40; $high = 99; $best = 40
    while ($low -le $high) {
        $mid = [int](($low + $high) / 2)
        $b = Measure-SampleBytes $sample $mid $fmt
        $estMB = $b * $count / 1MB
        if ($b -gt 0 -and $estMB -le $limit) { $best = $mid; $low = $mid + 1 }
        else { $high = $mid - 1 }
    }
    return $best
}

# raw/ のPNG群を指定フォーマット・品質で final/ へ出力
function Produce-Final([string]$SrcDir, [string]$DstDir, [int]$Quality, [string]$fmt) {
    if (Test-Path $DstDir) { Remove-Item -Recurse -Force $DstDir }
    New-Item -ItemType Directory -Force -Path $DstDir | Out-Null
    $ext  = Get-Ext $fmt
    $pngs = Get-ChildItem -Path $SrcDir -Filter "frame_*.png" | Sort-Object Name
    $i = 0
    foreach ($png in $pngs) {
        $i++
        $outFile = Join-Path $DstDir ("frame_{0:D5}.{1}" -f $i, $ext)
        # PNG無劣化(=100)は単純コピー、減色(<100)はエンコード
        if ($fmt -eq "png" -and $Quality -ge 100) { Copy-Item $png.FullName $outFile -Force }
        else { Encode-Frame $png.FullName $outFile $Quality $fmt }
    }
}

# Scale指定を ffmpeg scale フィルターへ変換
function Get-ScaleFilter([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }
    if ($s -match "^[0-9]*\.?[0-9]+$") {
        return "scale=trunc(iw*$s/2)*2:trunc(ih*$s/2)*2"
    }
    return "scale=$s"
}

# ─── 出力形式オプション一覧を構築（推定容量付き） ───────────
function Get-FormatOptions([string]$sample, [int]$count) {
    $pngBytes = if (Test-Path $sample) { (Get-Item $sample).Length } else { 0 }
    $jpgMax   = Find-MaxQuality $sample $count $MaxSizeMB "jpg"
    $webpMax  = Find-MaxQuality $sample $count $MaxSizeMB "webp"
    $pngMax   = Find-MaxQuality $sample $count $MaxSizeMB "png"

    $mk = {
        param($key, $label, $fmt, $q, $bytes)
        [pscustomobject]@{
            key = $key; label = $label; fmt = $fmt; quality = $q
            estMB = [math]::Round($bytes * $count / 1MB, 2)
        }
    }
    return @(
        & $mk "1" "JPG  推奨"   "jpg"  85       (Measure-SampleBytes $sample 85 "jpg")
        & $mk "2" "JPG  最大"   "jpg"  $jpgMax  (Measure-SampleBytes $sample $jpgMax "jpg")
        & $mk "3" "WebP 推奨"   "webp" 85       (Measure-SampleBytes $sample 85 "webp")
        & $mk "4" "WebP 最大"   "webp" $webpMax (Measure-SampleBytes $sample $webpMax "webp")
        & $mk "5" "PNG  減色"   "png"  $pngMax  (Measure-SampleBytes $sample $pngMax "png")
        & $mk "6" "PNG  無劣化" "png"  100      $pngBytes
    )
}

# ─── 形式選択メニュー（戻り値: 選択オプション or $null=キャンセル） ──
function Select-FormatOption([array]$options) {
    Write-Host "`n─── 出力形式を選択 ────────────────────────────" -ForegroundColor Cyan
    foreach ($o in $options) {
        $icon = if ($o.estMB -le $MaxSizeMB) { "✓" } else { "⚠超過" }
        Write-Host ("  [{0}] {1}  q={2,-3} → 推定 {3,7} MB {4}" -f $o.key, $o.label, $o.quality, $o.estMB, $icon)
    }
    Write-Host "  [n] キャンセル"
    while ($true) {
        $ans = Read-Host "選択 [1-6/n]"
        if ($ans -match "^[nN]") { return $null }
        $sel = $options | Where-Object { $_.key -eq $ans }
        if ($sel) { return $sel }
        Write-Host "  無効な入力です。" -ForegroundColor Yellow
    }
}

# ─── 比較画像生成 ─────────────────────────────────────────────
function Build-CompareImage([string]$sample, [int]$count, [string]$outFile, [array]$configs, [double]$fps, [double]$intervalMs, [double]$srcFps, [double]$srcIntervalMs) {
    try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop }
    catch { Write-Warning "System.Drawingが使えないため比較画像をスキップします。"; return $false }

    $items = @()
    foreach ($c in $configs) {
        $encTmp = Join-Path $env:TEMP ("ev_cmp_{0}.{1}" -f (Get-Random), (Get-Ext $c.fmt))
        Encode-Frame $sample $encTmp $c.quality $c.fmt
        $bytes = if (Test-Path $encTmp) { (Get-Item $encTmp).Length } else { 0 }
        $estMB = [math]::Round($bytes * $count / 1MB, 2)
        $dispPng = Join-Path $env:TEMP ("ev_disp_{0}.png" -f (Get-Random))
        ffmpeg -y -i $encTmp $dispPng 2>$null
        $items += @{ img = $dispPng; label = $c.label; quality = $c.quality; fmt = $c.fmt;
                     estMB = $estMB; kb = [math]::Round($bytes / 1KB, 1); tmp = $encTmp }
    }
    $valid = $items | Where-Object { Test-Path $_.img }
    if ($valid.Count -eq 0) { return $false }

    $cellW = 460; $labelH = 64; $pad = 12; $cols = 2
    $n = $items.Count
    $rows = [math]::Ceiling($n / $cols)
    $first = [System.Drawing.Image]::FromFile($valid[0].img)
    $aspect = $first.Height / $first.Width
    $first.Dispose()
    $cellH = [int]($cellW * $aspect)

    $headH = 66
    $totalW = $cols * $cellW + ($cols + 1) * $pad
    $totalH = $rows * ($cellH + $labelH) + ($rows + 1) * $pad + $headH

    $bmp = New-Object System.Drawing.Bitmap($totalW, $totalH)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(28, 28, 32))
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

    $fontHead  = New-Object System.Drawing.Font("Meiryo", 13, [System.Drawing.FontStyle]::Bold)
    $fontTitle = New-Object System.Drawing.Font("Meiryo", 12, [System.Drawing.FontStyle]::Bold)
    $fontInfo  = New-Object System.Drawing.Font("Meiryo", 10)
    $white = [System.Drawing.Brushes]::White
    $green = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(120, 230, 120))
    $amber = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(240, 190, 80))

    $g.DrawString(("画質・容量 比較 （上限 {0} MB / 想定 {1} 枚）" -f $MaxSizeMB, $count),
                  $fontHead, $white, 12, 6)
    $g.DrawString(("元動画: {0} fps / {1} ms/枚    抽出: {2} fps / {3} ms/枚" -f `
                    $srcFps, $srcIntervalMs, $fps, $intervalMs),
                  $fontInfo, [System.Drawing.Brushes]::Gainsboro, 12, 36)

    for ($i = 0; $i -lt $n; $i++) {
        $r = [int][math]::Floor($i / $cols)
        $col = $i % $cols
        $x = $pad + $col * ($cellW + $pad)
        $y = $headH + $pad + $r * ($cellH + $labelH + $pad)
        if (Test-Path $items[$i].img) {
            $im = [System.Drawing.Image]::FromFile($items[$i].img)
            $g.DrawImage($im, $x, $y, $cellW, $cellH)
            $im.Dispose()
        }
        $it = $items[$i]
        $ok = $it.estMB -le $MaxSizeMB
        $g.DrawString($it.label, $fontTitle, $white, $x, ($y + $cellH + 4))
        $g.DrawString(("{0} q={1}  1枚 {2}KB  合計 {3}MB  {4}" -f `
                        $it.fmt.ToUpper(), $it.quality, $it.kb, $it.estMB,
                        $(if ($ok) { "[収まる]" } else { "[超過]" })),
                      $fontInfo, $(if ($ok) { $green } else { $amber }), $x, ($y + $cellH + 30))
    }
    $g.Dispose()
    $bmp.Save($outFile, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    foreach ($it in $items) { Remove-Item $it.img, $it.tmp -ErrorAction SilentlyContinue }
    return $true
}

# ─── メタデータ ───────────────────────────────────────────────
function Save-Meta([hashtable]$Data) {
    $Data | ConvertTo-Json -Depth 5 | Set-Content -Path $MetaFile -Encoding UTF8
}
function Load-Meta {
    if (Test-Path $MetaFile) { return Get-Content $MetaFile -Raw | ConvertFrom-Json }
    return $null
}

# final/ が指定の形式・品質・枚数と一致し、実ファイルも揃っているか
function Test-FinalCurrent([string]$fmt, [int]$quality, [int]$expectedCount) {
    $m = Load-Meta
    if (-not $m -or -not $m.final) { return $false }
    if ($m.final.format -ne $fmt) { return $false }
    if ([int]$m.final.quality -ne $quality) { return $false }
    if ($m.final.PSObject.Properties.Name -notcontains "frame_count") { return $false }
    $ext = Get-Ext $fmt
    $cnt = (Get-ChildItem -Path $FinalDir -Filter "*.$ext" -ErrorAction SilentlyContinue).Count
    if ($cnt -le 0) { return $false }
    if ([int]$m.final.frame_count -ne $cnt) { return $false }
    if ($expectedCount -gt 0 -and $cnt -ne $expectedCount) { return $false }
    return $true
}

# -Force時に使うデフォルト選択を生成
function Get-DefaultOption([string]$sample, [int]$count) {
    if ($Format -eq "png") {
        if ($Preset -eq "recommended") {
            # 減色して上限内に収める
            $q = Find-MaxQuality $sample $count $MaxSizeMB "png"
            return [pscustomobject]@{ label = "PNG 減色"; fmt = "png"; quality = $q;
                                      estMB = [math]::Round((Measure-SampleBytes $sample $q "png") * $count / 1MB, 2) }
        }
        $b = if (Test-Path $sample) { (Get-Item $sample).Length } else { 0 }
        return [pscustomobject]@{ label = "PNG 無劣化"; fmt = "png"; quality = 100;
                                  estMB = [math]::Round($b * $count / 1MB, 2) }
    }
    $q = if ($Preset -eq "recommended") { 85 } else { Find-MaxQuality $sample $count $MaxSizeMB $Format }
    return [pscustomobject]@{ label = "$($Format.ToUpper()) $Preset"; fmt = $Format; quality = $q;
                             estMB = [math]::Round((Measure-SampleBytes $sample $q $Format) * $count / 1MB, 2) }
}

# ════════════════════════════════════════════════════════════
#  再ビルドモード（raw/ から final/ を作り直す）
# ════════════════════════════════════════════════════════════
if ($Rebuild) {
    $meta = Load-Meta
    $rawFrames = Get-ChildItem -Path $RawDir -Filter "frame_*.png" -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $rawFrames -or $rawFrames.Count -eq 0) {
        Write-Error "raw/ にフレームが見つかりません。先に通常実行してください。"; exit 1
    }
    Write-Host "`n─── 再ビルドモード ────────────────────────────" -ForegroundColor Cyan
    Write-Host "  raw/ フレーム数: $($rawFrames.Count) 枚"

    $frameCount = $rawFrames.Count
    $samplePng  = $rawFrames[[int]($frameCount / 2)].FullName

    if ($Force) {
        $choice = Get-DefaultOption $samplePng $frameCount
    } else {
        $options = Get-FormatOptions $samplePng $frameCount
        $choice  = Select-FormatOption $options
        if (-not $choice) { Write-Host "キャンセルしました。"; exit 0 }
    }

    if (-not $NoSkip -and (Test-FinalCurrent $choice.fmt $choice.quality $frameCount)) {
        $finalMB = Get-TotalMB $FinalDir "*.*"
        Write-Host ("`nfinal/ は最新です（{0} q={1}, {2} 枚 / {3} MB）。スキップしました。" -f `
                    $choice.fmt.ToUpper(), $choice.quality, $frameCount, $finalMB) -ForegroundColor Green
        Write-Host "  再生成するには -NoSkip を付けてください。"
        exit 0
    }

    Write-Host ("`nfinal/ を作り直します（{0} q={1}）..." -f $choice.fmt.ToUpper(), $choice.quality) -ForegroundColor Yellow
    Produce-Final $RawDir $FinalDir $choice.quality $choice.fmt
    $finalMB = Get-TotalMB $FinalDir "*.*"

    # メタが無ければ最小限を新規作成（次回スキップ判定のため）
    if (-not $meta) { $meta = [pscustomobject]@{ raw = [pscustomobject]@{ frame_count = $frameCount } } }
    $meta | Add-Member -NotePropertyName rebuilt_at -NotePropertyValue (Get-Date -Format "yyyy-MM-ddTHH:mm:ss") -Force
    $meta | Add-Member -NotePropertyName final -NotePropertyValue ([pscustomobject]@{
        format = $choice.fmt; quality = $choice.quality; frame_count = $frameCount; total_mb = $finalMB
    }) -Force
    $meta | ConvertTo-Json -Depth 5 | Set-Content -Path $MetaFile -Encoding UTF8
    Write-Host "`n─── 完了 ──────────────────────────────────────" -ForegroundColor Green
    Write-Host ("  [final] {0} q={1}  {2} MB  → {3}" -f $choice.fmt.ToUpper(), $choice.quality, $finalMB, $FinalDir)
    exit 0
}

# ════════════════════════════════════════════════════════════
#  通常実行
# ════════════════════════════════════════════════════════════
if (-not (Test-Path $InputVideo)) {
    Write-Error "入力動画が存在しません: $InputVideo"; exit 1
}

Write-Host "動画情報を取得中..." -ForegroundColor Cyan
$duration = [double](ffprobe -v error -select_streams v:0 `
    -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $InputVideo 2>$null)
$srcResolution = ffprobe -v error -select_streams v:0 `
    -show_entries stream=width,height -of csv=s=x:p=0 $InputVideo 2>$null
if ($duration -le 0) { Write-Error "動画の長さを取得できませんでした。"; exit 1 }

# 元動画のネイティブfps（r_frame_rate は "30000/1001" 等の分数）
$srcFpsRaw = ffprobe -v error -select_streams v:0 `
    -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 $InputVideo 2>$null
if ($srcFpsRaw -match '^(\d+)/(\d+)$' -and [double]$Matches[2] -ne 0) {
    $srcFps = [math]::Round([double]$Matches[1] / [double]$Matches[2], 3)
} elseif ($srcFpsRaw -match '^\d+(\.\d+)?$') {
    $srcFps = [math]::Round([double]$srcFpsRaw, 3)
} else { $srcFps = 0 }
$srcIntervalMs = if ($srcFps -gt 0) { [math]::Round(1000 / $srcFps, 2) } else { 0 }

if ([string]::IsNullOrWhiteSpace($FPS)) {
    $useFps    = [math]::Round($MaxFrames / $duration, 6)
    $fpsSource = "自動計算"
} else {
    $useFps    = [double]$FPS
    $fpsSource = "手動指定"
}
$estFrameCount   = [math]::Min($MaxFrames, [int][math]::Ceiling($useFps * $duration))
$frameIntervalMs = [math]::Round(1000 / $useFps, 2)
$scaleFilter     = Get-ScaleFilter $Scale

# サンプルフレーム（リサイズ適用済み）
Write-Host "サンプルフレームを計測中..." -ForegroundColor Cyan
$sampleTmp = Join-Path $env:TEMP "ev_sample_$(Get-Random).png"
$midSec    = [math]::Round($duration / 2, 3)
if ($scaleFilter) { ffmpeg -y -ss $midSec -i $InputVideo -vf $scaleFilter -vframes 1 $sampleTmp 2>$null }
else              { ffmpeg -y -ss $midSec -i $InputVideo -vframes 1 $sampleTmp 2>$null }
$outResolution = ffprobe -v error -select_streams v:0 `
    -show_entries stream=width,height -of csv=s=x:p=0 $sampleTmp 2>$null

# 形式オプション一覧（推定容量込み）
$options = Get-FormatOptions $sampleTmp $estFrameCount

# ─── 予測表示 ─────────────────────────────────────────────────
Write-Host ""
Write-Host "─── 予測レポート ──────────────────────────────" -ForegroundColor Cyan
Write-Host ("  動画長さ      : {0} 秒" -f [math]::Round($duration, 2))
Write-Host ("  解像度        : {0}{1}" -f $srcResolution, $(if ($scaleFilter) { " → $outResolution (リサイズ)" } else { "" }))
Write-Host ("  元動画FPS     : {0} fps / {1} ms/枚" -f $srcFps, $srcIntervalMs)
Write-Host ("  抽出FPS       : {0} fps（{1}）" -f $useFps, $fpsSource)
Write-Host ("  フレーム間隔  : {0} ms/枚" -f $frameIntervalMs)
Write-Host ("  予測フレーム数: {0} 枚" -f $estFrameCount)
Write-Host ("  補完モード    : {0}" -f $Interpolate)

# 補完が起こりうる条件：抽出FPS > 元動画FPS（足りないフレームを埋める）
$willInterpolate = ($srcFps -gt 0 -and $useFps -gt $srcFps)
if ($willInterpolate) {
    Write-Host ("  ⚠ 抽出FPS({0}) > 元動画FPS({1}) → 補完が発生します" -f $useFps, $srcFps) -ForegroundColor Yellow
    Write-Host  "      none=同フレーム複製 / blend=ブレンド合成 / minterpolate=動き推定生成" -ForegroundColor Yellow
}

# ─── 比較画像 ─────────────────────────────────────────────────
if (-not $NoCompare) {
    Write-Host "`n比較画像を生成中..." -ForegroundColor Cyan
    $configs = @(
        @{ label = "推奨 JPG";  quality = ($options | ? key -eq "1").quality; fmt = "jpg"  },
        @{ label = "最大 JPG";  quality = ($options | ? key -eq "2").quality; fmt = "jpg"  },
        @{ label = "推奨 WebP"; quality = 85;                                  fmt = "webp" },
        @{ label = "最大 WebP"; quality = ($options | ? key -eq "4").quality; fmt = "webp" },
        @{ label = "減色 PNG";  quality = ($options | ? key -eq "5").quality; fmt = "png"  },
        @{ label = "無劣化 PNG"; quality = 100;                                fmt = "png"  }
    )
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    if (Build-CompareImage $sampleTmp $estFrameCount $CompareFile $configs $useFps $frameIntervalMs $srcFps $srcIntervalMs) {
        Write-Host "  比較画像: $CompareFile" -ForegroundColor Green
        if (-not $Force) { Invoke-Item $CompareFile -ErrorAction SilentlyContinue }
    }
}

# ─── DryRun はここで終了 ─────────────────────────────────────
if ($DryRun) {
    Remove-Item $sampleTmp -ErrorAction SilentlyContinue
    Write-Host "`n[DryRun] 抽出なし。形式別の推定値:" -ForegroundColor Yellow
    foreach ($o in $options) {
        $icon = if ($o.estMB -le $MaxSizeMB) { "✓" } else { "⚠超過" }
        Write-Host ("    {0,-10} q={1,-3} → {2,7} MB {3}" -f $o.label, $o.quality, $o.estMB, $icon)
    }
    exit 0
}

# ─── 形式選択 ─────────────────────────────────────────────────
if ($Force) {
    $choice = Get-DefaultOption $sampleTmp $estFrameCount
    Write-Host ("`n[Force] {0} q={1} で実行します。" -f $choice.fmt.ToUpper(), $choice.quality)
} else {
    $choice = Select-FormatOption $options
    if (-not $choice) { Remove-Item $sampleTmp -ErrorAction SilentlyContinue; Write-Host "キャンセルしました。"; exit 0 }
}
Remove-Item $sampleTmp -ErrorAction SilentlyContinue

# ─── 補完モード選択（補完が起こりうる & 未指定 & 対話時のみ） ──
if ($willInterpolate -and -not $Force -and $Interpolate -eq "none") {
    Write-Host "`n─── フレーム補完 ──────────────────────────────" -ForegroundColor Cyan
    Write-Host "  抽出FPSが元動画を上回るため、不足フレームの埋め方を選べます:"
    Write-Host "  [1] none          同じフレームを複製（高速・既定）"
    Write-Host "  [2] blend         前後フレームをブレンド合成"
    Write-Host "  [3] minterpolate  動き推定で中間フレーム生成（高品質・低速）"
    $imap = @{ "1" = "none"; "2" = "blend"; "3" = "minterpolate" }
    while ($true) {
        $ians = Read-Host "選択 [1-3]"
        if ($imap.ContainsKey($ians)) { $Interpolate = $imap[$ians]; break }
        Write-Host "  無効な入力です。" -ForegroundColor Yellow
    }
    Write-Host ("  → 補完モード: {0}" -f $Interpolate) -ForegroundColor Green
}

# ─── GIF作成可否 ──────────────────────────────────────────────
if ($Force -or $PSBoundParameters.ContainsKey("Gif")) {
    $makeGif = [bool]$Gif
} else {
    $ans = Read-Host "プレビューGIFを作成しますか？ [y/N]"
    $makeGif = $ans -match "^[yY]"
}

# ─── raw/ 抽出 ────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $RawDir | Out-Null
switch ($Interpolate) {
    "blend"        { $vfParts = @("minterpolate=fps=${useFps}:mi_mode=blend") }
    "minterpolate" { $vfParts = @("minterpolate=fps=${useFps}:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1") }
    default        { $vfParts = @("fps=$useFps") }
}
if ($scaleFilter) { $vfParts += $scaleFilter }
$vfString = $vfParts -join ","

Write-Host "`nフレーム抽出中 → raw/ ..." -ForegroundColor Cyan
$RawPattern = Join-Path $RawDir "frame_%05d.png"
ffmpeg -y -i $InputVideo -vf $vfString -compression_level 3 $RawPattern
if ($LASTEXITCODE -ne 0) { Write-Error "ffmpegの実行に失敗しました。"; exit 1 }

$rawFrames   = Get-ChildItem -Path $RawDir -Filter "frame_*.png" | Sort-Object Name
$actualCount = $rawFrames.Count
$rawActualMB = Get-TotalMB $RawDir "*.png"
Write-Host "  抽出完了: $actualCount 枚 / $rawActualMB MB"

# ─── final/ 生成（選択した1形式） ───────────────────────────
# 通常実行では raw/ を作り直しているため final も必ず再生成する
# （スキップは raw 不変の -Rebuild 時のみ有効）
Write-Host ("`n[final] {0} q={1} に変換中..." -f $choice.fmt.ToUpper(), $choice.quality) -ForegroundColor Yellow
Produce-Final $RawDir $FinalDir $choice.quality $choice.fmt
$finalMB = Get-TotalMB $FinalDir "*.*"

# ─── プレビューGIF ────────────────────────────────────────────
if ($makeGif) {
    # GifFps未指定(0)なら抽出fps（150枚分割時のfps）を使用
    $gifFpsUsed = if ($GifFps -gt 0) { $GifFps } else { $useFps }
    $gifIntervalMs = [math]::Round(1000 / $gifFpsUsed, 2)
    Write-Host ("`nプレビューGIFを生成中（{0} fps / {1} ms/枚）..." -f $gifFpsUsed, $gifIntervalMs) -ForegroundColor Cyan
    $gifVf = "scale=480:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"
    ffmpeg -y -framerate $gifFpsUsed -i $RawPattern -vf $gifVf -loop 0 $GifFile 2>$null
    if (Test-Path $GifFile) { Write-Host ("  GIF: {0} ({1} MB)" -f $GifFile, (Get-TotalMB $OutputDir "preview.gif")) }
}

# ─── メタデータ保存 ───────────────────────────────────────────
$meta = @{
    source_video      = (Resolve-Path $InputVideo).Path
    duration_sec      = [math]::Round($duration, 3)
    resolution_src    = $srcResolution
    resolution_out    = $outResolution
    scale             = $Scale
    src_fps           = $srcFps
    src_interval_ms   = $srcIntervalMs
    fps_used          = $useFps
    frame_interval_ms = $frameIntervalMs
    interpolate       = $Interpolate
    max_frames        = $MaxFrames
    max_size_mb       = $MaxSizeMB
    extracted_at      = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    raw   = @{ frame_count = $actualCount; total_mb = $rawActualMB }
    final = @{ format = $choice.fmt; quality = $choice.quality; frame_count = $actualCount; total_mb = $finalMB }
}
Save-Meta $meta

# ─── 最終レポート ─────────────────────────────────────────────
Write-Host "`n─── 完了 ──────────────────────────────────────" -ForegroundColor Green
Write-Host "  出力先: $OutputDir"
Write-Host ("  フレーム間隔: {0} ms/枚 / 解像度: {1}" -f $frameIntervalMs, $outResolution)
Write-Host ""
Write-Host ("  [raw]   {0} 枚 / {1} MB  → {2}" -f $actualCount, $rawActualMB, $RawDir)
Write-Host ("  [final] {0} q={1}  {2} MB  → {3}" -f $choice.fmt.ToUpper(), $choice.quality, $finalMB, $FinalDir)
$check = if ($finalMB -le $MaxSizeMB) { "✓ OK" } else { "⚠ 超過" }
Write-Host ("  容量チェック: {0} MB / 上限 {1} MB {2}" -f $finalMB, $MaxSizeMB, $check) -ForegroundColor $(if ($finalMB -le $MaxSizeMB) { "Green" } else { "Yellow" })
Write-Host ""
Write-Host "  ※ final/ だけ別形式で作り直す例:"
Write-Host ("    frame150.ps1 -InputVideo `"{0}`" -OutputDir `"{1}`" -Rebuild" -f $InputVideo, $OutputDir)
