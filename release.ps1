# release.ps1 — 建立新版本（tag + GitHub Release）
#
# 用法：
#   .\release.ps1 -Version v1.0.1
#   .\release.ps1 -Version v1.0.1 -NotesFile .\notes\v1.0.1.md
#   .\release.ps1 -Version v1.0.1 -DryRun
#
# 前置：已安裝 GitHub CLI 並登入（gh auth status 正常）

param(
  [Parameter(Mandatory = $true)]
  [string]$Version,
  [string]$NotesFile = "",
  [string]$Title = "",
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# git 輸出為 UTF-8；PowerShell 5.1 預設用 cp950 解讀會讓中文路徑變亂碼
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$env:GIT_PAGER = "cat"

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

if ($Version -notmatch '^v\d+\.\d+\.\d+$') { Fail "版本格式應為 vX.Y.Z，例如 v1.0.1" }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  $candidate = "C:\Program Files\GitHub CLI\gh.exe"
  if (Test-Path $candidate) { $env:Path += ";C:\Program Files\GitHub CLI" }
  else { Fail "找不到 gh（GitHub CLI），請先安裝並登入" }
}

# 確認在 repo 根目錄
$root = git rev-parse --show-toplevel 2>$null
if (-not $root) { Fail "目前目錄不是 git repo" }
Set-Location $root

# 工作區必須乾淨
$dirty = git status --porcelain
if ($dirty) {
  Write-Host "工作區有未提交的變更：" -ForegroundColor Yellow
  $dirty | ForEach-Object { Write-Host "  $_" }
  if (-not $DryRun) { Fail "請先 commit 後再發版" }
}

# 遠端同步
git fetch --tags --quiet
$ahead = git rev-list --count "origin/main..HEAD" 2>$null
if ($ahead -and [int]$ahead -gt 0 -and -not $DryRun) { Fail "本地有 $ahead 個 commit 尚未 push，請先 push" }

# 版本重複檢查
$existing = git tag -l $Version
if ($existing) { Fail "tag $Version 已存在" }

# 準備 release notes
if (-not $NotesFile) {
  $prev = git describe --tags --abbrev=0 2>$null
  if (-not $prev) { $prev = "" }
  $range = if ($prev) { "$prev..HEAD" } else { "HEAD" }
  $lines = git log $range --pretty=format:"- %s" 2>$null
  $NotesFile = Join-Path $env:TEMP "release-notes-$Version.md"
  $body = "## 變更`n`n" + (($lines -join "`n") -replace "^$", "- 初始版本") + "`n"
  [System.IO.File]::WriteAllText($NotesFile, $body, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "自動產生 release notes：$NotesFile"
}

if (-not (Test-Path $NotesFile)) { Fail "找不到 notes 檔：$NotesFile" }
if (-not $Title) { $Title = $Version }

Write-Host ""
Write-Host "版本   : $Version"
Write-Host "標題   : $Title"
Write-Host "Notes  : $NotesFile"
Write-Host "Repo   : $root"
Write-Host ""

if ($DryRun) {
  Write-Host "[DryRun] 會執行：git tag $Version / git push origin $Version / gh release create ..." -ForegroundColor Cyan
  Get-Content $NotesFile -Encoding UTF8 | Select-Object -First 10 | ForEach-Object { "   | $_" }
  exit 0
}

git tag -a $Version -m $Title
if ($LASTEXITCODE -ne 0) { Fail "建立 tag 失敗" }

git push origin $Version
if ($LASTEXITCODE -ne 0) { Fail "推送 tag 失敗" }

gh release create $Version --title $Title --notes-file $NotesFile
if ($LASTEXITCODE -ne 0) { Fail "建立 Release 失敗" }

Write-Host ""
Write-Host "完成：" -ForegroundColor Green
$repo = (gh repo view --json nameWithOwner --jq .nameWithOwner)
Write-Host "  https://github.com/$repo/releases/tag/$Version"
Write-Host "  https://github.com/$repo/archive/refs/tags/$Version.zip"
