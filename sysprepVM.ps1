Remove-Item -Recurse -Force C:\Windows\Panther
Remove-Item "$PSScriptRoot\*" -Force
Set-Location $env:windir\system32\sysprep
.\sysprep.exe /oobe /generalize /mode:vm /shutdown
