param(
  [Parameter(Mandatory=$true)] [string]$PortalUrl,      # ej: http://localhost/reports
  [Parameter(Mandatory=$true)] [string]$ApiUrl,         # ej: http://localhost/reportserver
  [Parameter(Mandatory=$true)] [string]$TargetFolder,   # ej: /Apps/Smoke
  [string]$User, [string]$Pass                          # opcional: si deseas credenciales explícitas
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 1) Instalar/Importar RSTools (safe para correr en cada build)
if (-not (Get-Module -ListAvailable -Name ReportingServicesTools)) {
  Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
  Install-Module ReportingServicesTools -Scope CurrentUser -Force -AllowClobber
}
Import-Module ReportingServicesTools -Force

# 2) Credenciales (si se proveen)
$cred = $null
if ($User -and $Pass) {
  $sec = ConvertTo-SecureString $Pass -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential($User,$sec)
}

# 3) Helper: asegurar carpeta en SSRS
function Test-RsFolderExists {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter()][pscredential]$Credential
  )
  $parent = Split-Path $Path
  $leaf   = Split-Path $Path -Leaf
  $items = Get-RsFolderContent -ReportServerUri $ApiUrl -Path $parent -Credential $Credential -ErrorAction SilentlyContinue
  return $items | Where-Object { $_.TypeName -eq 'Folder' -and $_.Name -eq $leaf }
}

function Ensure-Folder {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter()][pscredential]$Credential
  )
  if (-not (Test-RsFolderExists -ApiUrl $ApiUrl -Path $Path -Credential $Credential)) {
    $parent = Split-Path $Path
    if (-not (Get-RsFolderContent -ReportServerUri $ApiUrl -Path $parent -Credential $Credential -ErrorAction SilentlyContinue)) {
      throw "La carpeta padre '$parent' no existe; créala primero o usa una ruta válida."
    }
    New-RsFolder -ReportServerUri $ApiUrl -Path $parent -Name (Split-Path $Path -Leaf) -Credential $Credential | Out-Null
    Write-Host "Creada carpeta: $Path"
  } else {
    Write-Host "OK carpeta: $Path"
  }
}

# 4) Crear/validar carpeta destino
Ensure-Folder -ApiUrl $ApiUrl -Path $TargetFolder -Credential $cred

# 5) Publicar recurso opcional
$img = Join-Path -Path $PSScriptRoot -ChildPath "..\reports\Resources\logo.jpg"
if (Test-Path $img) {
  Write-RsCatalogItem -ReportServerUri $ApiUrl -Path $TargetFolder -Name "logo.jpg" `
    -ItemType "Resource" -Overwrite -Content (Resolve-Path $img) -MimeType "image/jpg" -Credential $cred | Out-Null
  Write-Host "Publicado recurso: logo.jpg"
}

# 6) Publicar RDL de prueba
$rdl = Join-Path -Path $PSScriptRoot -ChildPath "..\reports\RDL\smoke\Smoke_detailed.rdl"
if (-not (Test-Path $rdl)) { throw "No existe el RDL de prueba: $rdl" }

Write-RsCatalogItem -ReportServerUri $ApiUrl -Path $TargetFolder -Name "Smoke_detailed" `
  -ItemType "Report" -Overwrite -Content (Resolve-Path $rdl) -Credential $cred | Out-Null
Write-Host "Publicado reporte: Smoke_detailed"

# 7) (Opcional) Vincular DataSource compartido si tu RDL lo requiere
# Set-RsDataSourceReference -ReportServerUri $ApiUrl -Path "$TargetFolder/hello_world" `
#   -DataSourceName "DS_MAIN" -ReferencePath "/DataSources/DW" -Credential $cred

Write-Host "Smoke test OK → revisa: $PortalUrl$TargetFolder"
