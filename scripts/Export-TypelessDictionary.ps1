# Export-TypelessDictionary.ps1
# Reusable launcher for export_typeless_dictionary.py
#
# Why this exists (2026-11-04): exporting the Typeless dictionary used to be
# re-invented from scratch every time (OCR, clipboard, network capture...).
# Working path: debug port -> VISIBLE hub window -> real wheel events ->
# read visible card text -> verify against total_count.
#
# Usage:
#   .\Export-TypelessDictionary.ps1                            # port already open
#   .\Export-TypelessDictionary.ps1 -Restart                   # restart with debug flags
#   .\Export-TypelessDictionary.ps1 -Restart -RestoreNormal    # then restore normal mode
#
# Notes:
#   * Never restart Typeless unless the user agreed (-Restart is opt-in).
#   * Window must be visible; when hidden, CDP input silently times out.
#   * Only the real hub window (class Chrome_WidgetWin_1) is raised; the
#     UIAutomation helper window is ignored.

param(
  [int]$Port = 9333,
  [switch]$Restart,
  [switch]$RestoreNormal,
  [string]$OutDir = "$env:USERPROFILE\Desktop\Typeless字典匯出",
  [string]$Archive = ""   # 可選：額外複製一份的目的資料夾
)

$ErrorActionPreference = "Stop"
$exe = "$env:LOCALAPPDATA\Programs\Typeless\Typeless.exe"
$py  = Join-Path $PSScriptRoot "export_typeless_dictionary.py"

function Test-Port([int]$p) {
  try { return (Test-NetConnection -ComputerName 127.0.0.1 -Port $p -InformationLevel Quiet -WarningAction SilentlyContinue) }
  catch { return $false }
}

function Stop-Typeless {
  Get-Process Typeless -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 3
}

function Start-TypelessWithDebug([int]$p) {
  Start-Process -FilePath $exe -ArgumentList "--force-renderer-accessibility", "--remote-debugging-port=$p"
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Port $p) {
      Start-Sleep -Seconds 6      # let the renderer finish first paint
      return $true
    }
  }
  return $false
}

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;
public class TyWin {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public struct RECT { public int L,T,R,B; }
  public static long Pick() {
    var pids = new Dictionary<uint,bool>();
    foreach (var p in System.Diagnostics.Process.GetProcessesByName("Typeless")) pids[(uint)p.Id] = true;
    long best = 0; int area = 0;
    EnumWindows((h,l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (!pids.ContainsKey(p)) return true;
      var cls = new StringBuilder(256); GetClassNameW(h, cls, 256);
      if (cls.ToString() != "Chrome_WidgetWin_1") return true;   // hub only, skip helper windows
      var ttl = new StringBuilder(256); GetWindowTextW(h, ttl, 256);
      if (ttl.ToString() != "Typeless") return true;              // skip floating bar ("Status")
      RECT r; GetWindowRect(h, out r);
      int w = r.R-r.L, hh = r.B-r.T;
      if (w >= 800 && hh >= 500 && w*hh > area) { area = w*hh; best = h.ToInt64(); }
      return true;
    }, IntPtr.Zero);
    return best;
  }
  public static string Raise() {
    long best = Pick();
    if (best == 0) return "NO_HUB_WINDOW";
    IntPtr h = new IntPtr(best);
    ShowWindow(h, 9); ShowWindow(h, 5); BringWindowToTop(h);
    IntPtr fg = GetForegroundWindow();
    uint fgT = GetWindowThreadProcessId(fg, IntPtr.Zero);
    uint myT = GetWindowThreadProcessId(h, IntPtr.Zero);
    AttachThreadInput(myT, fgT, true);
    SetForegroundWindow(h);
    AttachThreadInput(myT, fgT, false);
    System.Threading.Thread.Sleep(400);
    RECT r; GetWindowRect(h, out r);
    return "hwnd=" + best + " size=" + (r.R-r.L) + "x" + (r.B-r.T) + " fg=" + (GetForegroundWindow().ToInt64() == best);
  }
}
"@

function Show-TypelessWindow {
  try {
    $r = [TyWin]::Raise()
    if ($r -eq "NO_HUB_WINDOW") {
      # Hub 視窗被關閉（程序還在執行）：再呼叫一次 exe 會由 single-instance 轉發並開回主視窗，
      # 這不是重新啟動，程序與登入狀態都保留。
      Write-Host "hub window closed -> asking running instance to show it"
      Start-Process -FilePath $exe
      Start-Sleep -Seconds 4
      $r = [TyWin]::Raise()
    }
    return $r
  } catch { return "WINDOW_CHECK_FAILED: $($_.Exception.Message)" }
}

if (-not (Test-Path $exe)) { throw "Typeless.exe not found: $exe" }
if (-not (Test-Path $py))  { throw "exporter not found: $py" }
if ($Archive -and -not (Test-Path $Archive)) { Write-Host "WARN archive folder missing: $Archive" }

if ($Restart) {
  Write-Host "STOP  Typeless"
  Stop-Typeless
  Write-Host "START Typeless with debug port $Port"
  if (-not (Start-TypelessWithDebug $Port)) { throw "debug port $Port did not open" }
}

if (-not (Test-Port $Port)) {
  throw "port $Port is closed. Re-run with -Restart (ask the user first), or start Typeless with --remote-debugging-port=$Port"
}

Write-Host "WINDOW $(Show-TypelessWindow)"
Start-Sleep -Milliseconds 800

$cliArgs = @($py, "--port", $Port, "--outdir", $OutDir)
if ($Archive) { $cliArgs += @("--archive", $Archive) }
& python @cliArgs
$code = $LASTEXITCODE

if ($RestoreNormal) {
  Write-Host "RESTORE normal mode"
  Stop-Typeless
  Start-Process -FilePath $exe
  Start-Sleep -Seconds 3
  Write-Host "DEBUG_PORT_OPEN=$(Test-Port $Port)"
}

exit $code
