# frame150

動画を **最大150枚** の画像に切り分け、**合計容量を上限（既定30MB）以内**に収めるPowerShellツール。

抽出前に容量を予測し、JPG / WebP / PNG の画質・容量を見比べてから形式を選べます。中間成果物（raw）を保存するので、最終形式だけを後から作り直せます。

---

## 特長

- **最大150枚**に自動分割（fpsを `150 ÷ 動画長` で自動計算、小数点対応）
- **容量上限**に収まる最高画質を自動探索（二分探索）
- **形式を対話選択**：JPG / WebP / PNG（減色・無劣化）
- **抽出前の予測**：サンプル1枚を計測し合計容量を推定
- **比較画像**：6パターンを実際に圧縮して画質・容量を視覚比較（`preview_compare.png`）
- **フレーム補完**：抽出fpsが元動画fpsを上回る場合に警告し、補完方法を選択（`-Interpolate`）
- **解像度リサイズ**、**プレビューGIF**、**DryRun**（予測のみ）
- **中間成果物の再利用**：`raw/` から `final/` だけ作り直し（`-Rebuild`）。設定が同じならスキップ

---

## 必要環境

| ツール | 必須 | 用途 |
|--------|------|------|
| ffmpeg / ffprobe | 必須 | 抽出・エンコード・情報取得 |
| pngquant | 任意 | PNG減色の品質向上（無ければffmpegパレットで代替） |
| PowerShell 7+ | 推奨 | 実行環境 |

`frame150.ps1` を PATH の通った場所に置くと、どのフォルダからでも実行できます。

---

## 使い方

### 基本（対話実行）

```powershell
# カレントフォルダに <動画名>_frames/ を作成
frame150.ps1 -InputVideo "Video.mp4"
```

予測レポートと比較画像が表示され、出力形式をメニューから選択します。

```
─── 出力形式を選択 ────────────────────────────
  [1] JPG  推奨   q=85  → 推定   12.3 MB ✓
  [2] JPG  最大   q=93  → 推定   28.7 MB ✓
  [3] WebP 推奨   q=85  → 推定    9.1 MB ✓
  [4] WebP 最大   q=95  → 推定   27.4 MB ✓
  [5] PNG  減色   q=78  → 推定   26.5 MB ✓
  [6] PNG  無劣化 q=100 → 推定  142.0 MB ⚠超過
  [n] キャンセル
選択 [1-6/n]:
```

### よく使う例

```powershell
# 予測と比較画像だけ確認（抽出しない）
frame150.ps1 -InputVideo "Video.mp4" -DryRun

# 解像度を半分にして容量削減
frame150.ps1 -InputVideo "Video.mp4" -Scale 0.5

# 横1280pxにリサイズ
frame150.ps1 -InputVideo "Video.mp4" -Scale 1280:-1

# フレーム補完（動き推定・高品質・低速）
frame150.ps1 -InputVideo "Video.mp4" -Interpolate minterpolate

# 非対話で実行（自動化向け）
frame150.ps1 -InputVideo "Video.mp4" -Force -Format webp -Preset maximum -Gif

# raw/ を再利用して final/ だけ別形式で作り直す
frame150.ps1 -InputVideo "Video.mp4" -OutputDir "Video_frames" -Rebuild
```

---

## パラメータ

| パラメータ | 既定 | 説明 |
|-----------|------|------|
| `-InputVideo`（必須） | — | 入力動画パス |
| `-OutputDir` | `<動画名>_frames` | 出力先（カレント基準） |
| `-MaxFrames` | 150 | 最大フレーム数 |
| `-MaxSizeMB` | 30 | 合計容量の上限(MB) |
| `-FPS` | 自動 | fpsを手動指定（小数点可）。省略時 `MaxFrames ÷ 動画長` |
| `-Interpolate` | none | `none` / `blend` / `minterpolate` |
| `-Scale` | なし | 倍率 `0.5` / 解像度 `1280:-1` / `1920:1080` |
| `-Format` | jpg | `-Force` 時の形式：`jpg` / `webp` / `png` |
| `-Preset` | maximum | `-Force` 時の品質：`recommended`(q85) / `maximum`(上限内最高) |
| `-Gif` | off | プレビューGIFを生成 |
| `-GifFps` | 0 | GIFのfps（0=抽出fpsと同じ） |
| `-DryRun` | off | 予測と比較画像のみ |
| `-NoCompare` | off | 比較画像を生成しない |
| `-Rebuild` | off | raw/ から final/ だけ作り直す |
| `-NoSkip` | off | 最新でもスキップせず再生成 |
| `-Force` | off | 確認・選択プロンプトを省略 |

---

## 出力フォルダ構成

```
<動画名>_frames/
├─ _meta.json          # 設定・成果物のメタ情報
├─ preview_compare.png # 画質・容量の比較画像（6パターン）
├─ preview.gif         # プレビューGIF（-Gif 時）
├─ raw/                # 中間成果物（無劣化PNG・再ビルドの元）
└─ final/              # 選択した形式の最終成果
```

### `_meta.json` の例

```json
{
  "duration_sec": 45.2,
  "fps_used": 3.318,
  "frame_interval_ms": 301.39,
  "resolution_src": "1920x1080",
  "resolution_out": "960x540",
  "raw":   { "frame_count": 150, "total_mb": 142.0 },
  "final": { "format": "jpg", "quality": 93, "frame_count": 150, "total_mb": 28.7 }
}
```

`final` の `format` / `quality` / `frame_count` が現在の選択と一致し、実ファイル数も揃っていれば、`-Rebuild` 時に変換をスキップします（`-NoSkip` で強制再生成）。

---

## 補足

- **フレーム補完**：**抽出fps > 元動画fps**（短い動画を150枚に分割する場合など）になると、不足フレームを埋める必要が生じます。このとき予測レポートに警告が出て、対話実行なら補完方法をメニューから選べます。
  - `none`（既定）：同じフレームを複製（補完ではなく重複）
  - `blend`：前後フレームをブレンド合成
  - `minterpolate`：動き推定で中間フレームを生成（高品質・低速）
  - 抽出fpsが元動画fps以下なら補完は不要で、警告・メニューは出ません。
- **形式の選び方**：写真系の動画は WebP が小さく高品質。完全無劣化が必要なら PNG。互換性重視なら JPG。
- **PNG減色**：pngquant があれば高品質に減色、無ければ ffmpeg のパレット減色で代替します。
- 本ツールは単一スクリプト `frame150.ps1` で完結します（外部依存は ffmpeg、任意で pngquant のみ）。
