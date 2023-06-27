param (
    [string]$registrationtoken = $(throw "-registrationtoken is required.")
)

mkdir .\temp
Set-Location .\temp

#Download WVD Agent Installer
try {
    Invoke-WebRequest 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv' -UseBasicParsing -OutFile 'WVD-Agent.msi'
    "Downloaded WVD Agent Installer"
} 
catch {
    Throw "WVD Agent Installer is not downloaded"
}
#Install WVD Agent
try {
    Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i WVD-Agent.msi", "/quiet", "/qn", "/norestart", "/passive", "REGISTRATIONTOKEN=$($registrationtoken)"  -Wait
    "Installed WVD Agent"
}
catch {
    Throw "WVD Agent not installed $_"
}
#Download WVD BootLoader Installer
try {
    Invoke-WebRequest 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH' -UseBasicParsing -OutFile 'WVD-BootLoader.msi'
    "Downloaded WVD BootLoader Installer"
} 
catch {
    Throw "WVD BootLoader Installer is not downloaded"
}
#Install WVD BootLoader
try {
    Start-Process -FilePath "msiexec.exe" -ArgumentList "/i WVD-BootLoader.msi", "/quiet", "/qn", "/norestart", "/passive" -Wait
    "Installed WVD BootLoader"
}
catch {
    Throw "WVD BootLoader not installed $_"
}

Set-Location ..
Remove-Item -Recurse -Force .\temp
Remove-Item -Force $MyInvocation.MyCommand.Path
