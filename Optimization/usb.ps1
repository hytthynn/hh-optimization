#requires -Version 5.1
# hh-optimization USB preparation. Based on FR33THY WinSux / Ultimate (MIT).
[CmdletBinding()]
param()
$hhExpectedEntry = 'usb.ps1'
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
# USB preparation does not start OS optimization.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Escape-Xml([string]$Text) {
    [System.Security.SecurityElement]::Escape($Text)
}
Write-Host 'hh-optimization' -ForegroundColor Cyan
do {
    $userName = (Read-Host 'Имя нового пользователя (1-20 букв/цифр, _ или -, без пробелов)').Trim()
    $validName = $userName -match '^[\p{L}\p{Nd}_-]{1,20}$'
    $reserved = $userName -match '^(Administrator|Администратор|Guest|Гость|DefaultAccount|WDAGUtilityAccount|SYSTEM|LOCAL|NETWORK|CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$'
    if (-not $validName -or $reserved) { Write-Warning 'Недопустимое или зарезервированное имя.' }
} until ($validName -and -not $reserved)
do {
    $letterInput = (Read-Host 'Буква установочной флешки (например E или E:)').Trim()
    $validLetter = $letterInput -match '^[A-Za-z](?::\\?)?$'
    if (-not $validLetter) { Write-Warning 'Укажи одну букву диска.' }
} until ($validLetter)
$letter = $letterInput.Substring(0,1).ToUpperInvariant()
$usb = $letter + ':\'
if ($usb.TrimEnd('\') -eq $env:SystemDrive) { throw 'Системный диск запрещён.' }
if (-not (Test-Path -LiteralPath $usb -PathType Container)) { throw 'Диск не найден.' }
$logical = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($letter):'"
if ($null -eq $logical -or $logical.DriveType -notin @(2,3)) { throw 'Нужен локальный записываемый USB-носитель.' }
if (-not (Test-Path -LiteralPath (Join-Path $usb 'sources\boot.wim'))) {
    throw 'Нет sources\boot.wim. Сначала создай обычную установочную флешку, не Ventoy.'
}
$image = @('install.wim','install.esd','install.swm') | ForEach-Object {
    Join-Path $usb ('sources\' + $_)
} | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $image) { throw 'Нет sources\install.wim, install.esd или install.swm.' }
Import-Module Dism -ErrorAction Stop
Write-Host 'Чтение списка редакций образа (без монтирования и изменения)...'
$images = @(Get-WindowsImage -ImagePath $image)
$pro = @()
foreach ($entry in $images) {
    $detail = Get-WindowsImage -ImagePath $image -Index $entry.ImageIndex
    if ($detail.EditionId -eq 'Professional' -and [int]$detail.Architecture -eq 9) {
        $pro += $detail
    }
}
if ($pro.Count -ne 1) { throw 'Нужен ровно один образ Windows Pro (Professional) x64. Home/Pro N/ARM64 не подходят.' }
$selected = $pro[0]
if (($selected.Languages -join ';') -notmatch '(?i)\bru-RU\b') {
    throw 'В образе Pro нет русского языка. Используй русский ISO; языковые пакеты этот скрипт не скачивает.'
}
if (-not (Test-Path -LiteralPath (Join-Path $usb 'sources\ru-ru'))) {
    throw 'Нет sources\ru-ru. Требуется носитель с русским языком установщика.'
}
$imageIndex = [int]$selected.ImageIndex
$genericProKey = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T' # Public install key; NOT activation.
# Same driver policy values as Ultimate "5 Updates Drivers Block", USB option.
$driverCommands = @(
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\Device Metadata" /v PreventDeviceMetadataFromNetwork /t REG_DWORD /d 1 /f'
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\DeviceInstall\Settings" /v DisableSendGenericDriverNotFoundToWER /t REG_DWORD /d 1 /f'
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\DeviceInstall\Settings" /v DisableSendRequestAdditionalSoftwareToWER /t REG_DWORD /d 1 /f'
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\DriverSearching" /v SearchOrderConfig /t REG_DWORD /d 0 /f'
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v SetAllowOptionalContent /t REG_DWORD /d 0 /f'
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v AllowTemporaryEnterpriseFeatureControl /t REG_DWORD /d 0 /f'
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v ExcludeWUDriversInQualityUpdate /t REG_DWORD /d 1 /f'
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU" /v IncludeRecommendedUpdates /t REG_DWORD /d 0 /f'
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU" /v EnableFeaturedSoftware /t REG_DWORD /d 0 /f'
    'reg.exe add "HKLM\Software\Microsoft\Windows\CurrentVersion\DriverSearching" /v SearchOrderConfig /t REG_DWORD /d 0 /f'
)
# Windows Update block from Ultimate USB option 5.
# Use loopback instead of the upstream third-party domain; no external WSUS server.
$updateCommands = @(
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v DoNotConnectToWindowsUpdateInternetLocations /t REG_DWORD /d 1 /f'
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v UpdateServiceUrlAlternate /t REG_SZ /d "http://127.0.0.1:9" /f'
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /t REG_SZ /d "http://127.0.0.1:9" /f'
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /t REG_SZ /d "http://127.0.0.1:9" /f'
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v SetDisableUXWUAccess /t REG_DWORD /d 1 /f'
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v ExcludeWUDriversInQualityUpdate /t REG_DWORD /d 1 /f'
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f'
    'reg.exe add "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /t REG_DWORD /d 1 /f'
)
# Equivalent to AllowScripts.cmd / Scripts: On, applied only by Windows Setup.
$allowScriptsMachine = @'
$ErrorActionPreference = 'Stop'
try {
    $machineShellKey = 'HKLM:\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell'
    New-Item -Path $machineShellKey -Force | Out-Null
    New-ItemProperty -Path $machineShellKey -Name ExecutionPolicy -Value Unrestricted -PropertyType String -Force | Out-Null
    $openKey = 'HKLM:\SOFTWARE\Classes\Applications\powershell.exe\shell\open\command'
    New-Item -Path $openKey -Force | Out-Null
    $openCommand = '"' + $env:SystemRoot + '\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -ExecutionPolicy Unrestricted -File "%1"'
    Set-Item -Path $openKey -Value $openCommand
} catch {
    Write-Error $_
    exit 1
}
'@
$allowScriptsCommand = 'cmd.exe /d /c powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\hh-AllowScripts.ps1"'
$policyCommands = @($driverCommands) + @($updateCommands) + @($allowScriptsCommand)
# Apply in specialize independently of SetupComplete (OEM-key restriction).
$order = 0
$specializeAccountCommands = @(
    'net accounts /maxpwage:unlimited'
    "net user $userName /active:Yes"
    "net user $userName /passwordreq:no"
)
$specializeCommands = foreach ($command in (@($policyCommands) + @($specializeAccountCommands))) {
    $order++
    '<RunSynchronousCommand wcm:action="add"><Order>{0}</Order><Description>Update and driver policy {0}</Description><Path>{1}</Path><WillReboot>Never</WillReboot></RunSynchronousCommand>' -f $order,(Escape-Xml $command)
}
# This text is embedded for future first logon; it is NOT executed by this generator.
$localeScript = @'
$ErrorActionPreference = 'Stop'
try {
    # Apply AllowScripts.cmd user setting to the actual new user, not Setup's SYSTEM account.
    $userShellId = 'HKCU:\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell'
    New-Item -Path $userShellId -Force | Out-Null
    New-ItemProperty -Path $userShellId -Name ExecutionPolicy -Value Unrestricted -PropertyType String -Force | Out-Null
    # Scope file unblocking to the installed setup scripts, never entire drives.
    $setupScripts = Join-Path $env:SystemRoot 'Setup\Scripts'
    if (Test-Path -LiteralPath $setupScripts -PathType Container) {
        Get-ChildItem -LiteralPath $setupScripts -File -Recurse | Unblock-File
    }
    $languages = New-WinUserLanguageList 'ru-RU'
    $languages[0].InputMethodTips.Clear()
    $languages[0].InputMethodTips.Add('0419:00000419')
    $english = (New-WinUserLanguageList 'en-US')[0]
    $english.InputMethodTips.Clear()
    $english.InputMethodTips.Add('0409:00000409')
    $languages.Add($english)
    Set-WinUserLanguageList -LanguageList $languages -Force
    Set-WinDefaultInputMethodOverride -InputTip '0419:00000419'
    Set-WinUILanguageOverride -Language 'ru-RU'
    Set-Culture -CultureInfo 'ru-RU'
    Set-WinHomeLocation -GeoId 203
    Set-WinSystemLocale -SystemLocale 'ru-RU'
    Set-TimeZone -Id 'Russian Standard Time'
    Write-Host 'Locale settings applied; sign out/in to refresh all applications.'
} catch {
    Write-Warning $_.Exception.Message
    exit 1
}
'@
$localeCommand = 'cmd.exe /d /c powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\hh-FirstLogon.ps1"'
$escapedUser = Escape-Xml $userName
$xmlText = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>ru-RU</UILanguage></SetupUILanguage>
      <InputLocale>0419:00000419;0409:00000409</InputLocale>
      <SystemLocale>ru-RU</SystemLocale><UILanguage>ru-RU</UILanguage><UserLocale>ru-RU</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassTPMCheck" /t REG_DWORD /d 1 /f</Path>
                    <Description>Add BypassTPMCheck</Description>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassRAMCheck" /t REG_DWORD /d 1 /f</Path>
                    <Description>Add BypassRAMCheck</Description>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassSecureBootCheck" /t REG_DWORD /d 1 /f</Path>
                    <Description>Add BypassSecureBootCheck</Description>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassCPUCheck" /t REG_DWORD /d 1 /f</Path>
                    <Description>Add BypassCPUCheck</Description>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassStorageCheck" /t REG_DWORD /d 1 /f</Path>
                    <Description>Add BypassStorageCheck</Description>
                </RunSynchronousCommand>
            </RunSynchronous>
      <Diagnostics><OptIn>false</OptIn></Diagnostics>
      <DynamicUpdate><Enable>false</Enable><WillShowUI>OnError</WillShowUI></DynamicUpdate>
      <ImageInstall><OSImage><InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>$imageIndex</Value></MetaData></InstallFrom><WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>
      <UserData><AcceptEula>true</AcceptEula><ProductKey><Key>$genericProKey</Key><WillShowUI>OnError</WillShowUI></ProductKey></UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0419:00000419;0409:00000409</InputLocale>
      <SystemLocale>ru-RU</SystemLocale><UILanguage>ru-RU</UILanguage><UserLocale>ru-RU</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <TimeZone>Russian Standard Time</TimeZone>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>$($specializeCommands -join "`r`n")</RunSynchronous>
    </component>
    <component name="Microsoft-Windows-Security-SPP-UX" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SkipAutoActivation>true</SkipAutoActivation>
    </component>
    <component name="Microsoft-Windows-UnattendedJoin" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <Identification><JoinWorkgroup>WORKGROUP</JoinWorkgroup></Identification>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0419:00000419;0409:00000409</InputLocale>
      <SystemLocale>ru-RU</SystemLocale><UILanguage>ru-RU</UILanguage><UserLocale>ru-RU</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <TimeZone>Russian Standard Time</TimeZone>
      <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Home</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
      <UserAccounts><AdministratorPassword><PlainText>true</PlainText><Value></Value></AdministratorPassword><LocalAccounts><LocalAccount wcm:action="add"><Name>$escapedUser</Name><DisplayName>$escapedUser</DisplayName><Group>Administrators</Group><Password><Value></Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>
      <FirstLogonCommands><SynchronousCommand wcm:action="add"><Order>1</Order><Description>WinSux RU region and RU EN keyboard</Description><CommandLine>$(Escape-Xml $localeCommand)</CommandLine></SynchronousCommand></FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@
# Validate XML and documented command length limits before any USB writes.
# This does not replace full Windows SIM validation or an installation test.
$answerXml = [xml]$xmlText
foreach ($node in $answerXml.SelectNodes('//*[local-name()="RunSynchronousCommand"]/*[local-name()="Path"]')) {
    if ([string]::IsNullOrWhiteSpace($node.InnerText) -or $node.InnerText.Length -gt 259) {
        throw ('RunSynchronous Path exceeds the 259-character limit: ' + $node.InnerText.Length)
    }
}
foreach ($node in $answerXml.SelectNodes('//*[local-name()="FirstLogonCommands"]//*[local-name()="CommandLine"]')) {
    if ($node.InnerText.Length -gt 1024) {
        throw ('FirstLogon CommandLine exceeds the 1024-character limit: ' + $node.InnerText.Length)
    }
}
$cmdLines = @('@echo off','rem WINSUX-PERSONAL-MANAGED v0.1','setlocal')
foreach ($command in $policyCommands) {
    $cmdLines += $command
    $cmdLines += 'if errorlevel 1 exit /b 1'
}
$cmdLines += @('exit /b 0','')
$cmdText = $cmdLines -join "`r`n"
$eiText = "[EditionID]`r`nProfessional`r`n[Channel]`r`nRetail`r`n[VL]`r`n0`r`n"
$pidText = "[PID]`r`nValue=$genericProKey`r`n"
$files = @(
    @{ Relative = 'autounattend.xml'; Text = $xmlText; Encoding = [Text.UTF8Encoding]::new($true) }
    @{ Relative = 'sources\ei.cfg'; Text = $eiText; Encoding = [Text.Encoding]::ASCII }
    @{ Relative = 'sources\PID.txt'; Text = $pidText; Encoding = [Text.Encoding]::ASCII }
    @{ Relative = 'sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd'; Text = $cmdText; Encoding = [Text.Encoding]::ASCII }
    @{ Relative = 'sources\$OEM$\$$\Setup\Scripts\hh-AllowScripts.ps1'; Text = $allowScriptsMachine; Encoding = [Text.UTF8Encoding]::new($true) }
    @{ Relative = 'sources\$OEM$\$$\Setup\Scripts\hh-FirstLogon.ps1'; Text = $localeScript; Encoding = [Text.UTF8Encoding]::new($true) }
)
# Replace only the six generated USB files; no backups or current OS registry writes.
foreach ($file in $files) {
    $target = Join-Path $usb $file.Relative
    [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
    $temp = $target + '.winsux-' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, $file.Text, $file.Encoding)
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Force -ErrorAction Stop
        }
        Move-Item -LiteralPath $temp -Destination $target -Force
        $actual = [IO.File]::ReadAllText($target, $file.Encoding)
        if ($actual -cne $file.Text) { throw "Ошибка проверки записи: $target" }
        Write-Host ('Записан: ' + $target)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}
Write-Host ("Готово. Образ: {0}; индекс {1}; пользователь {2}." -f $selected.ImageName,$imageIndex,$userName) -ForegroundColor Green
