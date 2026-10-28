#requires -Version 5.1
<#
.SYNOPSIS
    把 apple/ 一键推到 GitHub，让 Actions 在云端 macOS 上编译出 Txin.app。

.DESCRIPTION
    没 Mac 也能拿到 .app —— 只要有一个 GitHub 账号。
    这个脚本做四件事：确认工具 → 初始化仓库 → 提交 → 建远端并推送 → 打印 Actions 地址。

.PARAMETER Remote
    远端仓库地址，形如 https://github.com/<你>/txin-mac.git
    不填则只做本地提交，最后打印手动推送的命令。

.PARAMETER RepoName
    配合 -Create 使用：用 gh CLI 自动建一个私有仓库。

.EXAMPLE
    .\push-to-github.ps1 -Remote https://github.com/me/txin-mac.git

.EXAMPLE
    # 装了 GitHub CLI 的话，连仓库一起建
    .\push-to-github.ps1 -Create -RepoName txin-mac
#>
[CmdletBinding()]
param(
    [string]$Remote,
    [switch]$Create,
    [string]$RepoName = 'txin-mac',
    [string]$Branch = 'main',
    [string]$Message = 'feat: 糖心 macOS 客户端 (SwiftPM + GitHub Actions)'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $root

function Say($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Ok($msg)  { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($m)  { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Die($msg) { Write-Host "  [X] $msg" -ForegroundColor Red; Pop-Location; exit 1 }

Write-Host "`n=== 糖心 macOS 客户端 · 推送到 GitHub ===`n" -ForegroundColor Magenta

# ---------- 1. 工具检查 ----------
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Die "没找到 git。装一个：https://git-scm.com/download/win （或 winget install Git.Git）"
}
Ok "git $((git --version) -replace 'git version ','')"

if (-not (Test-Path 'Package.swift')) {
    Die "当前目录不是工程根（没有 Package.swift）：$root"
}
if (-not (Test-Path '.github/workflows/macos-app.yml')) {
    Die "缺少 workflow 文件：.github/workflows/macos-app.yml"
}
Ok "工程完整（Package.swift + workflow）"

# ---------- 2. 仓库初始化 ----------
if (-not (Test-Path '.git')) {
    Say "初始化仓库…"
    git init -b $Branch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { git init 2>&1 | Out-Null; git checkout -b $Branch 2>&1 | Out-Null }
    Ok "已 git init（分支 $Branch）"
} else {
    $cur = (git rev-parse --abbrev-ref HEAD 2>$null)
    Ok "已有仓库，当前分支：$cur"
}

# 身份检查
$email = (git config user.email 2>$null)
if ([string]::IsNullOrWhiteSpace($email)) {
    Warn "还没配 git 身份，用占位值（之后可改：git config --global user.email ...）"
    git config user.email 'txin@local'
    git config user.name  'txin builder'
}

# ---------- 3. 提交 ----------
git add -A
$status = (git status --porcelain)
if ([string]::IsNullOrWhiteSpace($status)) {
    Ok "没有新改动，跳过提交"
} else {
    Say "提交…"
    git commit -m $Message 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "git commit 失败" }
    Ok "已提交 $(git rev-parse --short HEAD)"
}

# ---------- 4. 远端 ----------
$hasOrigin = $false
$existing = (git remote 2>$null)
if ($existing -contains 'origin') {
    $hasOrigin = $true
    Ok "已存在 origin：$(git remote get-url origin)"
}

if ($Create) {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { Die "-Create 需要 GitHub CLI：winget install GitHub.cli 然后 gh auth login" }
    Say "用 gh 创建仓库 $RepoName …"
    gh repo create $RepoName --private --source=. --remote=origin --push
    if ($LASTEXITCODE -ne 0) { Die "gh repo create 失败" }
    $hasOrigin = $true
    $Remote = (git remote get-url origin)
}

if ($Remote) {
    if ($hasOrigin) {
        git remote set-url origin $Remote
    } else {
        git remote add origin $Remote
    }
    Ok "origin = $Remote"
    Say "推送…"
    git push -u origin $Branch
    if ($LASTEXITCODE -ne 0) {
        Warn "HTTPS 推送失败，常见原因：没配 token / 需要代理"
        Warn "改用 SSH：git remote set-url origin git@github.com:<你>/$RepoName.git"
        Die "推送未完成"
    }
    Ok "推送成功"
}

# ---------- 5. 下一步 ----------
$webUrl = $null
if ($hasOrigin) {
    $u = (git remote get-url origin)
    if ($u -match 'github\.com[:/](.+?)(?:\.git)?$') {
        $webUrl = "https://github.com/$($Matches[1])"
    }
}

Write-Host "`n=== 下一步 ===`n" -ForegroundColor Magenta
if ($webUrl) {
    Write-Host "  1) 打开 Actions：" -NoNewline
    Write-Host "$webUrl/actions" -ForegroundColor Yellow
    Write-Host "  2) 左栏选「Build macOS App」→ 右上 Run workflow → 勾 make_dmg → 绿按钮"
    Write-Host "  3) 约 3~6 分钟，进那次 run，底部 Artifacts 下 Txin-macos-<N>.zip"
    Write-Host "  4) 在 Mac 上下载并解压（别在 Windows 上解压再拷，会丢可执行位）"
    Write-Host "  5) 把 Txin.app 拖进 /Applications，右键 →「打开」放行"
} else {
    Write-Host "  还没有远端。补一条命令："
    Write-Host "  git remote add origin https://github.com/<你>/txin-mac.git" -ForegroundColor Yellow
    Write-Host "  git push -u origin $Branch" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  或者装了 GitHub CLI 的话，重跑："
    Write-Host "  .\push-to-github.ps1 -Create -RepoName txin-mac" -ForegroundColor Yellow
}
Write-Host ""
Pop-Location
