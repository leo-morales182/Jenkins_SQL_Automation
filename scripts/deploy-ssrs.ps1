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
  $sec  = ConvertTo-SecureString $Pass -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential($User, $sec)
}
$script:cred = $cred

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

  [xml]$x = Get-Content -Raw $RdlPath
  $nsUris = @(
    "http://schemas.microsoft.com/sqlserver/reporting/2008/01/reportdefinition",
    "http://schemas.microsoft.com/sqlserver/reporting/2016/01/reportdefinition",
    "http://schemas.microsoft.com/sqlserver/reporting/2017/01/reportdefinition"
  )

  foreach ($nsUri in $nsUris) {
    $nsm = New-Object System.Xml.XmlNamespaceManager($x.NameTable)
    $nsm.AddNamespace("d", $nsUri)

    $nodes = $x.SelectNodes("//d:Report/d:DataSources/d:DataSource", $nsm)
    if ($nodes -and $nodes.Count -gt 0) {
      $out = @()
      foreach ($n in $nodes) {
        # Nombre puede ser atributo @Name
        $name = $null
        if ($n.Attributes -and $n.Attributes["Name"]) {
          $name = $n.Attributes["Name"].Value
        } else {
          $attrNode = $n.SelectSingleNode("@Name")
          if ($attrNode) { $name = $attrNode.Value }
        }

        # Referencia a shared DS (DataSourceReference)
        $ref = $null
        $refNode = $n.SelectSingleNode("d:DataSourceReference", $nsm)
        if ($refNode) { $ref = $refNode.InnerText }

        $out += [pscustomobject]@{ Name = $name; Reference = $ref }
      }
      return $out
    }
  }

  throw "No pude leer DataSources del RDL (namespace no reconocido o estructura inesperada)."
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

  # Forzar el cmdlet del módulo correcto para evitar alias/confusiones
  $SetDsRef = Get-Command 'ReportingServicesTools\Set-RsDataSourceReference' -ErrorAction Stop

  # (opcional) diagnóstico ligero
  $cmds = Get-Command Set-RsDataSourceReference -All | Where-Object { $_.ModuleName -eq 'ReportingServicesTools' }
  Write-Host "Set-RsDataSourceReference encontrados:"
  $cmds | ForEach-Object { Write-Host ("  - {0} :: {1} ({2})" -f $_.Name, $_.ModuleName, $_.CommandType) }

  # limpia aliases por si acaso
  Remove-Item alias:Set-RsDataSourceReference -ErrorAction SilentlyContinue
  Remove-Item alias:Set-RsDataSource          -ErrorAction SilentlyContinue



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
    # 2) Re-mapear DS por nombre o path
    $dsList = Get-RdlDataSourceRefs -RdlPath $rdl.FullName
    Write-Host "  - DS detectados en $($rdl.Name): " ($dsList | ForEach-Object { "$($_.Name) -> $($_.Reference)" } | Out-String)

    foreach ($ds in $dsList) {
      
      if (-not $ds.Reference) {
        Write-Host "  - DataSource '$($ds.Name)' es embebido. (se deja embebido)"
        continue
      }

      $reportItemPath = "$ProjectRsFolder/" + [System.IO.Path]::GetFileNameWithoutExtension($rdl.Name)

      # Si el RDL ya trae path absoluto (/Apps/...): úsalo directo
      if ($ds.Reference.StartsWith('/')) {
        Write-Host "Path absoluto"
        $targetRef = $ds.Reference
      } else {
        # Solo nombre lógico -> intenta proyecto y luego Shared
        $candidateProject = "$ProjectRsFolder/$($ds.Reference)"
        $candidateShared  = "$SharedDsFolder/$($ds.Reference)"
        
        # Búsqueda tolerantemente (case-insensitive) preguntando al server
        # --- Proyecto ---
        $projItems = Get-RsFolderContent -ReportServerUri $ApiUrl -Path $ProjectRsFolder -ErrorAction SilentlyContinue
        $matchProj = $projItems | Where-Object { $_.TypeName -eq 'DataSource' -and $_.Name -ieq $ds.Reference }
        $existsProject   = $false
        $candidateProject = "$ProjectRsFolder/$($ds.Reference)"
        if ($matchProj) {
          # usa el nombre real (respeta mayúsculas/minúsculas tal como está en el server)
          $candidateProject = "$ProjectRsFolder/$($matchProj.Name)"
          $existsProject = $true
        }

        # --- Shared ---
        $sharedItems = Get-RsFolderContent -ReportServerUri $ApiUrl -Path $SharedDsFolder -ErrorAction SilentlyContinue
        $matchShared = $sharedItems | Where-Object { $_.TypeName -eq 'DataSource' -and $_.Name -ieq $ds.Reference }
        $existsShared  = $false
        $candidateShared = "$SharedDsFolder/$($ds.Reference)"
        if ($matchShared) {
          $candidateShared = "$SharedDsFolder/$($matchShared.Name)"
          $existsShared = $true
        }

        # Escoge el targetRef
        if ($existsProject)      { $targetRef = $candidateProject }
        elseif ($existsShared)   { $targetRef = $candidateShared }
        else {
          Write-Warning "  - No encontré DS publicado para '$($ds.Name)' (ref='$($ds.Reference)') en '$ProjectRsFolder' ni en '$SharedDsFolder'."
          continue
        }
      }
      
      # Guardas
      if ([string]::IsNullOrWhiteSpace($ds.Name)) {
        Write-Warning "  - DataSource con nombre vacío en $($rdl.Name); se omite."
        continue
      }
      if ([string]::IsNullOrWhiteSpace($targetRef)) {
        Write-Warning "  - targetRef vacío para '$($ds.Name)'; se omite."
        continue
      }

      # Traza mínima para confirmar parámetros
      Write-Host ("  - Aplicando referencia: Report='{0}'  DSName='{1}'  RsItem='{2}'" -f $reportItemPath, $ds.Name, $targetRef)

      # Llamada 100% calificada al cmdlet correcto del módulo correcto (sin aliases, sin splatting)
      ReportingServicesTools\Set-RsDataSourceReference `
        -ReportServerUri $ApiUrl `
        -Path            $reportItemPath `
        -DataSourceName  $ds.Name `
        -RsItem          $targetRef `
        -ErrorAction     Stop | Out-Null

      Write-Host "  - DS '$($ds.Name)' → $targetRef"
    }


  }
}

# --- ORQUESTADOR ---

$TargetBase = Normalize-RsPath $TargetBase

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

  $mapArgs = @{
  ApiUrl             = $ApiUrl
  LocalReportsFolder = (Join-Path $proj.FullName "Reports")
  ProjectRsFolder    = $projRsFolder
  SharedDsFolder     = "$TargetBase/Shared/Data Sources"
  }

  Write-Host "mapArgs keys: $(($mapArgs.Keys) -join ', ')"
  Publish-Reports-And-MapDS @mapArgs
}
