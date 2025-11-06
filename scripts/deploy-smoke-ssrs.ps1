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


# 2) Credenciales (si se proveen)
$cred = $null
if ($User -and $Pass) {
  $sec = ConvertTo-SecureString $Pass -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential($User,$sec)
}

function Normalize-RsPath {
  param([Parameter(Mandatory=$true)][string]$Path)
  # Reemplaza \ por /, quita espacios, fuerza raíz
  $p = $Path.Trim().Replace('\','/')
  if (-not $p.StartsWith('/')) { $p = '/' + $p }
  # quita doble slash
  $p = $p -replace '/{2,}','/'
  # quita trailing slash salvo raíz
  if ($p.Length -gt 1 -and $p.EndsWith('/')) { $p = $p.TrimEnd('/') }
  return $p
}

function Get-RsParentPath {
  param([Parameter(Mandatory=$true)][string]$Path)
  $p = Normalize-RsPath $Path
  if ($p -eq '/') { return $null }                # raíz no tiene padre
  $lastSlash = $p.LastIndexOf('/')
  if ($lastSlash -le 0) { return '/' }            # p.ej. '/Apps' -> '/'
  return $p.Substring(0, $lastSlash)
}

function Get-RsLeafName {
  param([Parameter(Mandatory=$true)][string]$Path)
  $p = Normalize-RsPath $Path
  if ($p -eq '/') { return '/' }
  $lastSlash = $p.LastIndexOf('/')
  return $p.Substring($lastSlash + 1)
}

# 3) Helper: asegurar carpeta en SSRS
function Test-RsFolderExists {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter()][pscredential]$Credential
  )
  $p      = Normalize-RsPath $Path
  $parent = Get-RsParentPath $p
  $leaf   = Get-RsLeafName   $p

  if (-not $parent) { return $true }  # raíz

  $items = Get-RsFolderContent -ReportServerUri $ApiUrl -Path $parent -Credential $Credential -ErrorAction SilentlyContinue
  return $items | Where-Object { $_.TypeName -eq 'Folder' -and $_.Name -eq $leaf }
}

function Ensure-Folder {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter()][pscredential]$Credential
  )

  $p      = Normalize-RsPath $Path
  if ($p -eq '/') { return }  # nada que crear

  if (-not (Test-RsFolderExists -ApiUrl $ApiUrl -Path $p -Credential $Credential)) {
    $parent = Get-RsParentPath $p
    if (-not $parent) { $parent = '/' }
    # Asegura que el padre exista (recursivo)
    if ($parent -ne '/' -and -not (Test-RsFolderExists -ApiUrl $ApiUrl -Path $parent -Credential $Credential)) {
      Ensure-Folder -ApiUrl $ApiUrl -Path $parent -Credential $Credential
    }
    New-RsFolder -ReportServerUri $ApiUrl -Path $parent -Name (Get-RsLeafName $p) -Credential $Credential | Out-Null
    Write-Host "Creada carpeta: $p"
  } else {
    Write-Host "OK carpeta: $p"
  }
}

# 4) Crear/validar carpeta destino
$TargetFolder = Normalize-RsPath $TargetFolder
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
