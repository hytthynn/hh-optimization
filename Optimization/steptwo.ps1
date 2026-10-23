        # SCRIPT RUN AS ADMIN
        If (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator"))
        {Start-Process PowerShell.exe -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $PSCommandPath) -Verb RunAs
        Exit}
        $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + " (Administrator)"
        $Host.UI.RawUI.BackgroundColor = "Black"
        $Host.PrivateData.ProgressBackgroundColor = "Black"
        $Host.PrivateData.ProgressForegroundColor = "White"
        Clear-Host

        # FUNCTION RUN AS TRUSTED INSTALLER
        function Run-Trusted([String]$command) {
        try {
    	Stop-Service -Name TrustedInstaller -Force -ErrorAction Stop -WarningAction Stop
  		}
  		catch {
    	taskkill /im trustedinstaller.exe /f >$null
  		}
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='TrustedInstaller'"
        $DefaultBinPath = $service.PathName
  		$trustedInstallerPath = "$env:SystemRoot\servicing\TrustedInstaller.exe"
  		if ($DefaultBinPath -ne $trustedInstallerPath) {
    	$DefaultBinPath = $trustedInstallerPath
  		}
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($command)
        $base64Command = [Convert]::ToBase64String($bytes)
        sc.exe config TrustedInstaller binPath= "cmd.exe /c powershell.exe -encodedcommand $base64Command" | Out-Null
        sc.exe start TrustedInstaller | Out-Null
        sc.exe config TrustedInstaller binpath= "`"$DefaultBinPath`"" | Out-Null
        try {
    	Stop-Service -Name TrustedInstaller -Force -ErrorAction Stop -WarningAction Stop
  		}
  		catch {
    	taskkill /im trustedinstaller.exe /f >$null
  		}
        }
		
        # SCRIPT SILENT
        $progresspreference = 'silentlycontinue'

        Write-Host "REMOVE EDGE BROWSER; KEEP WEBVIEW`n"
# BEGIN embedded Edge browser removal
& {
# Remove ONLY the Edge browser. Keep WebView, EdgeCore and shared EdgeUpdate.
$ErrorActionPreference = 'Stop'
function Write-EdgeStatus([string]$Message) { Write-Host $Message }
$edgeRoots = @(
    $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application' }),
    $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Microsoft\Edge\Application' }),
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application' })
) | Where-Object { $_ } | Select-Object -Unique
function Test-BrowserPath([string]$Path) {
    if (-not $Path) { return $false }
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($root in $edgeRoots) {
        if ($full.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
function Remove-BrowserNode([string]$Path) {
    if (-not (Test-BrowserPath $Path)) { throw "Refusing deletion outside browser Application tree: $Path" }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $isDirectory = ($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        # Unlink junction/symlink itself; NEVER traverse into EdgeCore or WebView.
        if ($isDirectory) { [IO.Directory]::Delete($Path,$false) } else { [IO.File]::Delete($Path) }
        return
    }
    # Grant rights to THIS node only. No recursive takeown/icacls through links.
    & takeown.exe /f $Path /a 2>&1 | Out-Null
    $ownershipCode = $LASTEXITCODE
    & icacls.exe $Path /grant '*S-1-5-32-544:F' /q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-EdgeStatus "ACL grant failed: $Path; takeown=$ownershipCode; icacls=$LASTEXITCODE" }
    if ($isDirectory) {
        foreach ($child in [IO.Directory]::GetFileSystemEntries($Path)) { Remove-BrowserNode $child }
        [IO.Directory]::Delete($Path,$false)
    } else {
        [IO.File]::SetAttributes($Path,[IO.FileAttributes]::Normal)
        [IO.File]::Delete($Path)
    }
}
Write-EdgeStatus 'BEGIN browser removal; shared runtime/updater/core are excluded.'
try {
    # Stop only msedge.exe from a known browser tree, never msedgewebview2.exe.
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue)) {
        if (Test-BrowserPath $process.ExecutablePath) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    $candidates = New-Object Collections.Generic.List[object]
    foreach ($regPath in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge')) {
        $info = Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue
        if ($info -and $info.UninstallString) {
            $line = [string]$info.UninstallString; $exe = $null; $arguments = ''
            if ($line -match '^\s*"([^"]+\.exe)"\s*(.*)$') { $exe=$Matches[1]; $arguments=$Matches[2] }
            elseif ($line -match '^\s*(.+?\.exe)(?:\s+(.*))?$') { $exe=$Matches[1]; $arguments=$Matches[2] }
            if ($exe -and (Test-BrowserPath $exe) -and (Test-Path -LiteralPath $exe -PathType Leaf)) {
                $candidates.Add([pscustomobject]@{Exe=$exe;Args=$arguments;UserInstall=$regPath.StartsWith('HKCU:')})
            }
        }
    }
    foreach ($root in $edgeRoots) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            foreach ($version in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' }) {
                $setup = Join-Path $version.FullName 'Installer\setup.exe'
                if (Test-Path -LiteralPath $setup -PathType Leaf) { $candidates.Add([pscustomobject]@{Exe=$setup;Args='';UserInstall=$root.StartsWith($env:LOCALAPPDATA,[StringComparison]::OrdinalIgnoreCase)}) }
            }
        }
    }
    $tried = @{}
    foreach ($candidate in $candidates) {
        if ($tried.ContainsKey($candidate.Exe)) { continue }; $tried[$candidate.Exe]=$true
        $arguments = [string]$candidate.Args
        foreach ($flag in @('--uninstall','--msedge','--channel=stable','--force-uninstall')) {
            if ($arguments -notmatch [regex]::Escape($flag)) { $arguments += ' ' + $flag }
        }
        if (-not $candidate.UserInstall -and $arguments -notmatch '--system-level') { $arguments += ' --system-level' }
        try {
            # Direct executable invocation fixes the old cmd /c quoting bug.
            $result = Start-Process -FilePath $candidate.Exe -ArgumentList $arguments.Trim() -Wait -PassThru
            Write-EdgeStatus ("Uninstaller exit=$($result.ExitCode); executable=$($candidate.Exe)")
        } catch { Write-EdgeStatus ('Uninstaller error: '+$_.Exception.Message) }
    }
    # Some Windows builds refuse force-uninstall. Bounded file fallback removes
    # browser Application trees only, never Microsoft, EdgeCore, EdgeUpdate or WebView.
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue)) {
        if (Test-BrowserPath $process.ExecutablePath) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    foreach ($root in $edgeRoots) {
        if (Test-Path -LiteralPath $root) {
            try {
                $ancestor = Split-Path -Parent $root
                while ($ancestor -and (Split-Path -Parent $ancestor) -ne $ancestor) {
                    $parentItem = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
                    if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing browser cleanup through parent reparse point: $ancestor" }
                    $ancestor = Split-Path -Parent $ancestor
                }
                Remove-BrowserNode $root; Write-EdgeStatus "Removed browser-only tree: $root" }
            catch { Write-EdgeStatus "ERROR deleting ${root}: $($_.Exception.Message)" }
        }
    }
    $remaining = @($edgeRoots | Where-Object { Test-Path -LiteralPath $_ })
    if ($remaining.Count) { throw ('Browser tree still exists (possibly partly removed): '+($remaining -join '; ')) }
    # Remove only shortcuts whose resolved target is a browser executable.
    $shortcutFolders = @([Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('CommonDesktopDirectory'),[Environment]::GetFolderPath('Programs'),[Environment]::GetFolderPath('CommonPrograms'))
    $shortcutShell = New-Object -ComObject WScript.Shell
    foreach ($folder in $shortcutFolders | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique) {
        foreach ($shortcut in Get-ChildItem -LiteralPath $folder -Filter '*Edge*.lnk' -File -ErrorAction SilentlyContinue) {
            $link = $shortcutShell.CreateShortcut($shortcut.FullName)
            if (Test-BrowserPath $link.TargetPath) { Remove-Item -LiteralPath $shortcut.FullName -Force }
        }
    }
    # Browser-only update policy. WebView has a different product GUID.
    $policy=[Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\Policies\Microsoft\EdgeUpdate')
    try {
        $policy.SetValue('Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}',0,[Microsoft.Win32.RegistryValueKind]::DWord)
        $policy.SetValue('Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}',0,[Microsoft.Win32.RegistryValueKind]::DWord)
    } finally { $policy.Dispose() }
    Write-EdgeStatus 'DONE: known browser Application trees are absent. WebView, EdgeCore and EdgeUpdate directories were not removed. Browser profile data was not deleted.'
} catch {
    Write-EdgeStatus ('ERROR: '+$_.Exception.Message+' | '+$_.ScriptStackTrace)
    Write-Warning ('Edge removal incomplete: '+$_.Exception.Message)
}
}
# END embedded Edge browser removal

        Write-Host "REMOVE UWP APPS`n"
        ## ms-settings:appsfeatures
        ## powershell -noexit -command "get-appxpackage | select name | format-table -autosize"

Get-AppXPackage -AllUsers | Where-Object {
# Preserve requested apps and their dependencies.
-not $_.IsFramework -and -not $_.NonRemovable -and
$_.Name -notlike '*Microsoft.WindowsCalculator*' -and
$_.Name -notlike '*Microsoft.WindowsTerminal*' -and
$_.Name -notlike '*WebView*' -and
# breaks file explorer
$_.Name -notlike '*CBS*' -and
$_.Name -notlike '*Microsoft.AV1VideoExtension*' -and
$_.Name -notlike '*Microsoft.AVCEncoderVideoExtension*' -and
$_.Name -notlike '*Microsoft.HEIFImageExtension*' -and
$_.Name -notlike '*Microsoft.HEVCVideoExtension*' -and
$_.Name -notlike '*Microsoft.MPEG2VideoExtension*' -and
$_.Name -notlike '*Microsoft.Paint*' -and
$_.Name -notlike '*Microsoft.RawImageExtension*' -and
# breaks windows server defender
$_.Name -notlike '*Microsoft.SecHealthUI*' -and
$_.Name -notlike '*Microsoft.VP9VideoExtensions*' -and
$_.Name -notlike '*Microsoft.WebMediaExtensions*' -and
$_.Name -notlike '*Microsoft.WebpImageExtension*' -and
$_.Name -notlike '*Microsoft.Windows.Photos*' -and
# breaks windows server task bar
$_.Name -notlike '*Microsoft.Windows.ShellExperienceHost*' -and
# breaks windows server start menu
$_.Name -notlike '*Microsoft.Windows.StartMenuExperienceHost*' -and
$_.Name -notlike '*Microsoft.WindowsNotepad*' -and
$_.Name -notlike '*Microsoft.WindowsStore*' -and
$_.Name -notlike '*NVIDIACorp.NVIDIAControlPanel*' -and
# breaks windows server immersive control panel
$_.Name -notlike '*windows.immersivecontrolpanel*'
} | Remove-AppxPackage -ErrorAction SilentlyContinue

        Write-Host "REMOVE UWP FEATURES`n"
        ## ms-settings:optionalfeatures
        ## powershell -noexit -command "dism /online /get-capabilities /format:table"

Get-WindowsCapability -Online | Where-Object {
$_.Name -notlike 'OpenSSH.Client*' -and
$_.Name -notlike '*Microsoft.Windows.Ethernet*' -and
# windows 10
$_.Name -notlike '*Microsoft.Windows.MSPaint*' -and
# windows 10
$_.Name -notlike '*Microsoft.Windows.Notepad*' -and
$_.Name -notlike '*Microsoft.Windows.Notepad.System*' -and
$_.Name -notlike '*Microsoft.Windows.Wifi*' -and
$_.Name -notlike '*NetFX3*' -and
# windows 11 breaks msi installers if removed
$_.Name -notlike '*VBSCRIPT*' -and
# breaks monitoring programs
$_.Name -notlike '*WMIC*' -and
# windows 10 breaks uwp snippingtool if removed
$_.Name -notlike '*Windows.Client.ShellComponents*'
} | ForEach-Object {
try {
Remove-WindowsCapability -Online -Name $_.Name | Out-Null
} catch { }
}

        Write-Host "REMOVE LEGACY FEATURES`n"
        ## c:\windows\system32\optionalfeatures.exe
		## powershell -noexit -command "dism /online /get-features /format:table"

Get-WindowsOptionalFeature -Online | Where-Object {
$_.FeatureName -notlike '*DirectPlay*' -and
$_.FeatureName -notlike '*LegacyComponents*' -and
$_.FeatureName -notlike '*NetFx3*' -and
# breaks windows server turn windows features on or off
$_.FeatureName -notlike '*NetFx4*' -and
$_.FeatureName -notlike '*NetFx4-AdvSrvs*' -and
# breaks windows server turn windows features on or off
$_.FeatureName -notlike '*NetFx4ServerFeatures*' -and
# breaks search
$_.FeatureName -notlike '*SearchEngine-Client-Package*' -and
# breaks windows server desktop
$_.FeatureName -notlike '*Server-Shell*' -and
# breaks windows server defender
$_.FeatureName -notlike '*Windows-Defender*' -and
# breaks windows server internet
$_.FeatureName -notlike '*Server-Drivers-General*' -and
# breaks windows server internet
$_.FeatureName -notlike '*ServerCore-Drivers-General*' -and
# breaks windows server internet
$_.FeatureName -notlike '*ServerCore-Drivers-General-WOW64*' -and
# breaks windows server turn windows features on or off
$_.FeatureName -notlike '*Server-Gui-Mgmt*' -and
# breaks windows server nvidia app
$_.FeatureName -notlike '*WirelessNetworking*'
} | ForEach-Object {
try {
Disable-WindowsOptionalFeature -Online -FeatureName $_.FeatureName -NoRestart -WarningAction SilentlyContinue | Out-Null
} catch { }
}

		Write-Host "REMOVE LEGACY APPS`n"
		## appwiz.cpl

# uninstall brlapi
cmd /c "sc stop `"brlapi`" >nul 2>&1"
cmd /c "sc delete `"brlapi`" >nul 2>&1"
cmd /c "takeown /f `"$env:SystemRoot\brltty`" /r /d y >nul 2>&1"
cmd /c "icacls `"$env:SystemRoot\brltty`" /grant *S-1-5-32-544:F /t >nul 2>&1"
Remove-Item "$env:SystemRoot\brltty" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

# uninstall microsoft gameinput
$findmicrosoftgameinput = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
$microsoftgameinput = Get-ItemProperty $findmicrosoftgameinput -ErrorAction SilentlyContinue |
Where-Object { $_.DisplayName -like "*Microsoft GameInput*" }
if ($microsoftgameinput) {
$guid = $microsoftgameinput.PSChildName
Start-Process "msiexec.exe" -ArgumentList "/x $guid /qn /norestart" -Wait -NoNewWindow
}

# stop onedrive running
Stop-Process -Force -Name OneDrive -ErrorAction SilentlyContinue | Out-Null

# uninstall onedrive
cmd /c "C:\Windows\System32\OneDriveSetup.exe -uninstall >nul 2>&1"
# uninstall office 365 onedrive
Get-ChildItem -Path "C:\Program Files*\Microsoft OneDrive", "$env:LOCALAPPDATA\Microsoft\OneDrive" -Filter "OneDriveSetup.exe" -Recurse -ErrorAction SilentlyContinue |
ForEach-Object { Start-Process -Wait $_.FullName -ArgumentList "/uninstall /allusers" -WindowStyle Hidden -ErrorAction SilentlyContinue }
# windows 10 uninstall onedrive
cmd /c "C:\Windows\SysWOW64\OneDriveSetup.exe -uninstall >nul 2>&1"
# windows 10 remove onedrive scheduled tasks
Get-ScheduledTask | Where-Object {$_.Taskname -match 'OneDrive'} | Unregister-ScheduledTask -Confirm:$false

# uninstall remote desktop connection
try {
Start-Process "mstsc" -ArgumentList "/Uninstall" -ErrorAction SilentlyContinue
} catch { }
# silent window for remote desktop connection
$processExists = Get-Process -Name mstsc -ErrorAction SilentlyContinue
if ($processExists) {
$running = $true
$timeout = 0
do {
$mstscProcess = Get-Process -Name mstsc -ErrorAction SilentlyContinue
if ($mstscProcess -and $mstscProcess.MainWindowHandle -ne 0) {
Stop-Process -Force -Name mstsc -ErrorAction SilentlyContinue | Out-Null
$running = $false
}
Start-Sleep -Milliseconds 100
$timeout++
if ($timeout -gt 100) {
Stop-Process -Name mstsc -Force -ErrorAction SilentlyContinue
$running = $false
}
} while ($running)
}
Start-Sleep -Seconds 1

# windows 10 uninstall old snipping tool
try {
Start-Process "C:\Windows\System32\SnippingTool.exe" -ArgumentList "/Uninstall" -ErrorAction SilentlyContinue
} catch { }
# silent window for uninstall old snipping tool
$processExists = Get-Process -Name SnippingTool -ErrorAction SilentlyContinue
if ($processExists) {
$running = $true
$timeout = 0
do {
$snipProcess = Get-Process -Name SnippingTool -ErrorAction SilentlyContinue
if ($snipProcess -and $snipProcess.MainWindowHandle -ne 0) {
Stop-Process -Force -Name SnippingTool -ErrorAction SilentlyContinue | Out-Null
$running = $false
}
Start-Sleep -Milliseconds 100
$timeout++
if ($timeout -gt 100) {
Stop-Process -Name SnippingTool -Force -ErrorAction SilentlyContinue
$running = $false
}
} while ($running)
}
Start-Sleep -Seconds 1

# windows 10 uninstall update for windows 10 for x64-based systems
$findupdateforwindows = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
$updateforwindows = Get-ItemProperty $findupdateforwindows -ErrorAction SilentlyContinue |
Where-Object { $_.DisplayName -like "*Update for x64-based Windows Systems*" }
if ($updateforwindows) {
$guid = $updateforwindows.PSChildName
Start-Process "msiexec.exe" -ArgumentList "/x $guid /qn /norestart" -Wait -NoNewWindow
}

# windows 10 uninstall microsoft update health tools
$findupdatehealthtools = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
$updatehealthtools = Get-ItemProperty $findupdatehealthtools -ErrorAction SilentlyContinue |
Where-Object { $_.DisplayName -like "*Microsoft Update Health Tools*" }
if ($updatehealthtools) {
$guid = $updatehealthtools.PSChildName
Start-Process "msiexec.exe" -ArgumentList "/x $guid /qn /norestart" -Wait -NoNewWindow
}
cmd /c "reg delete `"HKLM\SYSTEM\ControlSet001\Services\uhssvc`" /f >nul 2>&1"
Unregister-ScheduledTask -TaskName PLUGScheduler -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

# remove 3rd party startup apps
## taskmgr /0 /startup
## ms-settings:startupapps
cmd /c "reg delete `"HKCU\Software\Microsoft\Windows\CurrentVersion\RunNotification`" /f >nul 2>&1"
cmd /c "reg add `"HKCU\Software\Microsoft\Windows\CurrentVersion\RunNotification`" /f >nul 2>&1"
cmd /c "reg delete `"HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce`" /f >nul 2>&1"
cmd /c "reg add `"HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce`" /f >nul 2>&1"
cmd /c "reg delete `"HKCU\Software\Microsoft\Windows\CurrentVersion\Run`" /f >nul 2>&1"
cmd /c "reg add `"HKCU\Software\Microsoft\Windows\CurrentVersion\Run`" /f >nul 2>&1"
cmd /c "reg delete `"HKLM\Software\Microsoft\Windows\CurrentVersion\RunOnce`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\Software\Microsoft\Windows\CurrentVersion\RunOnce`" /f >nul 2>&1"
cmd /c "reg delete `"HKLM\Software\Microsoft\Windows\CurrentVersion\Run`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\Software\Microsoft\Windows\CurrentVersion\Run`" /f >nul 2>&1"
cmd /c "reg delete `"HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce`" /f >nul 2>&1"
cmd /c "reg delete `"HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run`" /f >nul 2>&1"
Remove-Item -Recurse -Force "$env:AppData\Microsoft\Windows\Start Menu\Programs\Startup" -ErrorAction SilentlyContinue | Out-Null
Remove-Item -Recurse -Force "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp" -ErrorAction SilentlyContinue | Out-Null
New-Item -Path "$env:AppData\Microsoft\Windows\Start Menu\Programs\Startup" -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
New-Item -Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp" -ItemType Directory -ErrorAction SilentlyContinue | Out-Null

# remove 3rd party scheduled tasks
## taskschd.msc
## regedit HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree
## C:\Windows\System32\Tasks
$treePath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree"
Get-ChildItem $treePath | Where-Object { $_.PSChildName -ne "Microsoft" -and $_.PSChildName -notmatch "EdgeUpdate|WebView" } | ForEach-Object {
Run-Trusted "Remove-Item '$($_.PSPath)' -Recurse -Force"
}

$tasksPath = "$env:SystemRoot\System32\Tasks"
Get-ChildItem $tasksPath | Where-Object { $_.Name -ne "Microsoft" -and $_.Name -notmatch "EdgeUpdate|WebView" } | ForEach-Object {
Remove-Item $_.FullName -Recurse -Force
}

        Write-Host "STORE SETTINGS`n"
        ## ms-windows-store:settings

# open store settings page so disable personalized experiences on ms account sticks
try {
Start-Process "ms-windows-store:settings"
} catch { }
Start-Sleep -Seconds 5

# stop store running
$stop = "WinStore.App", "backgroundTaskHost", "StoreDesktopExtension"
$stop | ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

# disable apps updates
cmd /c "reg add `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate`" /v `"AutoDownload`" /t REG_DWORD /d `"2`" /f >nul 2>&1"

# create reg file
$storesettings = @'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\Settings\LocalState]
; disable video autoplay
"VideoAutoplay"=hex(5f5e10b):00,96,9d,69,8d,cd,93,dc,01
; disable notifications for app installations
"EnableAppInstallNotifications"=hex(5f5e10b):00,36,d0,88,8e,cd,93,dc,01

[HKEY_LOCAL_MACHINE\Settings\LocalState\PersistentSettings]
; disable personalized experiences
"PersonalizationEnabled"=hex(5f5e10b):00,0d,56,a1,8a,cd,93,dc,01
'@
Set-Content -Path "$env:ProgramData\hh-optimization\Runtime\windowsstore.reg" -Value $storesettings -Force
$settingsdat = "$env:LocalAppData\Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\Settings\settings.dat"
$regfilewindowsstore = "$env:ProgramData\hh-optimization\Runtime\windowsstore.reg"

# load hive
reg load "HKLM\Settings" $settingsdat >$null 2>&1

# import reg file
if ($LASTEXITCODE -eq 0) {
reg import $regfilewindowsstore >$null 2>&1

# unload hive
[gc]::Collect()
Start-Sleep -Seconds 2
reg unload "HKLM\Settings" >$null 2>&1
}

		Write-Host "WINDOWS SETTINGS`n"
		## regedit
		## control
        ## ms-settings:
        ## ms-settings:privacy
		## ms-settings:backup
		
# fix 1 for turn off privacy & security app permissions
# stop cam service and remove the database
Stop-Service -Name 'camsvc' -Force -ErrorAction SilentlyContinue
$capabilityconsentstoragedb = "Remove-item `"$env:ProgramData\Microsoft\Windows\CapabilityAccessManager\CapabilityConsentStorage.db*`" -Force"
Run-Trusted -command $capabilityconsentstoragedb

# fix for disable windows backup
cmd /c "reg add `"HKLM\SYSTEM\ControlSet001\Services\CDPUserSvc`" /v `"Start`" /t REG_DWORD /d `"4`" /f >nul 2>&1"

# import steptwo reg file
Start-Process -Wait "regedit.exe" -ArgumentList "/S `"$env:ProgramData\hh-optimization\Runtime\reg.reg`"" -WindowStyle Hidden

# disable gamebarpresencewriter.exe
Run-Trusted -command "reg add `"HKLM\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter`" /v `"ActivationType`" /t REG_DWORD /d `"0`" /f"

# fix 2 for turn off privacy & security app permissions
# stop cam service and remove the database
Stop-Service -Name 'camsvc' -Force -ErrorAction SilentlyContinue
$capabilityconsentstoragedb = "Remove-item `"$env:ProgramData\Microsoft\Windows\CapabilityAccessManager\CapabilityConsentStorage.db*`" -Force"
Run-Trusted -command $capabilityconsentstoragedb

# disable memorycompression
## powershell -noexit -command "get-mmagent"
Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null

# disable bitlocker
## control /name microsoft.bitlockerdriveencryption
try {
Get-BitLockerVolume |
Where-Object {
$_.ProtectionStatus -eq "On" -or $_.VolumeStatus -ne "FullyDecrypted"
} |
ForEach-Object {
Disable-BitLocker -MountPoint $_.MountPoint -ErrorAction SilentlyContinue | Out-Null
}
} catch { }

# smartscreen for microsoft edge - needs normal boot as admin
cmd /c "reg add `"HKEY_CURRENT_USER\SOFTWARE\Microsoft\Edge\SmartScreenEnabled`" /ve /t REG_DWORD /d `"0`" /f >nul 2>&1"

# smartscreen for microsoft store apps - needs normal boot as admin
cmd /c "reg add `"HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost`" /v `"EnableWebContentEvaluation`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# disable scheduled tasks - needs normal boot as admin
## powershell -noexit -command "get-scheduledtask | where-object {$_.taskname -like '*defender*' -or $_.taskname -like '*exploitguard*'} | format-table taskname, state -autosize"
schtasks /Change /TN "Microsoft\Windows\ExploitGuard\ExploitGuard MDM policy Refresh" /Disable 2>$null | Out-Null
schtasks /Change /TN "Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance" /Disable 2>$null | Out-Null
schtasks /Change /TN "Microsoft\Windows\Windows Defender\Windows Defender Cleanup" /Disable 2>$null | Out-Null
schtasks /Change /TN "Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan" /Disable 2>$null | Out-Null
schtasks /Change /TN "Microsoft\Windows\Windows Defender\Windows Defender Verification" /Disable 2>$null | Out-Null

# disable defragment and optimize your drives scheduled task
## powershell -noexit -command "get-scheduledtask -taskname "scheduleddefrag" | select-object taskname, state"
## dfrgui
Get-ScheduledTask | Where-Object {$_.TaskName -match 'ScheduledDefrag'} | Disable-ScheduledTask | Out-Null

# disable all network adapters except ipv4
## powershell -noexit -command "get-netadapterbinding | select-object name, displayname, componentid, enabled | format-table -autosize"
## ncpa.cpl
$adapterstodisable = @('ms_lldp', 'ms_lltdio', 'ms_implat', 'ms_rspndr', 'ms_tcpip6', 'ms_server', 'ms_msclient', 'ms_pacer')
foreach ($adapterbinding in $adapterstodisable) {
Disable-NetAdapterBinding -Name "*" -ComponentID $adapterbinding -ErrorAction SilentlyContinue
}

# No Windows Update pause: USB installation already applies blocking policies.

# block all windows driver updates
## ms-settings:windowsupdate
reg add "HKLM\Software\Policies\Microsoft\Windows\Device Metadata" /v "PreventDeviceMetadataFromNetwork" /t REG_DWORD /d 1 /f | Out-Null
reg add "HKLM\Software\Policies\Microsoft\Windows\DeviceInstall\Settings" /v "DisableSendGenericDriverNotFoundToWER" /t REG_DWORD /d 1 /f | Out-Null
reg add "HKLM\Software\Policies\Microsoft\Windows\DeviceInstall\Settings" /v "DisableSendRequestAdditionalSoftwareToWER" /t REG_DWORD /d 1 /f | Out-Null
reg add "HKLM\Software\Policies\Microsoft\Windows\DriverSearching" /v "SearchOrderConfig" /t REG_DWORD /d 0 /f | Out-Null
reg add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v "SetAllowOptionalContent" /t REG_DWORD /d 0 /f | Out-Null
reg add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v "AllowTemporaryEnterpriseFeatureControl" /t REG_DWORD /d 0 /f | Out-Null
reg add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v "ExcludeWUDriversInQualityUpdate" /t REG_DWORD /d 1 /f | Out-Null
reg add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU" /v "IncludeRecommendedUpdates" /t REG_DWORD /d 0 /f | Out-Null
reg add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU" /v "EnableFeaturedSoftware" /t REG_DWORD /d 0 /f | Out-Null

# disable if you've been away, when should windows require you to sign in again?
## ms-settings:signinoptions
powercfg /setdcvalueindex scheme_current sub_none consolelock 0 2>$null
powercfg /setacvalueindex scheme_current sub_none consolelock 0 2>$null

# disable set priority notifications
## ms-settings:notifications

# create reg file
$disableprioritynotificationsregcontent = @"
Windows Registry Editor Version 5.00

; disable set priority notifications
"@
$disableprioritynotificationsguid = Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current" -ErrorAction SilentlyContinue |
Where-Object { $_.PSChildName -match '^\{[a-f0-9-]+\}\$' } |
ForEach-Object { ($_.PSChildName -split '\$')[0] } |
Select-Object -Unique
foreach ($guid in $disableprioritynotificationsguid) {
$disableprioritynotificationsregcontent += "`n`n[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\$guid`$windows.data.donotdisturb.quiethoursprofile`$quiethoursprofilelist\windows.data.donotdisturb.quiethoursprofile`$microsoft.quiethoursprofile.priorityonly]`n"
$disableprioritynotificationsregcontent += '"Data"=hex(3):43,42,01,00,0A,02,01,00,2A,06,DF,B8,B4,CC,06,2A,2B,0E,D0,03,\' + "`n"
$disableprioritynotificationsregcontent += '  43,42,01,00,C2,0A,01,CD,14,06,02,05,00,00,01,01,02,00,03,01,04,00,CC,32,12,\' + "`n"
$disableprioritynotificationsregcontent += '  05,28,4D,00,69,00,63,00,72,00,6F,00,73,00,6F,00,66,00,74,00,2E,00,53,00,63,\' + "`n"
$disableprioritynotificationsregcontent += '  00,72,00,65,00,65,00,6E,00,53,00,6B,00,65,00,74,00,63,00,68,00,5F,00,38,00,\' + "`n"
$disableprioritynotificationsregcontent += '  77,00,65,00,6B,00,79,00,62,00,33,00,64,00,38,00,62,00,62,00,77,00,65,00,21,\' + "`n"
$disableprioritynotificationsregcontent += '  00,41,00,70,00,70,00,29,4D,00,69,00,63,00,72,00,6F,00,73,00,6F,00,66,00,74,\' + "`n"
$disableprioritynotificationsregcontent += '  00,2E,00,57,00,69,00,6E,00,64,00,6F,00,77,00,73,00,41,00,6C,00,61,00,72,00,\' + "`n"
$disableprioritynotificationsregcontent += '  6D,00,73,00,5F,00,38,00,77,00,65,00,6B,00,79,00,62,00,33,00,64,00,38,00,62,\' + "`n"
$disableprioritynotificationsregcontent += '  00,62,00,77,00,65,00,21,00,41,00,70,00,70,00,31,4D,00,69,00,63,00,72,00,6F,\' + "`n"
$disableprioritynotificationsregcontent += '  00,73,00,6F,00,66,00,74,00,2E,00,58,00,62,00,6F,00,78,00,41,00,70,00,70,00,\' + "`n"
$disableprioritynotificationsregcontent += '  5F,00,38,00,77,00,65,00,6B,00,79,00,62,00,33,00,64,00,38,00,62,00,62,00,77,\' + "`n"
$disableprioritynotificationsregcontent += '  00,65,00,21,00,4D,00,69,00,63,00,72,00,6F,00,73,00,6F,00,66,00,74,00,2E,00,\' + "`n"
$disableprioritynotificationsregcontent += '  58,00,62,00,6F,00,78,00,41,00,70,00,70,00,2D,4D,00,69,00,63,00,72,00,6F,00,\' + "`n"
$disableprioritynotificationsregcontent += '  73,00,6F,00,66,00,74,00,2E,00,58,00,62,00,6F,00,78,00,47,00,61,00,6D,00,69,\' + "`n"
$disableprioritynotificationsregcontent += '  00,6E,00,67,00,4F,00,76,00,65,00,72,00,6C,00,61,00,79,00,5F,00,38,00,77,00,\' + "`n"
$disableprioritynotificationsregcontent += '  65,00,6B,00,79,00,62,00,33,00,64,00,38,00,62,00,62,00,77,00,65,00,21,00,41,\' + "`n"
$disableprioritynotificationsregcontent += '  00,70,00,70,00,29,57,00,69,00,6E,00,64,00,6F,00,77,00,73,00,2E,00,53,00,79,\' + "`n"
$disableprioritynotificationsregcontent += '  00,73,00,74,00,65,00,6D,00,2E,00,4E,00,65,00,61,00,72,00,53,00,68,00,61,00,\' + "`n"
$disableprioritynotificationsregcontent += '  72,00,65,00,45,00,78,00,70,00,65,00,72,00,69,00,65,00,6E,00,63,00,65,00,52,\' + "`n"
$disableprioritynotificationsregcontent += '  00,65,00,63,00,65,00,69,00,76,00,65,00,00,00,00,00'
}
$disableprioritynotificationsregfile = "$env:ProgramData\hh-optimization\Runtime\disablesetprioritynotifications.reg"
$disableprioritynotificationsregcontent | Out-File -FilePath $disableprioritynotificationsregfile -Encoding ASCII

# import reg file
Start-Process -Wait "regedit.exe" -ArgumentList "/S `"$disableprioritynotificationsregfile`"" -WindowStyle Hidden

# disable app actions
## ms-settings:appactions
# stop c:\windows\systemapps\microsoftwindows.client.cbs_cw5n1h2txyewy running
$stop = "AppActions", "CrossDeviceResume", "DesktopStickerEditorWin32Exe", "DiscoveryHubApp", "FESearchHost", "SearchHost", "SoftLandingTask", "TextInputHost", "VisualAssistExe", "WebExperienceHostApp", "WindowsBackupClient", "WindowsMigration"
$stop | ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

# create reg file
$appactions = @'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\Settings\LocalState\DisabledApps]
"Microsoft.Paint_8wekyb3d8bbwe"=hex(5f5e10b):01,61,ed,11,34,f7,9f,dc,01
"Microsoft.Windows.Photos_8wekyb3d8bbwe"=hex(5f5e10b):01,61,ed,11,34,f7,9f,dc,01
"MicrosoftWindows.Client.CBS_cw5n1h2txyewy"=hex(5f5e10b):01,61,ed,11,34,f7,9f,dc,01
'@
Set-Content -Path "$env:ProgramData\hh-optimization\Runtime\appactions.reg" -Value $appactions -Force
$settingsdat = "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\Settings\settings.dat"
$regfileappactions = "$env:ProgramData\hh-optimization\Runtime\appactions.reg"

# load hive
reg load "HKLM\Settings" $settingsdat >$null 2>&1

# import reg file
if ($LASTEXITCODE -eq 0) {
reg import $regfileappactions >$null 2>&1

# unload hive
[gc]::Collect()
Start-Sleep -Seconds 2
reg unload "HKLM\Settings" >$null 2>&1
}

# disable network adapter powersaving & wake on all connected devices
$basePath = "HKLM:\System\ControlSet001\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
$adapterKeys = Get-ChildItem -Path $basePath -ErrorAction SilentlyContinue
foreach ($key in $adapterKeys) {
if ($key.PSChildName -match '^\d{4}$') {
$regPath = $key.Name
# disable adapter powersaving & wake
cmd /c "reg add `"$regPath`" /v `"PnPCapabilities`" /t REG_DWORD /d `"24`" /f >nul 2>&1"
# disable advanced energy efficient ethernet
cmd /c "reg add `"$regPath`" /v `"AdvancedEEE`" /t REG_SZ /d `"0`" /f >nul 2>&1"
# disable energy-efficient ethernet
cmd /c "reg add `"$regPath`" /v `"*EEE`" /t REG_SZ /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"EEELinkAdvertisement`" /t REG_SZ /d `"0`" /f >nul 2>&1"
# system idle power saver
cmd /c "reg add `"$regPath`" /v `"SipsEnabled`" /t REG_SZ /d `"0`" /f >nul 2>&1"
# ultra low power mode
cmd /c "reg add `"$regPath`" /v `"ULPMode`" /t REG_SZ /d `"0`" /f >nul 2>&1"
# disable gigabit lite
cmd /c "reg add `"$regPath`" /v `"GigaLite`" /t REG_SZ /d `"0`" /f >nul 2>&1"
# disable green ethernet
cmd /c "reg add `"$regPath`" /v `"EnableGreenEthernet`" /t REG_SZ /d `"0`" /f >nul 2>&1"
# disable power saving mode
cmd /c "reg add `"$regPath`" /v `"PowerSavingMode`" /t REG_SZ /d `"0`" /f >nul 2>&1"
# disable all wake
cmd /c "reg add `"$regPath`" /v `"S5WakeOnLan`" /t REG_SZ /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"*WakeOnMagicPacket`" /t REG_SZ /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"*ModernStandbyWoLMagicPacket`" /t REG_SZ /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"*WakeOnPattern`" /t REG_SZ /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"WakeOnLink`" /t REG_SZ /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"*ModernStandbyWoLMagicPacket`" /t REG_SZ /d `"0`" /f >nul 2>&1"
}
}

# disable acpi power savings on all connected devices
$usbKeys = Get-ChildItem -Path "HKLM:\SYSTEM\ControlSet001\Enum\ACPI" -Recurse -ErrorAction SilentlyContinue |
Where-Object { $_.PSChildName -eq "Device Parameters" }
foreach ($key in $usbKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"EnhancedPowerManagementEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"SelectiveSuspendEnabled`" /t REG_BINARY /d `"00`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"SelectiveSuspendOn`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
}
$usbKeys = Get-ChildItem -Path "HKLM:\SYSTEM\ControlSet001\Enum\ACPI" -Recurse -ErrorAction SilentlyContinue |
Where-Object { $_.PSChildName -eq "WDF" }
foreach ($key in $usbKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"IdleInWorkingState`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
}

# disable hid power savings on all connected devices
$usbKeys = Get-ChildItem -Path "HKLM:\SYSTEM\ControlSet001\Enum\HID" -Recurse -ErrorAction SilentlyContinue |
Where-Object { $_.PSChildName -eq "Device Parameters" }
foreach ($key in $usbKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"EnhancedPowerManagementEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"SelectiveSuspendEnabled`" /t REG_BINARY /d `"00`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"SelectiveSuspendOn`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
}
$usbKeys = Get-ChildItem -Path "HKLM:\SYSTEM\ControlSet001\Enum\HID" -Recurse -ErrorAction SilentlyContinue |
Where-Object { $_.PSChildName -eq "WDF" }
foreach ($key in $usbKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"IdleInWorkingState`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
}

# disable pci power savings on all connected devices
$usbKeys = Get-ChildItem -Path "HKLM:\SYSTEM\ControlSet001\Enum\PCI" -Recurse -ErrorAction SilentlyContinue |
Where-Object { $_.PSChildName -eq "Device Parameters" }
foreach ($key in $usbKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"EnhancedPowerManagementEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"SelectiveSuspendEnabled`" /t REG_BINARY /d `"00`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"SelectiveSuspendOn`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
}
$usbKeys = Get-ChildItem -Path "HKLM:\SYSTEM\ControlSet001\Enum\PCI" -Recurse -ErrorAction SilentlyContinue |
Where-Object { $_.PSChildName -eq "WDF" }
foreach ($key in $usbKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"IdleInWorkingState`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
}

# disable usb power savings on all connected devices
$usbKeys = Get-ChildItem -Path "HKLM:\SYSTEM\ControlSet001\Enum\USB" -Recurse -ErrorAction SilentlyContinue |
Where-Object { $_.PSChildName -eq "Device Parameters" }
foreach ($key in $usbKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"EnhancedPowerManagementEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"SelectiveSuspendEnabled`" /t REG_BINARY /d `"00`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"SelectiveSuspendOn`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
}
$usbKeys = Get-ChildItem -Path "HKLM:\SYSTEM\ControlSet001\Enum\USB" -Recurse -ErrorAction SilentlyContinue |
Where-Object { $_.PSChildName -eq "WDF" }
foreach ($key in $usbKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"IdleInWorkingState`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
}

# disable acpi wake on all connected devices
$usbKeys = Get-ChildItem -Path "HKLM:\SYSTEM\ControlSet001\Enum\ACPI" -Recurse -ErrorAction SilentlyContinue |
Where-Object { $_.PSChildName -eq "Device Parameters" }
foreach ($key in $usbKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"WaitWakeEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
}

# disable hid wake on all connected devices
$usbKeys = Get-ChildItem -Path "HKLM:\SYSTEM\ControlSet001\Enum\HID" -Recurse -ErrorAction SilentlyContinue |
Where-Object { $_.PSChildName -eq "Device Parameters" }
foreach ($key in $usbKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"WaitWakeEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
}

# disable pci wake on all connected devices
$usbKeys = Get-ChildItem -Path "HKLM:\SYSTEM\ControlSet001\Enum\PCI" -Recurse -ErrorAction SilentlyContinue |
Where-Object { $_.PSChildName -eq "Device Parameters" }
foreach ($key in $usbKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"WaitWakeEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
}

# disable usb wake on all connected devices
$usbKeys = Get-ChildItem -Path "HKLM:\SYSTEM\ControlSet001\Enum\USB" -Recurse -ErrorAction SilentlyContinue |
Where-Object { $_.PSChildName -eq "Device Parameters" }
foreach ($key in $usbKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"WaitWakeEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
}

# turn off windows write-cache buffer flushing on the device on all connected scsi devices
$basePath = "HKLM:\SYSTEM\ControlSet001\Enum\SCSI"
Get-ChildItem -Path $basePath -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq "Device Parameters" } | ForEach-Object {
$diskPath = Join-Path $_.PSPath "Disk"
cmd /c "reg add `"$(($diskPath -replace 'Microsoft.PowerShell.Core\\Registry::',''))`" /v `"CacheIsPowerProtected`" /t REG_DWORD /d `"1`" /f >nul 2>&1"
}

# turn off windows write-cache buffer flushing on the device on all connected nvme devices
$basePath = "HKLM:\SYSTEM\ControlSet001\Enum\NVME"
Get-ChildItem -Path $basePath -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq "Device Parameters" } | ForEach-Object {
$diskPath = Join-Path $_.PSPath "Disk"
cmd /c "reg add `"$(($diskPath -replace 'Microsoft.PowerShell.Core\\Registry::',''))`" /v `"CacheIsPowerProtected`" /t REG_DWORD /d `"1`" /f >nul 2>&1"
}

# import notepad settings
## notepad
# stop notepad running
Stop-Process -Name "Notepad" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# create reg file
$NotepadSettings = @'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\Settings\LocalState]
"OpenFile"=hex(5f5e104):01,00,00,00,d1,55,24,57,d1,84,db,01
"GhostFile"=hex(5f5e10b):00,42,60,f1,5a,d1,84,db,01
"RewriteEnabled"=hex(5f5e10b):00,12,4a,7f,5f,d1,84,db,01
'@
Set-Content -Path "$env:ProgramData\hh-optimization\Runtime\notepadsettings.reg" -Value $NotepadSettings -Force
$SettingsDat = "$env:LocalAppData\Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\Settings\settings.dat"
$RegFileNotepadSettings = "$env:ProgramData\hh-optimization\Runtime\notepadsettings.reg"

# load hive
reg load "HKLM\Settings" $SettingsDat >$null 2>&1

# import reg file
if ($LASTEXITCODE -eq 0) {
reg import $RegFileNotepadSettings >$null 2>&1

# unload hive
[gc]::Collect()
Start-Sleep -Seconds 2
reg unload "HKLM\Settings" >$null 2>&1
}

# unpin all taskbar items
cmd /c "reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband /f >nul 2>&1"
Remove-Item -Recurse -Force "$env:USERPROFILE\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch" -ErrorAction SilentlyContinue | Out-Null
	
# black signout & lockscreen
## ms-settings:lockscreen
# create image
Add-Type -AssemblyName System.Windows.Forms
$screenWidth = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Width
$screenHeight = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Height
Add-Type -AssemblyName System.Drawing
$file = "C:\Windows\Black.jpg"
$edit = New-Object System.Drawing.Bitmap $screenWidth, $screenHeight
$color = [System.Drawing.Brushes]::Black
$graphics = [System.Drawing.Graphics]::FromImage($edit)
$graphics.FillRectangle($color, 0, 0, $edit.Width, $edit.Height)
$graphics.Dispose()
$edit.Save($file)
$edit.Dispose()

# set image
cmd /c "reg add `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP`" /v `"LockScreenImagePath`" /t REG_SZ /d `"C:\Windows\Black.jpg`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP`" /v `"LockScreenImageStatus`" /t REG_DWORD /d `"1`" /f >nul 2>&1"

# black wallpaper
cmd /c "reg add `"HKCU\Control Panel\Desktop`" /v `"Wallpaper`" /t REG_SZ /d `"C:\Windows\Black.jpg`" /f >nul 2>&1"
rundll32.exe user32.dll, UpdatePerUserSystemParameters

# remove context menu items
# Classic context menu and native Terminal integration are handled by the embedded settings block.

# remove customize this folder
cmd /c "reg add `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer`" /v `"NoCustomizeThisFolder`" /t REG_DWORD /d `"1`" /f >nul 2>&1"

# remove pin to quick access
cmd /c "reg delete `"HKCR\Folder\shell\pintohome`" /f >nul 2>&1"

# remove add to favorites
cmd /c "reg delete `"HKCR\*\shell\pintohomefile`" /f >nul 2>&1"

# remove troubleshoot compatibility
cmd /c "reg delete `"HKCR\exefile\shellex\ContextMenuHandlers\Compatibility`" /f >nul 2>&1"

# Keep Open in Terminal.

# remove scan with defender
cmd /c "reg add `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked`" /v `"{09A47860-11B0-4DA5-AFA5-26D86198A780}`" /t REG_SZ /d `"`" /f >nul 2>&1"

# remove give access to
cmd /c "reg add `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked`" /v `"{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}`" /t REG_SZ /d `"`" /f >nul 2>&1"

# remove include in library
cmd /c "reg delete `"HKCR\Folder\ShellEx\ContextMenuHandlers\Library Location`" /f >nul 2>&1"

# remove share
cmd /c "reg delete `"HKCR\AllFilesystemObjects\shellex\ContextMenuHandlers\ModernSharing`" /f >nul 2>&1"

# remove restore previous versions
cmd /c "reg add `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer`" /v `"NoPreviousVersionsPage`" /t REG_DWORD /d `"1`" /f >nul 2>&1"

# remove send to
cmd /c "reg delete `"HKCR\AllFilesystemObjects\shellex\ContextMenuHandlers\SendTo`" /f >nul 2>&1"
cmd /c "reg delete `"HKCR\UserLibraryFolder\shellex\ContextMenuHandlers\SendTo`" /f >nul 2>&1"

# windows 10 import start menu
# delete startmenulayout.xml
Remove-Item -Recurse -Force "$env:SystemDrive\Windows\StartMenuLayout.xml" -ErrorAction SilentlyContinue | Out-Null

# create startmenulayout.xml
$MultilineComment = @'
<LayoutModificationTemplate xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" Version="1" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification">
    <LayoutOptions StartTileGroupCellWidth="6" />
    <DefaultLayoutOverride>
        <StartLayoutCollection>
            <defaultlayout:StartLayout GroupCellWidth="6" />
        </StartLayoutCollection>
    </DefaultLayoutOverride>
</LayoutModificationTemplate>
'@
Set-Content -Path "C:\Windows\StartMenuLayout.xml" -Value $MultilineComment -Force -Encoding ASCII

# assign startmenulayout.xml registry
$layoutFile="C:\Windows\StartMenuLayout.xml"
$regAliases = @("HKLM", "HKCU")
foreach ($regAlias in $regAliases){
$basePath = $regAlias + ":\SOFTWARE\Policies\Microsoft\Windows"
$keyPath = $basePath + "\Explorer"
IF(!(Test-Path -Path $keyPath)) {
New-Item -Path $basePath -Name "Explorer" | Out-Null
}
Set-ItemProperty -Path $keyPath -Name "LockedStartLayout" -Value 1 | Out-Null
Set-ItemProperty -Path $keyPath -Name "StartLayoutFile" -Value $layoutFile | Out-Null
}

# restart explorer
Stop-Process -Force -Name explorer -ErrorAction SilentlyContinue | Out-Null
Start-Sleep -Seconds 5

# disable lockedstartlayout registry
foreach ($regAlias in $regAliases){
$basePath = $regAlias + ":\SOFTWARE\Policies\Microsoft\Windows"
$keyPath = $basePath + "\Explorer"
Set-ItemProperty -Path $keyPath -Name "LockedStartLayout" -Value 0
}

# delete startmenulayout.xml
Remove-Item -Recurse -Force "$env:SystemDrive\Windows\StartMenuLayout.xml" -ErrorAction SilentlyContinue | Out-Null

# windows 11 import start menu
# remove start2 bin
Remove-Item -Recurse -Force "$env:USERPROFILE\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin" -ErrorAction SilentlyContinue | Out-Null

# decode start2 txt
certutil.exe -decode "$env:ProgramData\hh-optimization\Runtime\start2.txt" "$env:ProgramData\hh-optimization\Runtime\start2.bin" >$null

# install start2 bin
Copy-Item "$env:ProgramData\hh-optimization\Runtime\start2.bin" -Destination "$env:USERPROFILE\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState" -Force -ErrorAction SilentlyContinue | Out-Null

# set start menu apps view to list
cmd /c "reg add `"HKCU\Software\Microsoft\Windows\CurrentVersion\Start`" /v `"AllAppsViewMode`" /t REG_DWORD /d `"2`" /f >nul 2>&1"

# restart explorer
Stop-Process -Force -Name explorer -ErrorAction SilentlyContinue | Out-Null

# No service-folder shortcuts or Start Menu Recycle Bin shortcut.

# hide accessibility accessories folders and all contents from start menu
$folders = @(
"$env:USERPROFILE\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Accessibility",
"$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Accessibility",
"$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Accessories"
)
foreach ($folder in $folders) {
if (Test-Path $folder) {
cmd /c "attrib +h `"$folder`" >nul 2>&1"
cmd /c "attrib +h `"$folder\*.*`" /s /d >nul 2>&1"
}
}

# set start menu apps view to list
cmd /c "reg add `"HKCU\Software\Microsoft\Windows\CurrentVersion\Start`" /v `"AllAppsViewMode`" /t REG_DWORD /d `"2`" /f >nul 2>&1"

# show all hidden taskbar icons
## ms-settings:taskbar
$notifyiconsettings = Get-ChildItem -Path 'registry::HKEY_CURRENT_USER\Control Panel\NotifyIconSettings' -Recurse -Force
foreach ($setreg in $notifyiconsettings) {
if ((Get-ItemProperty -Path "registry::$setreg").IsPromoted -eq 0) {
}
else {
Set-ItemProperty -Path "registry::$setreg" -Name 'IsPromoted' -Value 1 -Force
}
}

# restart explorer
Stop-Process -Force -Name explorer -ErrorAction SilentlyContinue | Out-Null
Start-Sleep -Seconds 10

        Write-Host "POWER PLAN`n"
        ## powercfg.cpl

# import ultimate power plan
cmd /c "powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 99999999-9999-9999-9999-999999999999 >nul 2>&1"

# set ultimate power plan active
cmd /c "powercfg /SETACTIVE 99999999-9999-9999-9999-999999999999 >nul 2>&1"

# get all powerplans
$output = powercfg /L
$powerPlans = @()
foreach ($line in $output) {

# extract guid manually to avoid language issues
if ($line -match ':') {
$parse = $line -split ':'
$index = $parse[1].Trim().indexof('(')
$guid = $parse[1].Trim().Substring(0, $index)
$powerPlans += $guid
}
}

# delete all powerplans
foreach ($plan in $powerPlans) {
cmd /c "powercfg /delete $plan 2>nul" | Out-Null
}

# disable hibernate
powercfg /hibernate off
cmd /c "reg add `"HKLM\SYSTEM\CurrentControlSet\Control\Power`" /v `"HibernateEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SYSTEM\CurrentControlSet\Control\Power`" /v `"HibernateEnabledDefault`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# disable lock
cmd /c "reg add `"HKLM\Software\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings`" /v `"ShowLockOption`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# disable sleep
cmd /c "reg add `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings`" /v `"ShowSleepOption`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# disable fast boot
cmd /c "reg add `"HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power`" /v `"HiberbootEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# disable power throttling
cmd /c "reg add `"HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling`" /v `"PowerThrottlingOff`" /t REG_DWORD /d `"1`" /f >nul 2>&1"

# modify desktop & laptop settings
# hard disk turn off hard disk after 0%
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 0012ee47-9041-4b5d-9b77-535fba8b1442 6738e2c4-e8a5-4a42-b16a-e040e769756e 0x00000000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 0012ee47-9041-4b5d-9b77-535fba8b1442 6738e2c4-e8a5-4a42-b16a-e040e769756e 0x00000000 2>$null

# desktop background settings slide show paused
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 0d7dbae2-4294-402a-ba8e-26777e8488cd 309dce9b-bef4-4119-9921-a851fb12f0f4 001 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 0d7dbae2-4294-402a-ba8e-26777e8488cd 309dce9b-bef4-4119-9921-a851fb12f0f4 001 2>$null

# wireless adapter settings power saving mode maximum performance
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 000 2>$null

# sleep
# sleep after 0%
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0x00000000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0x00000000 2>$null

# allow hybrid sleep off
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 238c9fa8-0aad-41ed-83f4-97be242c8f20 94ac6d29-73ce-41a6-809f-6363ba21b47e 000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 238c9fa8-0aad-41ed-83f4-97be242c8f20 94ac6d29-73ce-41a6-809f-6363ba21b47e 000 2>$null

# hibernate after
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 238c9fa8-0aad-41ed-83f4-97be242c8f20 9d7815a6-7ee4-497e-8888-515a05f02364 0x00000000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 238c9fa8-0aad-41ed-83f4-97be242c8f20 9d7815a6-7ee4-497e-8888-515a05f02364 0x00000000 2>$null

# allow wake timers disable
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 238c9fa8-0aad-41ed-83f4-97be242c8f20 bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d 000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 238c9fa8-0aad-41ed-83f4-97be242c8f20 bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d 000 2>$null

# usb settings
# unhide hub selective suspend timeout
cmd /c "reg add `"HKLM\System\ControlSet001\Control\Power\PowerSettings\2a737441-1930-4402-8d77-b2bebba308a3\0853a681-27c8-4100-a2fd-82013e970683`" /v `"Attributes`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# hub selective suspend timeout 0
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 2a737441-1930-4402-8d77-b2bebba308a3 0853a681-27c8-4100-a2fd-82013e970683 0x00000000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 2a737441-1930-4402-8d77-b2bebba308a3 0853a681-27c8-4100-a2fd-82013e970683 0x00000000 2>$null

# usb selective suspend setting disabled
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 000 2>$null

# unhide usb 3 link power management
cmd /c "reg add `"HKLM\System\ControlSet001\Control\Power\PowerSettings\2a737441-1930-4402-8d77-b2bebba308a3\d4e98f31-5ffe-4ce1-be31-1b38b384c009`" /v `"Attributes`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# usb 3 link power management - off
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 2a737441-1930-4402-8d77-b2bebba308a3 d4e98f31-5ffe-4ce1-be31-1b38b384c009 000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 2a737441-1930-4402-8d77-b2bebba308a3 d4e98f31-5ffe-4ce1-be31-1b38b384c009 000 2>$null

# power buttons and lid start menu power button shut down
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 4f971e89-eebd-4455-a8de-9e59040e7347 a7066653-8d6c-40a8-910e-a1f54b84c7e5 002 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 4f971e89-eebd-4455-a8de-9e59040e7347 a7066653-8d6c-40a8-910e-a1f54b84c7e5 002 2>$null

# pci express link state power management off
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 000 2>$null

# processor power management
# minimum processor state 100%
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c 0x00000064 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c 0x00000064 2>$null

# system cooling policy active
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 54533251-82be-4824-96c1-47b60b740d00 94d3a615-a899-4ac5-ae2b-e4d8f634367f 001 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 54533251-82be-4824-96c1-47b60b740d00 94d3a615-a899-4ac5-ae2b-e4d8f634367f 001 2>$null

# maximum processor state 100%
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 54533251-82be-4824-96c1-47b60b740d00 bc5038f7-23e0-4960-96da-33abaf5935ec 0x00000064 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 54533251-82be-4824-96c1-47b60b740d00 bc5038f7-23e0-4960-96da-33abaf5935ec 0x00000064 2>$null

# unhide processor performance core parking min cores
cmd /c "reg add `"HKLM\System\ControlSet001\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583`" /v `"Attributes`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# unpark cpu cores
# processor performance core parking min cores 100%
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 54533251-82be-4824-96c1-47b60b740d00 0cc5b647-c1df-4637-891a-dec35c318583 0x00000064 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 54533251-82be-4824-96c1-47b60b740d00 0cc5b647-c1df-4637-891a-dec35c318583 0x00000064 2>$null

# unhide processor performance core parking max cores
cmd /c "reg add `"HKLM\System\ControlSet001\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\ea062031-0e34-4ff1-9b6d-eb1059334028`" /v `"Attributes`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# unpark cpu cores
# processor performance core parking max cores 100%
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 54533251-82be-4824-96c1-47b60b740d00 ea062031-0e34-4ff1-9b6d-eb1059334028 0x00000064 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 54533251-82be-4824-96c1-47b60b740d00 ea062031-0e34-4ff1-9b6d-eb1059334028 0x00000064 2>$null

# display
# turn off display after 10 min - oled protection
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e 0 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e 0 2>$null
powercfg /requestsoverride PROCESS "chrome.exe" DISPLAY SYSTEM AWAYMODE 2>$null
powercfg /requestsoverride PROCESS "Discord.exe" DISPLAY SYSTEM AWAYMODE 2>$null

# display brightness 100%
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 7516b95f-f776-4464-8c53-06167f40cc99 aded5e82-b909-4619-9949-f5d71dac0bcb 0x00000064 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 7516b95f-f776-4464-8c53-06167f40cc99 aded5e82-b909-4619-9949-f5d71dac0bcb 0x00000064 2>$null

# dimmed display brightness 100%
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 7516b95f-f776-4464-8c53-06167f40cc99 f1fbfde2-a960-4165-9f88-50667911ce96 0x00000064 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 7516b95f-f776-4464-8c53-06167f40cc99 f1fbfde2-a960-4165-9f88-50667911ce96 0x00000064 2>$null

# enable adaptive brightness off
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 7516b95f-f776-4464-8c53-06167f40cc99 fbd9aa66-9553-4097-ba44-ed6e9d65eab8 000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 7516b95f-f776-4464-8c53-06167f40cc99 fbd9aa66-9553-4097-ba44-ed6e9d65eab8 000 2>$null

# video playback quality bias video playback performance bias
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 9596fb26-9850-41fd-ac3e-f7c3c00afd4b 10778347-1370-4ee0-8bbd-33bdacaade49 001 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 9596fb26-9850-41fd-ac3e-f7c3c00afd4b 10778347-1370-4ee0-8bbd-33bdacaade49 001 2>$null

# when playing video optimize video quality
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 9596fb26-9850-41fd-ac3e-f7c3c00afd4b 34c7b99f-9a6d-4b3c-8dc7-b6693b78cef4 000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 9596fb26-9850-41fd-ac3e-f7c3c00afd4b 34c7b99f-9a6d-4b3c-8dc7-b6693b78cef4 000 2>$null

# modify laptop settings
# intel(r) graphics settings intel(r) graphics power plan maximum performance
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 44f3beca-a7c0-460e-9df2-bb8b99e0cba6 3619c3f2-afb2-4afc-b0e9-e7fef372de36 002 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 44f3beca-a7c0-460e-9df2-bb8b99e0cba6 3619c3f2-afb2-4afc-b0e9-e7fef372de36 002 2>$null

# amd power slider overlay best performance
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 c763b4ec-0e50-4b6b-9bed-2b92a6ee884e 7ec1751b-60ed-4588-afb5-9819d3d77d90 003 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 c763b4ec-0e50-4b6b-9bed-2b92a6ee884e 7ec1751b-60ed-4588-afb5-9819d3d77d90 003 2>$null

# ati graphics power settings ati powerplay settings maximize performance
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 f693fb01-e858-4f00-b20f-f30e12ac06d6 191f65b5-d45c-4a4f-8aae-1ab8bfd980e6 001 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 f693fb01-e858-4f00-b20f-f30e12ac06d6 191f65b5-d45c-4a4f-8aae-1ab8bfd980e6 001 2>$null

# switchable dynamic graphics global settings maximize performance
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 e276e160-7cb0-43c6-b20b-73f5dce39954 a1662ab2-9d34-4e53-ba8b-2639b9e20857 003 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 e276e160-7cb0-43c6-b20b-73f5dce39954 a1662ab2-9d34-4e53-ba8b-2639b9e20857 003 2>$null

# battery
# critical battery notification off
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 e73a048d-bf27-4f12-9731-8b2076e8891f 5dbb7c9f-38e9-40d2-9749-4f8a0e9f640f 000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 e73a048d-bf27-4f12-9731-8b2076e8891f 5dbb7c9f-38e9-40d2-9749-4f8a0e9f640f 000 2>$null

# critical battery action do nothing
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 e73a048d-bf27-4f12-9731-8b2076e8891f 637ea02f-bbcb-4015-8e2c-a1c7b9c0b546 000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 e73a048d-bf27-4f12-9731-8b2076e8891f 637ea02f-bbcb-4015-8e2c-a1c7b9c0b546 000 2>$null

# low battery level 0%
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 e73a048d-bf27-4f12-9731-8b2076e8891f 8183ba9a-e910-48da-8769-14ae6dc1170a 0x00000000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 e73a048d-bf27-4f12-9731-8b2076e8891f 8183ba9a-e910-48da-8769-14ae6dc1170a 0x00000000 2>$null

# critical battery level 0%
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 e73a048d-bf27-4f12-9731-8b2076e8891f 9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469 0x00000000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 e73a048d-bf27-4f12-9731-8b2076e8891f 9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469 0x00000000 2>$null

# low battery notification off
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 e73a048d-bf27-4f12-9731-8b2076e8891f bcded951-187b-4d05-bccc-f7e51960c258 000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 e73a048d-bf27-4f12-9731-8b2076e8891f bcded951-187b-4d05-bccc-f7e51960c258 000 2>$null

# low battery action do nothing
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 e73a048d-bf27-4f12-9731-8b2076e8891f d8742dcb-3e6a-4b3c-b3fe-374623cdcf06 000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 e73a048d-bf27-4f12-9731-8b2076e8891f d8742dcb-3e6a-4b3c-b3fe-374623cdcf06 000 2>$null

# reserve battery level 0%
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 e73a048d-bf27-4f12-9731-8b2076e8891f f3c5027d-cd16-4930-aa6b-90db844a8f00 0x00000000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 e73a048d-bf27-4f12-9731-8b2076e8891f f3c5027d-cd16-4930-aa6b-90db844a8f00 0x00000000 2>$null

# immersive control panel
# low screen brightness when using battery saver disable
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 de830923-a562-41af-a086-e3a2c6bad2da 13d09884-f74e-474a-a852-b6bde8ad03a8 0x00000064 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 de830923-a562-41af-a086-e3a2c6bad2da 13d09884-f74e-474a-a852-b6bde8ad03a8 0x00000064 2>$null

# turn battery saver on automatically at never
powercfg /setacvalueindex 99999999-9999-9999-9999-999999999999 de830923-a562-41af-a086-e3a2c6bad2da e69653ca-cf7f-4f05-aa73-cb833fa90ad4 0x00000000 2>$null
powercfg /setdcvalueindex 99999999-9999-9999-9999-999999999999 de830923-a562-41af-a086-e3a2c6bad2da e69653ca-cf7f-4f05-aa73-cb833fa90ad4 0x00000000 2>$null

# disable if you've been away, when should windows require you to sign in again?
powercfg /setdcvalueindex scheme_current sub_none consolelock 0 2>$null
powercfg /setacvalueindex scheme_current sub_none consolelock 0 2>$null

        Write-Host "TIMER RESOLUTION`n"
        ## services.msc

# compile and create service
Start-Process -Wait "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" -ArgumentList "-out:C:\Windows\SetTimerResolutionService.exe C:\ProgramData\hh-optimization\Runtime\settimerresolutionservice.cs" -WindowStyle Hidden

# remove old service if exists
if (Get-Service -Name "Set Timer Resolution Service" -ErrorAction SilentlyContinue) {
    sc.exe delete "Set Timer Resolution Service" | Out-Null
    Start-Sleep -Seconds 2
}

# install and start service
New-Service -Name "Set Timer Resolution Service" -BinaryPathName "$env:SystemDrive\Windows\SetTimerResolutionService.exe" -ErrorAction SilentlyContinue | Out-Null
Set-Service -Name "Set Timer Resolution Service" -StartupType Auto -ErrorAction SilentlyContinue | Out-Null
Set-Service -Name "Set Timer Resolution Service" -Status Running -ErrorAction SilentlyContinue | Out-Null

# enable global timer resolution requests
cmd /c "reg add `"HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel`" /v `"GlobalTimerResolutionRequests`" /t REG_DWORD /d `"1`" /f >nul 2>&1"

# rebuild performance counters
## perfmon.msc
cmd /c "cd /d %systemroot%\system32 && lodctr /R >nul 2>&1"
cmd /c "cd /d %systemroot%\sysWOW64 && lodctr /R >nul 2>&1"

# remove uwp apps pesky on ms account
## ms-settings:appsfeatures
## powershell -noexit -command "get-appxpackage | select name | format-table -autosize"
Get-AppxPackage -allusers *MSTeams* | Remove-AppxPackage -ErrorAction SilentlyContinue
Get-AppxPackage -allusers *Microsoft.OutlookForWindows* | Remove-AppxPackage -ErrorAction SilentlyContinue

		# Apply requested overrides after the original settings/power plan, before cleanup.
# BEGIN embedded personal and advanced settings
& {
# Final overrides for the TARGET Windows. Never run as a diagnostic on the host.
$ErrorActionPreference = 'Stop'
# Status is console-only; no diagnostic files are created.
$script:hhFailures = 0
function Write-SettingStatus([string]$Level,[string]$Message) {
    Write-Host ("[$Level] $Message")
}
function Apply-Setting([string]$Name,[scriptblock]$Action) {
    try { & $Action; Write-SettingStatus 'OK' $Name }
    catch {
        $script:hhFailures++
        $detail = $_.Exception.Message + ' | ' + $_.InvocationInfo.PositionMessage + ' | ' + $_.ScriptStackTrace
        Write-SettingStatus 'ERROR' ("${Name}: $detail")
        Write-Warning ("${Name}: " + $_.Exception.Message)
    }
}
function Set-RegistryValue([string]$Hive,[string]$Path,[string]$Name,$Value,[Microsoft.Win32.RegistryValueKind]$Kind) {
    # Do not recreate existing keys with New-Item -Force (Registry provider).
    # Open only the specific leaf key; never reset parent keys or their ACLs.
    $base = if ($Hive -eq 'HKCU') { [Microsoft.Win32.Registry]::CurrentUser } elseif ($Hive -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { throw "Unsupported hive: $Hive" }
    $key = $null
    try {
        $key = $base.OpenSubKey($Path,$true)
        if ($null -eq $key) { $key = $base.CreateSubKey($Path) }
        if ($null -eq $key) { throw 'Could not open/create registry key' }
        $key.SetValue($Name,$Value,$Kind)
        $actual = $key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($Kind -eq [Microsoft.Win32.RegistryValueKind]::Binary) { if ([BitConverter]::ToString([byte[]]$actual) -cne [BitConverter]::ToString([byte[]]$Value)) { throw 'Binary read-back verification failed' } } elseif ([string]$actual -cne [string]$Value) { throw 'Read-back verification failed' }
    } catch { throw "Registry write failed: $Hive\$Path [$Name]: $($_.Exception.Message)" }
    finally { if ($null -ne $key) { $key.Dispose() } }
}
function Set-Dword([string]$Hive,[string]$Path,[string]$Name,[int]$Value) {
    Set-RegistryValue $Hive $Path $Name $Value ([Microsoft.Win32.RegistryValueKind]::DWord)
}
function Set-String([string]$Hive,[string]$Path,[string]$Name,[string]$Value) {
    Set-RegistryValue $Hive $Path $Name $Value ([Microsoft.Win32.RegistryValueKind]::String)
}
function Remove-RegistryValue([string]$Hive,[string]$Path,[string]$Name) {
    $base = if ($Hive -eq 'HKCU') { [Microsoft.Win32.Registry]::CurrentUser } else { [Microsoft.Win32.Registry]::LocalMachine }
    $key = $null
    try { $key = $base.OpenSubKey($Path,$true); if ($key) { $key.DeleteValue($Name,$false) } }
    catch { throw "Registry delete failed: $Hive\$Path [$Name]: $($_.Exception.Message)" }
    finally { if ($key) { $key.Dispose() } }
}
Write-SettingStatus 'BEGIN' ('User SID: ' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
Apply-Setting 'MPO enabled (default)' { Remove-RegistryValue HKLM 'SOFTWARE\Microsoft\Windows\Dwm' OverlayTestMode }
Apply-Setting 'Windowed game optimizations enabled' {
    $gpuPath = 'Software\Microsoft\DirectX\UserGpuPreferences'
    $gpuKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($gpuPath)
    $old = ''; if ($gpuKey) { try { $old = [string]$gpuKey.GetValue('DirectXUserGlobalSettings','') } finally { $gpuKey.Dispose() } }
    $parts = @($old -split ';' | Where-Object { $_ -and $_ -notmatch '^SwapEffectUpgradeEnable=' })
    Set-String HKCU $gpuPath DirectXUserGlobalSettings ((($parts + 'SwapEffectUpgradeEnable=1') -join ';') + ';')
}
# Exactly four requested checkboxes; all other Performance Options effects off.
Apply-Setting 'Prepare native visual-effects API' {
    if (-not ('hhOptimization.VisualEffectsNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace hhOptimization {
 public static class VisualEffectsNative {
  [StructLayout(LayoutKind.Sequential)] public struct AnimationInfo { public uint Size; public int MinAnimate; }
  [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
  private static extern bool Set(uint action,uint ui,IntPtr value,uint flags);
  [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
  private static extern bool Get(uint action,uint ui,out int value,uint flags);
  [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
  private static extern bool Animation(uint action,uint ui,ref AnimationInfo info,uint flags);
  public static void SetBoolean(uint action,uint getAction,bool enabled,bool useUiParam) {
   if (!Set(action,useUiParam?(enabled?1u:0u):0u,useUiParam?IntPtr.Zero:new IntPtr(enabled?1:0),3u)) throw new Win32Exception(Marshal.GetLastWin32Error());
   int actual; if(!Get(getAction,0u,out actual,0u)) throw new Win32Exception(Marshal.GetLastWin32Error());
   if((actual!=0)!=enabled) throw new InvalidOperationException("Visual-effect read-back mismatch: 0x"+action.ToString("X"));
  }
  public static void DisableMinimizeAnimation() {
   AnimationInfo info=new AnimationInfo();info.Size=(uint)Marshal.SizeOf(typeof(AnimationInfo));info.MinAnimate=0;
   if(!Animation(0x49u,info.Size,ref info,3u)) throw new Win32Exception(Marshal.GetLastWin32Error());
   if(!Animation(0x48u,info.Size,ref info,0u)||info.MinAnimate!=0) throw new InvalidOperationException("Window-animation read-back failed");
  }
 }
}
'@
    }
}
Apply-Setting 'Normalize UserPreferencesMask to binary' {
    Set-RegistryValue HKCU 'Control Panel\Desktop' UserPreferencesMask ([byte[]](0x90,0x12,0x03,0x80,0x10,0,0,0)) ([Microsoft.Win32.RegistryValueKind]::Binary)
}
$offEffects = @(
    @{Label='Menu animation';Set=0x1003;Get=0x1002},
    @{Label='Combo-box animation';Set=0x1005;Get=0x1004},
    @{Label='Smooth-scroll list boxes';Set=0x1007;Get=0x1006},
    @{Label='Menu fade';Set=0x1013;Get=0x1012},
    @{Label='Selection fade after menu command';Set=0x1015;Get=0x1014},
    @{Label='Tooltip animation';Set=0x1017;Get=0x1016},
    @{Label='Tooltip fade';Set=0x1019;Get=0x1018},
    @{Label='Cursor shadow';Set=0x101B;Get=0x101A},
    @{Label='Window drop shadows';Set=0x1025;Get=0x1024},
    @{Label='Animations inside windows';Set=0x1043;Get=0x1042}
)
foreach ($effectSetting in $offEffects) {
    Apply-Setting ($effectSetting.Label + ' OFF') { [hhOptimization.VisualEffectsNative]::SetBoolean($effectSetting.Set,$effectSetting.Get,$false,$false) }
}
Apply-Setting 'Minimize/maximize animation OFF' { [hhOptimization.VisualEffectsNative]::DisableMinimizeAnimation() }
foreach ($effectSetting in @(
    @{Path='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';Value='TaskbarAnimations'},
    @{Path='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';Value='ListviewShadow'},
    @{Path='Software\Microsoft\Windows\DWM';Value='EnableAeroPeek'},
    @{Path='Software\Microsoft\Windows\DWM';Value='AlwaysHibernateThumbnails'}
)) {
    Apply-Setting ($effectSetting.Value + ' OFF') { Set-Dword HKCU $effectSetting.Path $effectSetting.Value 0 }
}
Apply-Setting 'MinAnimate registry OFF' { Set-String HKCU 'Control Panel\Desktop\WindowMetrics' MinAnimate '0' }
# The only enabled checkboxes from the screenshot.
Apply-Setting 'Thumbnails instead of icons ON' { Set-Dword HKCU 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' IconsOnly 0 }
Apply-Setting 'Translucent selection rectangle ON' { Set-Dword HKCU 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' ListviewAlphaSelect 1 }
Apply-Setting 'Show window contents while dragging ON' {
    Set-String HKCU 'Control Panel\Desktop' DragFullWindows '1'
    [hhOptimization.VisualEffectsNative]::SetBoolean(0x25,0x26,$true,$true)
}
Apply-Setting 'Smooth screen fonts ON' {
    Set-String HKCU 'Control Panel\Desktop' FontSmoothing '2'
    [hhOptimization.VisualEffectsNative]::SetBoolean(0x4B,0x4A,$true,$true)
}
Apply-Setting 'Custom visual effects selection' { Set-Dword HKCU 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' VisualFXSetting 3 }

Apply-Setting 'Classic context menu' {
    Set-String HKCU 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '' ''
}
foreach ($hive in @('HKCU','HKLM')) {
    Apply-Setting "Unblock native Terminal integration ($hive)" {
        Remove-RegistryValue $hive 'SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked' '{9F156763-7844-4DC4-B2B1-901F640F5155}'
    }
}
# Remove our redundant English verb only; retain Windows Terminal's native item.
foreach ($relative in @('Directory\Background','Directory','Drive')) {
    Apply-Setting "Remove duplicate Terminal verb: $relative" {
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(('Software\Classes\' + $relative + '\shell\hh.OpenInTerminal'),$false)
    }
}

# Home is hidden per-user. Do not write protected HKLM NameSpace keys.
Apply-Setting 'Hide Explorer Home (per-user)' { Set-Dword HKCU 'Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}' 'System.IsPinnedToNameSpaceTree' 0 }
Apply-Setting 'Explorer opens This PC' { Set-Dword HKCU 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' LaunchTo 1 }
Apply-Setting 'Do not show all namespace folders' { Set-Dword HKCU 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' NavPaneShowAllFolders 0 }
foreach ($mode in @('NewStartPanel','ClassicStartMenu')) {
    Apply-Setting "Show Recycle Bin on Desktop: $mode" { Set-Dword HKCU "Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\$mode" '{645FF040-5081-101B-9F08-00AA002F954E}' 0 }
}
Apply-Setting 'Display never turns off on AC' { powercfg.exe /change monitor-timeout-ac 0; if ($LASTEXITCODE -ne 0) { throw "powercfg AC exit code $LASTEXITCODE" } }
Apply-Setting 'Display never turns off on battery' { powercfg.exe /change monitor-timeout-dc 0; if ($LASTEXITCODE -ne 0) { throw "powercfg DC exit code $LASTEXITCODE" } }

# Requested Disable options from Ultimate 8 Advanced 2/3/4/5.
# These deliberately reduce security. Do not stop/delete BFE or MpsSvc services.
Apply-Setting 'Firewall disabled (Ultimate method)' {
cmd /c "reg add `"HKEY_LOCAL_MACHINE\System\ControlSet001\Services\SharedAccess\Parameters\FirewallPolicy\PublicProfile`" /v `"EnableFirewall`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"HKEY_LOCAL_MACHINE\System\ControlSet001\Services\SharedAccess\Parameters\FirewallPolicy\StandardProfile`" /v `"EnableFirewall`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
}
foreach ($mitigationName in @('FeatureSettingsOverrideMask','FeatureSettingsOverride')) {
    Apply-Setting "Spectre/Meltdown Disable: $mitigationName=3 (reboot required)" { Set-Dword HKLM 'SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' $mitigationName 3 }
}
Apply-Setting 'DEP boot policy AlwaysOff (Ultimate method; reboot required)' {
cmd /c "bcdedit /set nx AlwaysOff >nul 2>&1"
}
Apply-Setting 'Disable file-download security settings check' { Set-Dword HKLM 'SOFTWARE\Policies\Microsoft\Internet Explorer\Security' DisableSecuritySettingsCheck 1 }
foreach ($hive in @('HKCU','HKLM')) {
    Apply-Setting "Disable file-download launch warning: $hive zone 3 / 1806" { Set-Dword $hive 'Software\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\3' '1806' 0 }
}
# Explicitly ENABLE features. Preserving a disabled component does not enable it.
foreach ($featureName in @('LegacyComponents','DirectPlay')) {
    Apply-Setting "Enable Windows feature: $featureName (may require reboot)" {
        $state = [string](Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop).State
        if ($state -notin @('Enabled','EnablePending')) {
            try { Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart -LimitAccess -ErrorAction Stop | Out-Null }
            catch {
                $originalError = $_.Exception.Message
                $source = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root 'sources\sxs' } | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
                if (-not $source.Count) { throw "Could not enable ${featureName}: $originalError. Matching Windows installation media may be required; no sources\sxs found." }
                Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart -LimitAccess -Source $source -ErrorAction Stop | Out-Null
            }
            $state = [string](Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop).State
        }
        if ($state -notin @('Enabled','EnablePending')) { throw "Unexpected feature state: $state" }
        Write-SettingStatus 'STATE' "$featureName=$state"
    }
}
Apply-Setting 'C: volume label SYSTEM' {
    $systemVolume = [IO.DriveInfo]::new('C:\')
    if (-not $systemVolume.IsReady -or $systemVolume.DriveType -ne [IO.DriveType]::Fixed) { throw 'C: is not a ready fixed volume; not relabeled.' }
    $systemVolume.VolumeLabel = 'SYSTEM'
    if ($systemVolume.VolumeLabel -cne 'SYSTEM') { throw 'C: label read-back mismatch' }
}

# Cursor scheme and keyboard-switching hotkeys remain unchanged.
Write-SettingStatus 'END' ("Failed operations: $script:hhFailures. Explorer and boot policy changes require the planned reboot.")
if ($script:hhFailures -gt 0) { Write-Warning "$script:hhFailures requested operations failed. Details were printed above; no log files are saved." }
}
# END embedded personal and advanced settings
# BEGIN final cleanup of project-owned artifacts (last stage only)
& {
$ErrorActionPreference = 'Stop'
$runtimeRoot = Join-Path $env:ProgramData 'hh-optimization\Runtime'
$projectRoot = Join-Path $env:ProgramData 'hh-optimization'
$localProjectRoot=Join-Path $env:LOCALAPPDATA 'hh-optimization'
$desktopPath=[Environment]::GetFolderPath('Desktop')
if([string]::IsNullOrWhiteSpace($desktopPath)){throw 'Desktop unavailable; cleanup cancelled'}
$afterFolder=Join-Path $desktopPath 'После Оптимизации'
$afterStage=Join-Path $runtimeRoot 'После Оптимизации'
function Write-CleanupStatus([string]$Message) { Write-Host $Message }
function Assert-NoReparseAncestor([string]$Path) {
    $current = $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing cleanup through reparse point: $current" }
        }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }; $current=$parent
    }
}
function Remove-OwnedTree([string]$Path,[string]$AllowedRoot) {
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\');$allowed=[IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\')
    if ($full -ine $allowed -and -not $full.StartsWith($allowed+'\',[StringComparison]::OrdinalIgnoreCase)) { throw "Refusing cleanup outside owned root: $Path" }
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        if ($item.PSIsContainer) { [IO.Directory]::Delete($Path,$false) } else { [IO.File]::Delete($Path) };return
    }
    if ($item.PSIsContainer) {
        foreach($child in [IO.Directory]::GetFileSystemEntries($Path)){Remove-OwnedTree $child $AllowedRoot}
        [IO.Directory]::Delete($Path,$false)
    } else { [IO.File]::SetAttributes($Path,[IO.FileAttributes]::Normal);[IO.File]::Delete($Path) }
}
# Save requested tools on the current user Desktop before removing any working folders.
Assert-NoReparseAncestor $afterStage
if(-not (Test-Path -LiteralPath $afterStage -PathType Container)){throw 'Staged tools missing; cleanup cancelled'}
$afterFiles=@(Get-ChildItem -LiteralPath $afterStage -Force)
if(-not $afterFiles.Count){throw 'Staged tools empty; cleanup cancelled'}
Assert-NoReparseAncestor $afterFolder
[IO.Directory]::CreateDirectory($afterFolder)|Out-Null
foreach($afterFile in $afterFiles){
    if($afterFile.PSIsContainer -or ($afterFile.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unexpected tools item; cleanup cancelled'}
    $afterTarget=Join-Path $afterFolder $afterFile.Name
    Assert-NoReparseAncestor $afterTarget
    if((Test-Path -LiteralPath $afterTarget) -and -not (Test-Path -LiteralPath $afterTarget -PathType Leaf)){throw 'Destination is not a file; cleanup cancelled'}
    Copy-Item -LiteralPath $afterFile.FullName -Destination $afterTarget -Force -ErrorAction Stop
    if((Get-FileHash -LiteralPath $afterFile.FullName -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $afterTarget -Algorithm SHA256).Hash){throw 'Desktop tools verification failed; cleanup cancelled'}
}
# No Logs directory is created.
try {
    Assert-NoReparseAncestor $projectRoot
    Assert-NoReparseAncestor $runtimeRoot
    $packageRecord=Join-Path $runtimeRoot 'source-package.path'
    $downloadedPackage=if(Test-Path -LiteralPath $packageRecord){Assert-NoReparseAncestor $packageRecord;[IO.File]::ReadAllText($packageRecord).Trim()}else{''}
    # User explicitly requested the entire Windows Setup directory, not only our files.
    # Run only at the final optimization stage, after installation/first-logon work.
    $setupRoot=Join-Path $env:SystemRoot 'Setup'
    try {
        if(Test-Path -LiteralPath $setupRoot){
            Assert-NoReparseAncestor $setupRoot
            Remove-OwnedTree $setupRoot $setupRoot
            if(Test-Path -LiteralPath $setupRoot){throw 'Windows Setup directory still exists'}
            Write-CleanupStatus 'Removed entire Windows Setup directory.'
        }
    } catch { Write-CleanupStatus ('ERROR removing Windows Setup: '+$_.Exception.Message);Write-Warning ('Windows Setup cleanup incomplete: '+$_.Exception.Message) }
    foreach($legacyLog in @((Join-Path $env:PUBLIC 'WinSux-Locale.log'),(Join-Path $env:PUBLIC 'WinSux-Locale-error.log'),(Join-Path $env:SystemRoot 'Temp\WinSux-DriverPolicies.log'))){
        if(Test-Path -LiteralPath $legacyLog -PathType Leaf){Assert-NoReparseAncestor $legacyLog;Remove-Item -LiteralPath $legacyLog -Force -ErrorAction Stop}
    }
    # Remove only known project logs left by earlier versions; never archive them.
    $oldDesktopLogs=Join-Path $afterFolder 'Logs'
    if(Test-Path -LiteralPath $oldDesktopLogs){
        Assert-NoReparseAncestor $oldDesktopLogs
        foreach($oldLogName in @('PersonalSettings.log','EdgeRemoval.log','Cleanup.log','WinSux-Locale.log','WinSux-Locale-error.log','WinSux-DriverPolicies.log')){
            $oldLogPath=Join-Path $oldDesktopLogs $oldLogName
            if(Test-Path -LiteralPath $oldLogPath -PathType Leaf){Assert-NoReparseAncestor $oldLogPath;Remove-Item -LiteralPath $oldLogPath -Force -ErrorAction Stop}
        }
        if(-not @(Get-ChildItem -LiteralPath $oldDesktopLogs -Force).Count){[IO.Directory]::Delete($oldDesktopLogs,$false)}
    }
    if($downloadedPackage){
        $base=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'hh-optimization\Packages')).TrimEnd('\')
        $full=[IO.Path]::GetFullPath($downloadedPackage).TrimEnd('\')
        if((Split-Path -Leaf $full) -match '^[a-f0-9]{32}$' -and [IO.Path]::GetFullPath((Split-Path -Parent $full)).TrimEnd('\') -ieq $base){
            if(Test-Path -LiteralPath $full){Assert-NoReparseAncestor $full;Remove-OwnedTree $full $full;Write-CleanupStatus 'Removed this run downloaded package.'}
            if((Test-Path -LiteralPath $base) -and -not @(Get-ChildItem -LiteralPath $base -Force).Count){[IO.Directory]::Delete($base,$false)}
        }else{Write-CleanupStatus 'Ignored package record outside owned GUID package directory.'}
    }
    # All optimization stages have completed; the current script is loaded in memory.
    if(Test-Path -LiteralPath $projectRoot){
        Assert-NoReparseAncestor $projectRoot
        Remove-OwnedTree $projectRoot $projectRoot
        if(Test-Path -LiteralPath $projectRoot){throw 'ProgramData project directory still exists'}
        Write-CleanupStatus 'Removed entire ProgramData hh-optimization directory (including remaining files).'
    }
    # Manual tools are on Desktop, outside the entire LocalAppData project root.
    if(Test-Path -LiteralPath $localProjectRoot){
        Assert-NoReparseAncestor $localProjectRoot
        Remove-OwnedTree $localProjectRoot $localProjectRoot
        if(Test-Path -LiteralPath $localProjectRoot){throw 'LocalAppData project directory still exists'}
        Write-CleanupStatus 'Removed entire LocalAppData hh-optimization directory.'
    }
    Write-CleanupStatus ('Cleanup finished; errors, if any, were printed above. Tools: '+$afterFolder)
}catch{Write-CleanupStatus ('ERROR: '+$_.Exception.Message);Write-Warning ('Project cleanup incomplete: '+$_.Exception.Message)}
}
# END final cleanup of project-owned artifacts

Write-Host "DISK CLEANUP`n"
		## cleanmgr.exe
		## %temp%
		## temp

# clear %temp% folder
Remove-Item -Path "$env:USERPROFILE\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

# clear temp folder
Remove-Item -Path "$env:SystemDrive\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

# delete folders & files
Remove-Item "$env:SystemDrive\DumpStack.log" -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemDrive\Output.txt" -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemDrive\PerfLogs" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemDrive\Windows.old" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemDrive\XboxGames" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemDrive\inetpub" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

# clear windows updates cache folder
cmd /c "sc stop `"wuauserv`" >nul 2>&1"
Remove-Item "$env:SystemDrive\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

# run disk cleanup
cleanmgr.exe /autoclean /d C:

# Restore point creation deliberately omitted.

        Write-Host "RESTARTING`n" -ForegroundColor Red

# restart
Start-Sleep -Seconds 5
shutdown -r -t 00