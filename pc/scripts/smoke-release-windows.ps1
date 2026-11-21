#requires -Version 7.2
<#
.SYNOPSIS
Exercise the release installer on a fresh GitHub-hosted Windows x64 runner.
.EXAMPLE
pwsh -NoProfile -File ./pc/scripts/smoke-release-windows.ps1 -Version 0.1.254 -Installer ./candidate.exe -ExpectedSha256 $auditedHash
.NOTES
Download the draft asset in a preceding step. Pin ExpectedSha256 from the independent
audit receipt. Give this step no secrets, restored profiles, or persisted checkout
credentials. Only upload the report, never the temporary app profile or raw logs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string] $Version,
    [Parameter(Mandatory)][string] $Installer,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string] $ExpectedSha256,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string] $ExpectedExeSha256,
    [string] $ReportPath = (Join-Path $env:RUNNER_TEMP 'windows-smoke-result.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ARCH -ne 'X64' -or
    $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or -not [Environment]::Is64BitProcess) {
    throw 'Use a fresh GitHub-hosted x64 Windows job with pwsh.'
}

$setup = (Resolve-Path -LiteralPath $Installer).ProviderPath
$root = Join-Path $env:RUNNER_TEMP ('hachimi-' + [guid]::NewGuid().ToString('N'))
$install = Join-Path $root 'app'
$userDir = Join-Path $root 'user'
$tempDir = Join-Path $root 'tmp'
$registry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\com.petmanager.desktop'
$exe = Join-Path $install 'Hachimodock.exe'
$uninstaller = Join-Path $install 'Uninstall.exe'
$report = [ordered]@{ version=$version; passed=$false; stage='candidate'; checks=[ordered]@{} }
$gui = $null
$installedHere = $false

# Keep GUI stderr private, drain pipes continuously and retain only the exact native
# confirmation emitted when the loaded frontend completes its startup handshake.
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public sealed class SmokeReady {
    public volatile bool Accepted;
    public void Attach(Process p) {
        p.ErrorDataReceived += (s,e) => { if (e.Data == "[startup-native] category=ready") Accepted = true; };
        p.OutputDataReceived += (s,e) => {};
    }
}
public static class SmokeWindow {
    delegate bool EnumProc(IntPtr hwnd, IntPtr unused);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc fn, IntPtr arg);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint msg,IntPtr w,IntPtr l,uint flags,uint ms,out IntPtr result);
    [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetMenuString(IntPtr menu,uint pos,StringBuilder name,int n,uint flags);
    [DllImport("user32.dll")] static extern uint GetMenuItemID(IntPtr menu,int pos);
    public static IntPtr Owned(int process, string cls) {
        IntPtr found=IntPtr.Zero;
        EnumWindows((h,u)=>{
            uint pid;
            GetWindowThreadProcessId(h,out pid);
            if(pid!=process) return true;
            var name=new StringBuilder(128);
            GetClassName(h,name,name.Capacity);
            if(name.ToString()!=cls) return true;
            found=h; return false;
        },IntPtr.Zero);
        return found;
    }
    [DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread,uint msg,IntPtr w,IntPtr l);
    public static bool QuitLoop(IntPtr main, int expectedPid) {
        uint pid;
        uint thread=GetWindowThreadProcessId(main,out pid);
        return thread!=0 && pid==expectedPid && PostThreadMessage(thread,0x0012,IntPtr.Zero,IntPtr.Zero);
    }
    public static bool OpenTray(IntPtr tray) {
        // tray-icon 0.23.1 uses 6002 for the shell's tray notification.
        return PostMessage(tray,6002,IntPtr.Zero,(IntPtr)0x0205);
    }
    public static bool QuitMenu(IntPtr tray,IntPtr popup) {
        IntPtr menu;
        // MN_GETHMENU for the popup belonging to this candidate process.
        if(SendMessageTimeout(popup,0x01e1,IntPtr.Zero,IntPtr.Zero,2,1000,out menu)==IntPtr.Zero) return false;
        for(int i=0;i<GetMenuItemCount(menu);i++) {
            var name=new StringBuilder(128);
            GetMenuString(menu,(uint)i,name,name.Capacity,0x400);
            if(name.ToString().Replace("&","")!="\u9000\u51fa HachimiDock") continue;
            uint command=GetMenuItemID(menu,i);
            if(command==0 || command>65535) return false;
            PostMessage(tray,0x001f,IntPtr.Zero,IntPtr.Zero);
            return PostMessage(tray,0x0111,(IntPtr)command,IntPtr.Zero);
        }
        return false;
    }
}
'@

function New-SmokeProcess([string]$File, [string[]]$Arguments) {
    $p = [Diagnostics.Process]::new()
    $start = $p.StartInfo
    $start.UseShellExecute = $false
    $start.FileName = $File
    $start.WorkingDirectory = $root
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment.Clear()
    foreach ($name in 'SystemRoot','WINDIR','ComSpec','SystemDrive','ProgramFiles','ProgramFiles(x86)',
                      'ProgramW6432','ProgramData','OS','PROCESSOR_ARCHITECTURE','NUMBER_OF_PROCESSORS') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $start.Environment[$name] = $value }
    }
    $start.Environment['PATH'] = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
    $start.Environment['TEMP'] = $tempDir
    $start.Environment['TMP'] = $tempDir
    $start.Environment['HOME'] = $userDir
    $start.Environment['USERPROFILE'] = $userDir
    $start.Environment['APPDATA'] = Join-Path $userDir 'Roaming'
    $start.Environment['LOCALAPPDATA'] = Join-Path $userDir 'Local'
    $start.Environment['WEBVIEW2_USER_DATA_FOLDER'] = Join-Path $userDir 'WebView'
    foreach ($arg in $Arguments) { $start.ArgumentList.Add($arg) }
    return $p
}

function Invoke-SmokeProcess([string]$File, [string[]]$Arguments, [int]$Timeout = 120, [bool]$Capture = $true) {
    $p = New-SmokeProcess $File $Arguments
    $p.StartInfo.RedirectStandardOutput = $Capture
    $p.StartInfo.RedirectStandardError = $Capture
    try {
        if (!$p.Start()) { throw 'Process did not start' }
        if ($Capture) {
            $out = $p.StandardOutput.ReadToEndAsync()
            $err = $p.StandardError.ReadToEndAsync()
        }
        if (!$p.WaitForExit(1000 * $Timeout)) {
            $p.Kill($true)
            throw 'Candidate operation timed out'
        }
        if ($p.ExitCode -ne 0) { throw "Candidate operation exited with code $($p.ExitCode)" }
        if (!$Capture) { return }
        if (!$out.Wait(5000) -or !$err.Wait(5000)) { throw 'Candidate output did not close' }
        return $out.Result
    } finally { $p.Dispose() }
}

function Wait-For([scriptblock]$Condition, [int]$Seconds) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 250
    } while ($timer.Elapsed.TotalSeconds -lt $Seconds)
    throw "Timed out at $($report.stage)"
}

try {
    $hash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $ExpectedSha256) { throw 'Candidate digest mismatch' }
    $report.installerSha256 = $hash
    if (Test-Path -LiteralPath $registry) { throw 'Existing product registration on runner' }
    foreach ($path in $root,$userDir,$tempDir,(Join-Path $userDir 'Roaming'),(Join-Path $userDir 'Local')) {
        $null = New-Item -ItemType Directory -Path $path
    }
    $report.stage = 'install'
    # NSIS requires the unquoted /D= override last, including paths with spaces.
    $installerProcess = New-SmokeProcess $setup @()
    $installerProcess.StartInfo.Arguments = "/S /D=$install"
    $installerProcess.StartInfo.RedirectStandardOutput = $false
    $installerProcess.StartInfo.RedirectStandardError = $false
    try {
        if (!$installerProcess.Start()) { throw 'Installer did not start' }
        if (!$installerProcess.WaitForExit(240000)) { $installerProcess.Kill($true); throw 'Installer timed out' }
        if ($installerProcess.ExitCode -ne 0) { throw 'Installer returned failure' }
    } finally { $installerProcess.Dispose() }
    $registration = Get-ItemProperty -LiteralPath $registry
    if ($registration.InstallLocation -ne $install -or $registration.DisplayVersion -ne $version) {
        throw 'Installed product registration mismatch'
    }
    $installedHere = $true
    $v = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
    $fixed = '{0}.{1}.{2}.{3}' -f $v.ProductMajorPart,$v.ProductMinorPart,$v.ProductBuildPart,$v.ProductPrivatePart
    if ($fixed -ne "$version.0") { throw 'Installed EXE product version mismatch' }
    $report.exeSha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    if ($ExpectedExeSha256 -and $report.exeSha256 -ne $ExpectedExeSha256) { throw 'Installed EXE digest mismatch' }
    $report.checks.install = $fixed

    $report.stage = 'petui'
    $info = (Invoke-SmokeProcess $exe @('--petui','tool-info')) | ConvertFrom-Json
    if ($info.version -ne $version -or $info.target -ne 'windows-x64' -or $info.protocol -ne 2) {
        throw 'Installed PetUI CLI identity mismatch'
    }
    $doctor = (Invoke-SmokeProcess $exe @('--petui','doctor')) | ConvertFrom-Json
    if ($doctor.ok -ne $true -or $doctor.wasmBytes -le 0) { throw 'Bundled compiler did not produce WASM' }
    $sample = Join-Path $install 'skills\petui\examples\local-notebook'
    $packed = Join-Path $root 'notebook.hachiapp'
    $null = Invoke-SmokeProcess $exe @('--petui','pack',$sample,$packed)
    $null = Invoke-SmokeProcess $exe @('--petui','validate',$packed)
    $rehearsal = (Invoke-SmokeProcess $exe @('--petui','install-rehearsal',$packed)) | ConvertFrom-Json
    if ($rehearsal.component -ne 'local-notebook' -or $rehearsal.firstOpen -ne 'library-entry-verified') {
        throw 'PetUI temporary library rehearsal failed'
    }
    $report.checks.petui = @{target=$info.target; wasmBytes=$doctor.wasmBytes; rehearsal=$rehearsal.firstOpen}

    # Use the exact shipped compiler and checker for the native regression suite.
    $testResources = Join-Path $env:RUNNER_TEMP 'petui-release-resources'
    $null = New-Item -ItemType Directory -Path $testResources
    foreach ($resource in 'authoring-runtime','skills') {
        Copy-Item -LiteralPath (Join-Path $install $resource) -Destination $testResources -Recurse
    }

    $report.stage = 'gui'
    $gui = New-SmokeProcess $exe @()
    $ready = [SmokeReady]::new()
    $ready.Attach($gui)
    if (!$gui.Start()) { throw 'GUI did not start' }
    $gui.BeginErrorReadLine()
    $gui.BeginOutputReadLine()
    Wait-For {
        $gui.Refresh()
        if ($gui.HasExited) { throw 'GUI exited during startup' }
        $ready.Accepted -and $gui.MainWindowHandle -ne [IntPtr]::Zero -and
            [SmokeWindow]::IsWindowVisible($gui.MainWindowHandle) -and $gui.Responding
    } 60
    $report.checks.gui = 'visible-responsive-window-and-native-frontend-ready'

    $report.stage = 'exit'
    $mainWindow = $gui.MainWindowHandle
    $tray = [SmokeWindow]::Owned($gui.Id,'tray_icon_app')
    $quitMode = 'tray-menu'
    $menuInvoked = $false
    if ($tray -ne [IntPtr]::Zero -and [SmokeWindow]::OpenTray($tray)) {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        do {
            $popup = [SmokeWindow]::Owned($gui.Id,'#32768')
            if ($popup -ne [IntPtr]::Zero) {
                if (![SmokeWindow]::QuitMenu($tray,$popup)) { throw 'Candidate tray Quit command unavailable' }
                $menuInvoked = $true
                break
            }
            Start-Sleep -Milliseconds 200
        } while ($timer.Elapsed.TotalSeconds -lt 8)
    }
    if (!$menuInvoked) {
        # Hosted sessions can lack an Explorer notification area. Exercise the
        # candidate GUI thread's normal message-loop termination in that case.
        $quitMode = 'win32-message-loop'
        if (![SmokeWindow]::QuitLoop($mainWindow,$gui.Id)) { throw 'Could not request GUI thread exit' }
    }
    if (!$gui.WaitForExit(30000) -or $gui.ExitCode -ne 0) { throw 'Candidate did not quit cleanly' }
    $report.checks.exit = $quitMode

} catch {
    $report.failureStage = $report.stage
} finally {
    if ($gui) {
        try { if (!$gui.HasExited) { $gui.Kill($true); $null = $gui.WaitForExit(10000) } } catch {}
        $gui.Dispose()
    }
    if ($installedHere) {
        try {
            $report.stage = 'uninstall'
            $null = Invoke-SmokeProcess $uninstaller @('/S') 90 $false
            Wait-For { !(Test-Path -LiteralPath $install) -and !(Test-Path -LiteralPath $registry) } 45
            $report.checks.uninstall = 'files-and-registration-removed'
        } catch { $report.uninstallFailed = $true }
    }
    $report.passed = $report.checks.Contains('exit') -and $report.checks.Contains('uninstall') -and !$report.Contains('failureStage')
    $report.stage = 'finished'
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReportPath -Encoding utf8
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
if (!$report.passed) { throw 'Windows smoke failed. See the sanitized JSON report.' }
Write-Output "Windows $version smoke passed."
