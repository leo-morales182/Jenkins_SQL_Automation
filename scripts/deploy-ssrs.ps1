param(
  [Parameter(Mandatory=$true)] [string]$PortalUrl,      # ej: http://localhost/Reports  (solo informativo)
  [Parameter(Mandatory=$true)] [string]$ApiUrl,         # ej: http://localhost/ReportServer
  [Parameter()] [string]$TargetBase = "/Apps",          # carpeta raíz en SSRS
  [string]$RepoRoot,
  [string]$User,
  [string]$Pass
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"

# --- Credenciales opcionales ---
$cred = $null
if ($User -and $Pass) {
  $sec = ConvertTo-SecureString $Pass -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential($User, $sec)
}

if (-not $RepoRoot -or -not (Test-Path $RepoRoot)) {
  $candidate1 = Join-Path $PSScriptRoot "..\reports"
  $candidate2 = Join-Path $env:WORKSPACE "ssrs\reports"
  if     (Test-Path $candidate1) { $RepoRoot = $candidate1 }
  elseif (Test-Path $candidate2) { $RepoRoot = $candidate2 }
  else  { throw "No encuentro carpeta 'reports' en: `n - $candidate1 `n - $candidate2" }
}
Write-Host "RepoRoot: $RepoRoot"

# --- Helpers SSRS ---

function Normalize-RsPath {
  param([Parameter(Mandatory=$true)][string]$Path)
  $p = $Path.Trim().Replace('\','/')
  if (-not $p.StartsWith('/')) { $p = '/' + $p }
  $p = $p -replace '/{2,}','/'
  if ($p.Length -gt 1 -and $p.EndsWith('/')) { $p = $p.TrimEnd('/') }
  return $p
}

function Ensure-RsPath {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][string]$Path
  )
  $p = Normalize-RsPath $Path
  if ($p -eq '/') { return }
  $segments = $p.TrimStart('/').Split('/')
  $current = '/'

  foreach ($seg in $segments) {
    $listArgs = @{ ReportServerUri = $ApiUrl; Path = $current; ErrorAction = 'SilentlyContinue' }
    if ($script:cred) { $listArgs.Credential = $script:cred }
    $kids = Get-RsFolderContent @listArgs

    if (-not ($kids | Where-Object { $_.TypeName -eq 'Folder' -and $_.Name -eq $seg })) {
      $newArgs = @{ ReportServerUri = $ApiUrl; Path = $current; Name = $seg; ErrorAction = 'Stop' }
      if ($script:cred) { $newArgs.Credential = $script:cred }
      New-RsFolder @newArgs | Out-Null
      Write-Host "Creada carpeta: $current/$seg"
    }

    if ($current -eq '/') {
      $current = "/$seg"
    } else {
      $current = "$current/$seg"
    }
  }
}

# --- Publicadores ---

function Publish-Resources {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][string]$LocalFolder,
    [Parameter(Mandatory=$true)][string]$RsFolder
  )
  if (-not (Test-Path $LocalFolder)) { return }
  $files = Get-ChildItem -Path $LocalFolder -File -Recurse
  foreach ($f in $files) {
    $args = @{
      ReportServerUri = $ApiUrl
      Path           = $f.FullName
      RsFolder       = (Normalize-RsPath $RsFolder)
      Overwrite      = $true
    }
    if ($script:cred) { $args.Credential = $script:cred }
    Write-RsCatalogItem @args | Out-Null
    Write-Host "Publicado recurso: $($f.Name) en $RsFolder"
  }
}

function Publish-DataSources {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][string]$LocalFolder,
    [Parameter(Mandatory=$true)][string]$RsFolder
  )
  if (-not (Test-Path $LocalFolder)) { return }
  $dss = Get-ChildItem -Path $LocalFolder -File -Include *.rds,*.rsds -Recurse
  foreach ($ds in $dss) {
    $args = @{
      ReportServerUri = $ApiUrl
      Path           = $ds.FullName
      RsFolder       = (Normalize-RsPath $RsFolder)
      Overwrite      = $true
    }
    if ($script:cred) { $args.Credential = $script:cred }
    Write-RsCatalogItem @args | Out-Null
    Write-Host "Publicado DataSource: $($ds.Name) en $RsFolder"
  }
}

function Publish-DataSets {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][string]$LocalFolder,
    [Parameter(Mandatory=$true)][string]$RsFolder
  )
  if (-not (Test-Path $LocalFolder)) { return }
  $sets = Get-ChildItem -Path $LocalFolder -File -Include *.rsd -Recurse
  foreach ($s in $sets) {
    $args = @{
      ReportServerUri = $ApiUrl
      Path           = $s.FullName
      RsFolder       = (Normalize-RsPath $RsFolder)
      Overwrite      = $true
    }
    if ($script:cred) { $args.Credential = $script:cred }
    Write-RsCatalogItem @args | Out-Null
    Write-Host "Publicado DataSet: $($s.Name) en $RsFolder"
  }
}

# --- RDL: extracción y remapeo de DS ---

function Get-RdlDataSourceRefs {
  param([Parameter(Mandatory=$true)][string]$RdlPath)

  [xml]$x = Get-Content $RdlPath

  # namespaces posibles
  $namespaces = @(
    @{ pfx='d'; uri='http://schemas.microsoft.com/sqlserver/reporting/2008/01/reportdefinition' },
    @{ pfx='d'; uri='http://schemas.microsoft.com/sqlserver/reporting/2016/01/reportdefinition' }
  )

  $nodes = $null
  foreach ($ns in $namespaces) {
    $nm = New-Object System.Xml.XmlNamespaceManager($x.NameTable)
    $nm.AddNamespace($ns.pfx, $ns.uri) | Out-Null
    $nodes = $x.SelectNodes("//d:Report/d:DataSources/d:DataSource", $nm)
    if ($nodes -and $nodes.Count -gt 0) { break }
  }

  $out = @()
  if ($nodes) {
    foreach ($n in $nodes) {
      $name = $n.Name
      # si existe DataSourceReference como string, tomarlo
      $ref = $n.DataSourceReference
      if ($ref) {
        $out += [pscustomobject]@{ Name=$name; Reference=($ref.'#text') }
      } else {
        $out += [pscustomobject]@{ Name=$name; Reference=$null }  # embebido
      }
    }
  }
  return $out
}

function Publish-Reports-And-MapDS {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][string]$LocalReportsFolder,
    [Parameter(Mandatory=$true)][string]$ProjectRsFolder,      # /Apps/Proyecto
    [Parameter(Mandatory=$true)][string]$SharedDsFolder        # /Apps/Shared/Data Sources
  )
  if (-not (Test-Path $LocalReportsFolder)) { return }
  $rdls = Get-ChildItem -Path $LocalReportsFolder -File -Include *.rdl -Recurse

  foreach ($rdl in $rdls) {
    # Publicar el RDL
    $pubArgs = @{
      ReportServerUri = $ApiUrl
      Path           = $rdl.FullName
      RsFolder       = (Normalize-RsPath $ProjectRsFolder)
      Overwrite      = $true
    }
    if ($script:cred) { $pubArgs.Credential = $script:cred }
    Write-RsCatalogItem @pubArgs | Out-Null
    Write-Host "Publicado RDL: $($rdl.Name) en $ProjectRsFolder"

    # Remapeo de DS
    $dsList = Get-RdlDataSourceRefs -RdlPath $rdl.FullName
    foreach ($ds in $dsList) {
      if (-not $ds.Reference) {
        Write-Host "  - DS '$($ds.Name)' embebido (sin remap)."
        continue
      }

      $reportItemPath   = (Normalize-RsPath ("$ProjectRsFolder/" + [System.IO.Path]::GetFileNameWithoutExtension($rdl.Name)))
      $candidateProject = (Normalize-RsPath ("$ProjectRsFolder/" + $ds.Reference))
      $candidateShared  = (Normalize-RsPath ("$SharedDsFolder/" + $ds.Reference))

      # ¿existe en proyecto?
      $getArgs = @{ ReportServerUri = $ApiUrl; Path = $candidateProject; ErrorAction = 'SilentlyContinue' }
      if ($script:cred) { $getArgs.Credential = $script:cred }
      $existsProject = Get-RsCatalogItem @getArgs

      if ($existsProject) {
        $targetRef = $candidateProject
      } else {
        $targetRef = $candidateShared
      }

      $mapArgs = @{
        ReportServerUri = $ApiUrl
        Path           = $reportItemPath
        DataSourceName = $ds.Name
        RsItem         = $targetRef
      }
      if ($script:cred) { $mapArgs.Credential = $script:cred }
      Set-RsDataSourceReference @mapArgs | Out-Null

      Write-Host "  - DS '$($ds.Name)' → $targetRef"
    }
  }
}

# --- ORQUESTADOR ---

$TargetBase = Normalize-RsPath $TargetBase
$RepoRoot   = Join-Path $PSScriptRoot "..\reports"

# 0) estructura base
Ensure-RsPath -ApiUrl $ApiUrl -Path $TargetBase
Ensure-RsPath -ApiUrl $ApiUrl -Path "$TargetBase/Shared/Data Sources"
Ensure-RsPath -ApiUrl $ApiUrl -Path "$TargetBase/Shared/Data Sets"
Ensure-RsPath -ApiUrl $ApiUrl -Path "$TargetBase/Shared/Resources"

# 1) publicar shared
Publish-DataSources -ApiUrl $ApiUrl -LocalFolder (Join-Path $RepoRoot "Shared\DataSources") -RsFolder "$TargetBase/Shared/Data Sources"
Publish-DataSets   -ApiUrl $ApiUrl -LocalFolder (Join-Path $RepoRoot "Shared\DataSets")   -RsFolder "$TargetBase/Shared/Data Sets"
Publish-Resources  -ApiUrl $ApiUrl -LocalFolder (Join-Path $RepoRoot "Shared\Resources")  -RsFolder "$TargetBase/Shared/Resources"

# 2) proyectos (todas las carpetas excepto Shared)
$projects = Get-ChildItem -Path $RepoRoot -Directory | Where-Object { $_.Name -ne 'Shared' }
foreach ($proj in $projects) {
  $projName     = $proj.Name
  $projRsFolder = "$TargetBase/$projName"
  Ensure-RsPath -ApiUrl $ApiUrl -Path $projRsFolder

  Publish-DataSources -ApiUrl $ApiUrl -LocalFolder (Join-Path $proj.FullName "DataSources") -RsFolder $projRsFolder
  Publish-Resources  -ApiUrl $ApiUrl -LocalFolder (Join-Path $proj.FullName "Resources")   -RsFolder "$projRsFolder/Resources"

  Publish-Reports-And-MapDS `
    -ApiUrl $ApiUrl `
    -LocalReportsFolder (Join-Path $proj.FullName "Reports") `
    -ProjectRsFolder $projRsFolder `
    -SharedDsFolder "$TargetBase/Shared/Data Sources"
}
