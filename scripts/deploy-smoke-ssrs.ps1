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
function Ensure-Folder($path) {
  $exists = Get-RsFolder -ReportServerUri $ApiUrl -Path $path -Credential $cred -ErrorAction SilentlyContinue
  if (-not $exists) {
    $parent = Split-Path $path
    if (-not (Get-RsFolder -ReportServerUri $ApiUrl -Path $parent -Credential $cred -ErrorAction SilentlyContinue)) {
      throw "La carpeta padre '$parent' no existe; créala primero o usa una ruta válida."
    }
    New-RsFolder -ReportServerUri $ApiUrl -Path $parent -Name (Split-Path $path -Leaf) -Credential $cred | Out-Null
    Write-Host "Creada carpeta: $path"
  } else {
    Write-Host "OK carpeta: $path"
  }
}

# 4) Crear/validar carpeta destino
Ensure-Folder $TargetFolder

# 5) Publicar recurso opcional
$img = Join-Path -Path $PSScriptRoot -ChildPath "..\reports\Resources\logo.png"
if (Test-Path $img) {
  Write-RsCatalogItem -ReportServerUri $ApiUrl -Path $TargetFolder -Name "logo.png" `
    -ItemType "Resource" -Overwrite -Content (Resolve-Path $img) -MimeType "image/png" -Credential $cred | Out-Null
  Write-Host "Publicado recurso: logo.png"
}

# 6) Publicar RDL de prueba
$rdl = Join-Path -Path $PSScriptRoot -ChildPath "..\reports\RDL\smoke\hello_world.rdl"
if (-not (Test-Path $rdl)) { throw "No existe el RDL de prueba: $rdl" }

Write-RsCatalogItem -ReportServerUri $ApiUrl -Path $TargetFolder -Name "hello_world" `
  -ItemType "Report" -Overwrite -Content (Resolve-Path $rdl) -Credential $cred | Out-Null
Write-Host "Publicado reporte: hello_world"

# 7) (Opcional) Vincular DataSource compartido si tu RDL lo requiere
# Set-RsDataSourceReference -ReportServerUri $ApiUrl -Path "$TargetFolder/hello_world" `
#   -DataSourceName "DS_MAIN" -ReferencePath "/DataSources/DW" -Credential $cred

Write-Host "Smoke test OK → revisa: $PortalUrl$TargetFolder"
