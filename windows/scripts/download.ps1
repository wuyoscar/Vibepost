param([Parameter(Mandatory=$true)][string]$Url,[Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 300
