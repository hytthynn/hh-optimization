#requires -Version 5.1
# hh-optimization installed-Windows optimization. Based on FR33THY WinSux / Ultimate (MIT).
[CmdletBinding()]
param()
$hhExpectedEntry = 'optimization.ps1'
if ($env:OS -ne 'Windows_NT') { throw 'Windows is required.' }
$hhPathProperty = $MyInvocation.MyCommand.PSObject.Properties['Path']
$hhEntryPath = if ($hhPathProperty) { [string]$hhPathProperty.Value } else { $null }
$hhExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not $hhEntryPath -or ([IO.Path]::GetFileName($hhEntryPath) -ine $hhExpectedEntry)) {
    # Web invocation downloads the complete repository, then starts THIS entry.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $hhPackage = Join-Path $env:LOCALAPPDATA ('hh-optimization\Packages\' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($hhPackage) | Out-Null
    $hhArchive = Join-Path $hhPackage 'source.zip'
    try {
        Write-Host 'Downloading hh-optimization...' -ForegroundColor Cyan
        $hhUrl = 'https://codeload.github.com/hytthynn/hh-optimization/zip/refs/heads/main?fresh=' + [guid]::NewGuid().ToString('N')
        Invoke-WebRequest -UseBasicParsing -Uri $hhUrl -OutFile $hhArchive -ErrorAction Stop
        Expand-Archive -LiteralPath $hhArchive -DestinationPath $hhPackage -Force -ErrorAction Stop
        $hhLocalEntry = Join-Path $hhPackage ('hh-optimization-main\Optimization\' + $hhExpectedEntry)
        if (-not (Test-Path -LiteralPath $hhLocalEntry -PathType Leaf)) { throw 'Downloaded entrypoint is missing.' }
        & $hhExe -NoProfile -ExecutionPolicy Bypass -File $hhLocalEntry
        if ($LASTEXITCODE -ne 0) { throw "Entrypoint exited with code $LASTEXITCODE" }
    } finally { Remove-Item -LiteralPath $hhArchive -Force -ErrorAction SilentlyContinue }
    return
}
$hhIsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $hhIsAdmin) {
    $hhArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $hhEntryPath
    $hhProcess = Start-Process -FilePath $hhExe -ArgumentList $hhArguments -Verb RunAs -Wait -PassThru -ErrorAction Stop
    if ($hhProcess.ExitCode -ne 0) { throw "Elevated process exited with code $($hhProcess.ExitCode)" }
    return
}
# Continue after elevation without an additional APPLY prompt.


        $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + " (Administrator)"
        $Host.UI.RawUI.BackgroundColor = "Black"
        $Host.PrivateData.ProgressBackgroundColor = "Black"
        $Host.PrivateData.ProgressForegroundColor = "White"
        Clear-Host

        # SCRIPT CHECK INTERNET
        if (!(Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        Write-Host "Internet Connection Required`n" -ForegroundColor Red
        Pause
        exit
        }

        # SCRIPT SILENT
        $progresspreference = 'silentlycontinue'

        Write-Host "DL`n"
		## explorer "https://github.com/hytthynn/hh-optimization/tree/main/Optimization"

# Stage this local customized build. Never download upstream scripts over these files.
$runtime = Join-Path $env:ProgramData 'hh-optimization\Runtime'
[IO.Directory]::CreateDirectory($runtime) | Out-Null
foreach ($name in @('reg.reg','settimerresolutionservice.cs','start2.txt','stepone.ps1','steptwo.ps1')) {
    $localFile = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $localFile -PathType Leaf)) { throw "Missing local payload: $localFile" }
    Copy-Item -LiteralPath $localFile -Destination (Join-Path $runtime $name) -Force -ErrorAction Stop
}
# Manual post-optimization tools: stage files only, never execute them.
$afterSource=Join-Path $PSScriptRoot 'После Оптимизации'
$afterStage=Join-Path $runtime 'После Оптимизации'
if(-not (Test-Path -LiteralPath $afterSource -PathType Container)){throw 'Post-optimization tools folder missing'}
if((Get-Item -LiteralPath $afterSource -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Tools folder must not be a link'}
$afterFiles=@(Get-ChildItem -LiteralPath $afterSource -Force)
if(-not $afterFiles.Count){throw 'Tools folder empty'}
foreach($afterFile in $afterFiles){if($afterFile.PSIsContainer -or ($afterFile.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Only regular tool files allowed'}}
[IO.Directory]::CreateDirectory($afterStage)|Out-Null
foreach($afterFile in $afterFiles){Copy-Item -LiteralPath $afterFile.FullName -Destination (Join-Path $afterStage $afterFile.Name) -Force -ErrorAction Stop}
# Record only a project-owned downloaded package for final cleanup.
$packageBase = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'hh-optimization\Packages')).TrimEnd('\')
$sourcePackage = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ($sourcePackage -and (Split-Path -Leaf $sourcePackage) -match '^[a-f0-9]{32}$' -and [IO.Path]::GetFullPath((Split-Path -Parent $sourcePackage)).TrimEnd('\') -ieq $packageBase) {
    [IO.File]::WriteAllText((Join-Path $runtime 'source-package.path'),$sourcePackage,[Text.UTF8Encoding]::new($false))
}

        Write-Host "7Z`n"
        ## explorer "https://www.7-zip.org" 

# download 7zip
IWR "https://github.com/hytthynn/hh-optimization/releases/download/Files/7zip.exe" -OutFile "$env:ProgramData\hh-optimization\Runtime\7zip.exe"

# install 7zip
Start-Process -Wait "$env:ProgramData\hh-optimization\Runtime\7zip.exe" -ArgumentList "/S"

# set config for 7zip
cmd /c "reg add `"HKEY_CURRENT_USER\Software\7-Zip\Options`" /v `"ContextMenu`" /t REG_DWORD /d `"259`" /f >nul 2>&1"
cmd /c "reg add `"HKEY_CURRENT_USER\Software\7-Zip\Options`" /v `"CascadedMenu`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# cleaner start menu shortcut path
Move-Item -Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip\7-Zip File Manager.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

        Write-Host "C++`n"
		## explorer "https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170"

# download c++
IWR "https://github.com/hytthynn/hh-optimization/releases/download/Files/vcredist2005_x86.exe" -OutFile "$env:ProgramData\hh-optimization\Runtime\vcredist2005_x86.exe"
IWR "https://github.com/hytthynn/hh-optimization/releases/download/Files/vcredist2005_x64.exe" -OutFile "$env:ProgramData\hh-optimization\Runtime\vcredist2005_x64.exe"
IWR "https://github.com/hytthynn/hh-optimization/releases/download/Files/vcredist2008_x86.exe" -OutFile "$env:ProgramData\hh-optimization\Runtime\vcredist2008_x86.exe"
IWR "https://github.com/hytthynn/hh-optimization/releases/download/Files/vcredist2008_x64.exe" -OutFile "$env:ProgramData\hh-optimization\Runtime\vcredist2008_x64.exe"
IWR "https://github.com/hytthynn/hh-optimization/releases/download/Files/vcredist2010_x86.exe" -OutFile "$env:ProgramData\hh-optimization\Runtime\vcredist2010_x86.exe"
IWR "https://github.com/hytthynn/hh-optimization/releases/download/Files/vcredist2010_x64.exe" -OutFile "$env:ProgramData\hh-optimization\Runtime\vcredist2010_x64.exe"
IWR "https://github.com/hytthynn/hh-optimization/releases/download/Files/vcredist2012_x86.exe" -OutFile "$env:ProgramData\hh-optimization\Runtime\vcredist2012_x86.exe"
IWR "https://github.com/hytthynn/hh-optimization/releases/download/Files/vcredist2012_x64.exe" -OutFile "$env:ProgramData\hh-optimization\Runtime\vcredist2012_x64.exe"
IWR "https://github.com/hytthynn/hh-optimization/releases/download/Files/vcredist2013_x86.exe" -OutFile "$env:ProgramData\hh-optimization\Runtime\vcredist2013_x86.exe"
IWR "https://github.com/hytthynn/hh-optimization/releases/download/Files/vcredist2013_x64.exe" -OutFile "$env:ProgramData\hh-optimization\Runtime\vcredist2013_x64.exe"
IWR "https://github.com/hytthynn/hh-optimization/releases/download/Files/vcredist2015_2017_2019_2022_x86.exe" -OutFile "$env:ProgramData\hh-optimization\Runtime\vcredist2015_2017_2019_2022_x86.exe"
IWR "https://github.com/hytthynn/hh-optimization/releases/download/Files/vcredist2015_2017_2019_2022_x64.exe" -OutFile "$env:ProgramData\hh-optimization\Runtime\vcredist2015_2017_2019_2022_x64.exe"

# install c++
Start-Process -Wait "$env:ProgramData\hh-optimization\Runtime\vcredist2005_x86.exe" -ArgumentList "/Q /C:`"msiexec /i vcredist.msi /qn /norestart`"" -WindowStyle Hidden
Start-Process -Wait "$env:ProgramData\hh-optimization\Runtime\vcredist2005_x64.exe" -ArgumentList "/Q /C:`"msiexec /i vcredist.msi /qn /norestart`"" -WindowStyle Hidden
Start-Process -Wait "$env:ProgramData\hh-optimization\Runtime\vcredist2008_x86.exe" -ArgumentList "/q" -WindowStyle Hidden
Start-Process -Wait "$env:ProgramData\hh-optimization\Runtime\vcredist2008_x64.exe" -ArgumentList "/q" -WindowStyle Hidden
Start-Process -Wait "$env:ProgramData\hh-optimization\Runtime\vcredist2010_x86.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
Start-Process -Wait "$env:ProgramData\hh-optimization\Runtime\vcredist2010_x64.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
Start-Process -Wait "$env:ProgramData\hh-optimization\Runtime\vcredist2012_x86.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
Start-Process -Wait "$env:ProgramData\hh-optimization\Runtime\vcredist2012_x64.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
Start-Process -Wait "$env:ProgramData\hh-optimization\Runtime\vcredist2013_x86.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
Start-Process -Wait "$env:ProgramData\hh-optimization\Runtime\vcredist2013_x64.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
Start-Process -Wait "$env:ProgramData\hh-optimization\Runtime\vcredist2015_2017_2019_2022_x86.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
Start-Process -Wait "$env:ProgramData\hh-optimization\Runtime\vcredist2015_2017_2019_2022_x64.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden 

# DDU removed from this build.

        Write-Host "HELIUM`n"
        ## explorer "https://helium.computer"

# download helium
IWR "https://github.com/hytthynn/hh-optimization/releases/download/Files/helium.exe" -OutFile "$env:ProgramData\hh-optimization\Runtime\helium.exe"

# install helium
Start-Process -Wait "$env:ProgramData\hh-optimization\Runtime\helium.exe" -ArgumentList "/S" -WindowStyle Hidden

# add helium policies
cmd /c "reg add `"HKLM\SOFTWARE\Policies\Helium`" /v `"HardwareAccelerationModeEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Policies\Helium`" /v `"BackgroundModeEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Policies\Helium`" /v `"HighEfficiencyModeEnabled`" /t REG_DWORD /d `"1`" /f >nul 2>&1"

# remove logon helium
$basePath = "HKLM:\Software\Microsoft\Active Setup\Installed Components"
Get-ChildItem $basePath | ForEach-Object {
$val = (Get-ItemProperty $_.PsPath)."(default)"
if ($val -like "*Helium*") {
Remove-Item $_.PsPath -Force -ErrorAction SilentlyContinue
}
}

# remove helium services
$services = Get-Service | Where-Object { $_.Name -match 'Helium' }
foreach ($service in $services) {
cmd /c "sc stop `"$($service.Name)`" >nul 2>&1"
cmd /c "sc delete `"$($service.Name)`" >nul 2>&1"
}

# remove helium scheduled tasks
Get-ScheduledTask | Where-Object { $_.TaskName -like '*Helium*' } | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

# cleaner start menu shortcut path
Move-Item -Path "$env:AppData\Microsoft\Windows\Start Menu\Programs\Helium.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue | Out-Null

        Write-Host "DIRECTX`n"
        ## explorer "https://www.microsoft.com/en-au/download/details.aspx?id=35"

# download directx
IWR "https://github.com/hytthynn/hh-optimization/releases/download/Files/directx.exe" -OutFile "$env:ProgramData\hh-optimization\Runtime\directx.exe"

# extract directx with 7zip
& "$env:SystemDrive\Program Files\7-Zip\7z.exe" x "$env:ProgramData\hh-optimization\Runtime\directx.exe" -o"$env:ProgramData\hh-optimization\Runtime\directx" -y | Out-Null

# install directx
Start-Process -Wait "$env:ProgramData\hh-optimization\Runtime\directx\DXSETUP.exe" -ArgumentList "/silent" -WindowStyle Hidden

        Write-Host "REMOVEUWP`n"
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

# allow password sign in
cmd /c "reg add `"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device`" /v `"DevicePasswordLessBuildVersion`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# Preserve default Windows Terminal delegation.

# install runonce stepone ps1 file to run in safe boot
cmd /c "reg add `"HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce`" /v `"*!stepone`" /t REG_SZ /d `"powershell.exe -nop -ep bypass -WindowStyle Maximized -f $env:ProgramData\hh-optimization\Runtime\stepone.ps1`" /f >nul 2>&1"

# install runonce steptwo ps1 file to run in normal boot
cmd /c "reg add `"HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce`" /v `"!steptwo`" /t REG_SZ /d `"powershell.exe -nop -ep bypass -WindowStyle Maximized -f $env:ProgramData\hh-optimization\Runtime\steptwo.ps1`" /f >nul 2>&1"

# turn on safe boot
cmd /c "bcdedit /set {current} safeboot minimal >nul 2>&1"

        Write-Host "RESTARTING`n" -ForegroundColor Red

# restart
Start-Sleep -Seconds 5
shutdown -r -t 00