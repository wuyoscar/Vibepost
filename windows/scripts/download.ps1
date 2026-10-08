param([Parameter(Mandatory=$true)][string]$Url,[Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if(Get-Command curl.exe -ErrorAction SilentlyContinue){
  & curl.exe --fail --location --retry 3 --retry-delay 1 --connect-timeout 15 --max-time 300 --output $Destination $Url
  if($LASTEXITCODE -ne 0){throw "Download failed with curl exit $LASTEXITCODE"}
}else{
  Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 300
}
