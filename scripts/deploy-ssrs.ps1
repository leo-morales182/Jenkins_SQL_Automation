param(
  [Parameter(Mandatory=$true)] [string]$PortalUrl,      # ej: http://localhost/Reports (solo informativo)
  [Parameter(Mandatory=$true)] [string]$ApiUrl,         # ej: http://localhost/ReportServer
  [Parameter()] [string]$TargetBase = "/",              # ahora raíz del servidor SSRS
  [string]$RepoRoot,
  [string]$User,
  [string]$Pass
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"

# --- Credenciales ---
$cred = $null
if ($User -and $Pass) {
  $sec  = ConvertTo-SecureString $Pass -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential($User, $sec)
}
$script:cred = $cred

# Resolver RepoRoot a la carpeta 'reports'
if (-not $RepoRoot -or -not (Test-Path $RepoRoot)) {
  $candidate1 = Join-Path $PSScriptRoot "..\reports"
  $candidate2 = Join-Path $env:WORKSPACE "ssrs\reports"
  if     (Test-Path $candidate1) { $RepoRoot = $candidate1 }
  elseif (Test-Path $candidate2) { $RepoRoot = $candidate2 }
  else  { throw "Not 'reports' folder in: `n - $candidate1 `n - $candidate2" }
}
Write-Host "RepoRoot: $RepoRoot"

# === NUEVO: carpeta DS compartidos en raíz ===
$SharedDsFolder = "/Data Sources"

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
      Write-Host "Folder created: $current/$seg"
    }

    if ($current -eq '/') { $current = "/$seg" } else { $current = "$current/$seg" }
  }
}

# --- Publicadores (tus funciones originales, sin cambios de firma) ---
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
    Write-Host "Resource: $($f.Name) published in $RsFolder"
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
    Write-Host "DataSource: $($ds.Name) published in $RsFolder"
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
    Write-Host "DataSet: $($s.Name) published in $RsFolder"
  }
}

# --- RDL: extracción y remapeo de DS (tu función original) ---
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
        $name = $null
        if ($n.Attributes -and $n.Attributes["Name"]) { $name = $n.Attributes["Name"].Value }
        else {
          $attrNode = $n.SelectSingleNode("@Name")
          if ($attrNode) { $name = $attrNode.Value }
        }
        $ref = $null
        $refNode = $n.SelectSingleNode("d:DataSourceReference", $nsm)
        if ($refNode) { $ref = $refNode.InnerText }
        $out += [pscustomobject]@{ Name = $name; Reference = $ref }
      }
      return $out
    }
  }

  throw "DataSources can't be read from the RDL (namespace no reconocido o estructura inesperada)."
}

function Publish-Reports-And-MapDS {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][string]$LocalReportsFolder,
    [Parameter(Mandatory=$true)][string]$ProjectRsFolder,      # ahora: /<Proyecto>
    [Parameter(Mandatory=$true)][string]$SharedDsFolder        # ahora: /Data Sources
  )
  if (-not (Test-Path $LocalReportsFolder)) { return }
  $rdls = Get-ChildItem -Path $LocalReportsFolder -File -Include *.rdl -Recurse

  $SetDsRef = Get-Command 'ReportingServicesTools\Set-RsDataSourceReference' -ErrorAction Stop
  Remove-Item alias:Set-RsDataSourceReference -ErrorAction SilentlyContinue
  Remove-Item alias:Set-RsDataSource          -ErrorAction SilentlyContinue

  foreach ($rdl in $rdls) {
    # Publicar el RDL en /<Proyecto>/Reports
    $pubArgs = @{
      ReportServerUri = $ApiUrl
      Path           = $rdl.FullName
      RsFolder       = (Normalize-RsPath "$ProjectRsFolder")
      Overwrite      = $true
    }
    if ($script:cred) { $pubArgs.Credential = $script:cred }
    Write-RsCatalogItem @pubArgs | Out-Null
    Write-Host "RDL: $($rdl.Name) published in $($pubArgs.RsFolder)"

    # Re-mapear DS a /Data Sources/<Name>
    $dsList = Get-RdlDataSourceRefs -RdlPath $rdl.FullName
    $reportItemPath = "$($pubArgs.RsFolder)/" + [System.IO.Path]::GetFileNameWithoutExtension($rdl.Name)

    foreach ($ds in $dsList) {
      if (-not $ds.Reference) {
        Write-Host "  - DataSource '$($ds.Name)' es embebido."
        continue
      }

      # Si reference trae path absoluto, lo respetamos; si no, resolvemos a /Data Sources/<ref>
      if ($ds.Reference.StartsWith('/')) {
        $targetRef = $ds.Reference
      } else {
        $targetRef = "$SharedDsFolder/$($ds.Reference)"
      }

      Write-Host "Targetref value: $($targetRef)"

      # Confirmar y aplicar
      if ([string]::IsNullOrWhiteSpace($ds.Name) -or [string]::IsNullOrWhiteSpace($targetRef)) {
        Write-Warning "  - Parámetros inválidos para '$($rdl.Name)'; se omite."
        continue
      }
      if (-not $targetRef.StartsWith('/')) { $targetRef = '/' + $targetRef.TrimStart('/') }

      $setDsRefArgs = @{
        ReportServerUri = $ApiUrl
        Path            = $reportItemPath
        DataSourceName  = $ds.Name
        DataSourcePath  = $targetRef
      }
      if ($script:cred) { $setDsRefArgs.Credential = $script:cred }

      & $SetDsRef @setDsRefArgs | Out-Null
      Write-Host "  - DS '$($ds.Name)' → $targetRef"
    }
  }
}

# === NUEVO: recopilar y publicar RDS únicos a /Data Sources ===
function Publish-SharedRdsFromProjects {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][System.IO.DirectoryInfo[]]$ProjectDirs,
    [Parameter(Mandatory=$true)][string]$SharedDsFolder
  )

  Ensure-RsPath -ApiUrl $ApiUrl -Path $SharedDsFolder

  # Tomar .rds en la RAÍZ de cada proyecto (no en Reports/)
  $allRds = foreach ($proj in $ProjectDirs) {
    Get-ChildItem -Path $proj.FullName -File -Filter *.rds
  }

  # Dedupe por nombre (sin extensión)
  $byName = @{}
  $dups = @()
  foreach ($rds in $allRds) {
    $name = [IO.Path]::GetFileNameWithoutExtension($rds.Name)
    if (-not $byName.ContainsKey($name)) { $byName[$name] = $rds.FullName }
    else { $dups += [pscustomobject]@{ Name=$name; First=$byName[$name]; Duplicate=$rds.FullName } }
  }
  if ($dups.Count -gt 0) {
    Write-Warning "RDS duplicados por nombre; se usará el primero encontrado:"
    $dups | ForEach-Object { Write-Warning (" - {0}: {1} (dup: {2})" -f $_.Name,$_.First,$_.Duplicate) }
  }

  # Publicar cada DS una sola vez en /Data Sources
  foreach ($name in $byName.Keys) {
    $src = $byName[$name]
    $args = @{
      ReportServerUri = $ApiUrl
      Path           = $src
      RsFolder       = (Normalize-RsPath $SharedDsFolder)
      Overwrite      = $true
    }
    if ($script:cred) { $args.Credential = $script:cred }
    Write-RsCatalogItem @args | Out-Null
    Write-Host "Shared DS: $name (from $src) -> $SharedDsFolder"
  }
}

# === NUEVO: publicar recursos del proyecto desde su RAÍZ (excluye .rds y la carpeta Reports) ===
function Publish-ProjectResourcesFromRoot {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][System.IO.DirectoryInfo]$ProjectDir
  )
  $target = "/$($ProjectDir.Name)/Resources"
  Ensure-RsPath -ApiUrl $ApiUrl -Path "/$($ProjectDir.Name)"
  Ensure-RsPath -ApiUrl $ApiUrl -Path $target

  # Solo extensiones permitidas por Write-RsCatalogItem en tu versión: jpg/png
  $files = Get-ChildItem -Path $ProjectDir.FullName -File |
           Where-Object { $_.Extension -in '.jpg', '.png' }

  foreach ($f in $files) {
    $args = @{
      ReportServerUri = $ApiUrl
      Path           = $f.FullName
      RsFolder       = (Normalize-RsPath $target)
      Overwrite      = $true
    }
    if ($script:cred) { $args.Credential = $script:cred }
    Write-RsCatalogItem @args | Out-Null
    Write-Host "Resource: $($f.Name) -> $target"
  }
}

function Set-SharedDataSourceCredentials {
  param(
    [Parameter(Mandatory)][string] $ApiUrl,
    [Parameter(Mandatory)][string] $SharedDsFolder, # "/Data Sources"
    [Parameter(Mandatory)][string] $MappingFile     # p.ej. repo\env\datasources.map.PROD.json
  )

  if (-not (Test-Path $MappingFile)) { throw "No existe $MappingFile" }
  $map = Get-Content $MappingFile -Raw | ConvertFrom-Json

  $hasSetRsDataSource = Get-Command -Name Set-RsDataSource -ErrorAction SilentlyContinue

  foreach ($ds in $map.items) {
    $dsPath = "$SharedDsFolder/$($ds.name)"
    $user=$null;$pass=$null
    if ($ds.credentialMode -eq "Store") {
      $user = [Environment]::GetEnvironmentVariable($ds.usernameEnv)
      $pass = [Environment]::GetEnvironmentVariable($ds.passwordEnv)
      if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($pass)) {
        throw "Faltan variables $($ds.usernameEnv)/$($ds.passwordEnv) para $($ds.name)"
      }
    }

    try {
      if ($hasSetRsDataSource) {
        $p = @{
          ReportServerUri     = $ApiUrl
          Path                = $dsPath
          ConnectionString    = $ds.connectionString
          Extension           = $ds.type               # SQL|OLEDB|Oracle...
          CredentialRetrieval = $ds.credentialMode     # Store|Integrated|Prompt|None
        }
        if ($ds.credentialMode -eq "Store") {
          $p.UserName = $user; $p.Password = $pass
          if ($null -ne $ds.useWindowsCredentials) { $p.WindowsCredentials = [bool]$ds.useWindowsCredentials }
        }
        Set-RsDataSource @p -ErrorAction Stop
      } else {
        # Fallback REST por si no está ese cmdlet
        $lookup = Invoke-RsRestMethod -ReportServerUri $ApiUrl -Method Post -Url "api/v2.0/PathLookup" -Body (@{path=$dsPath}|ConvertTo-Json) -ContentType "application/json"
        if (-not $lookup -or -not $lookup.Id) { throw "No existe $dsPath" }
        $payload = @{
          Id                  = $lookup.Id
          Name                = $ds.name
          Path                = $dsPath
          Type                = "DataSource"
          DataSourceType      = $ds.type
          ConnectionString    = $ds.connectionString
          CredentialRetrieval = $ds.credentialMode
        }
        if ($ds.credentialMode -eq "Store") {
          $payload.Username = $user; $payload.Password = $pass
          if ($null -ne $ds.useWindowsCredentials) { $payload.WindowsCredentials = [bool]$ds.useWindowsCredentials }
        }
        Invoke-RsRestMethod -ReportServerUri $ApiUrl -Method Patch -Url "api/v2.0/datasources($($lookup.Id))" -Body ($payload|ConvertTo-Json -Depth 6) -ContentType "application/json" | Out-Null
      }

      # Probar conexión
      Test-RsDataSourceConnection -ReportServerUri $ApiUrl -Path $dsPath -ErrorAction Stop | Out-Null
      Write-Host "OK DS: $dsPath"
    } catch {
      Write-Warning "Fallo DS $dsPath: $_"
    }
  }
}


# --- ORQUESTADOR ---

$TargetBase = Normalize-RsPath $TargetBase

# 0) Estructura base en raíz
Ensure-RsPath -ApiUrl $ApiUrl -Path $TargetBase          # "/"
Ensure-RsPath -ApiUrl $ApiUrl -Path "$TargetBase/Data Sources"  # "/Data Sources"

# 1) Proyectos: subcarpetas de RepoRoot (ya no existe 'Shared' en repo)
$projects = Get-ChildItem -Path $RepoRoot -Directory | Where-Object { $_.Name -ne 'Shared' }

# 2) Publicar TODOS los RDS únicos de los proyectos en /Data Sources (raíz)
Publish-SharedRdsFromProjects -ApiUrl $ApiUrl -ProjectDirs $projects -SharedDsFolder "$TargetBase/Data Sources"

#$envMap = Join-Path $RepoRoot "env\datasources.map.$($env:ENV).json"
Write-Host "Env value: $($env:ENV)"
$envMap = Join-Path $RepoRoot "jenkins_env\datasources.map.dev.json"
Set-SharedDataSourceCredentials -ApiUrl $ApiUrl -SharedDsFolder "$TargetBase/Data Sources" -MappingFile $envMap

# 3) (Opcional) Si aún manejas Shared DataSets/Resources globales en el repo, puedes comentar/ajustar estas líneas:
# Publish-DataSets   -ApiUrl $ApiUrl -LocalFolder (Join-Path $RepoRoot "Shared\DataSets")   -RsFolder "$TargetBase/Data Sets"
# Publish-Resources  -ApiUrl $ApiUrl -LocalFolder (Join-Path $RepoRoot "Shared\Resources")  -RsFolder "$TargetBase/Resources"

# 4) Publicar cada proyecto en raíz
foreach ($proj in $projects) {
  $projName     = $proj.Name
  $projRsFolder = "$TargetBase/$projName"       # "/<Proyecto>"
  Ensure-RsPath -ApiUrl $ApiUrl -Path $projRsFolder

  # Recursos desde la RAÍZ del proyecto (excluye .rds y Reports/)
  Publish-ProjectResourcesFromRoot -ApiUrl $ApiUrl -ProjectDir $proj

  # Reportes del proyecto (están en <Proyecto>/Reports)
  $mapArgs = @{
    ApiUrl             = $ApiUrl
    LocalReportsFolder = $proj.FullName
    ProjectRsFolder    = $projRsFolder
    SharedDsFolder     = "/Data Sources"   # "/Data Sources"
  }
  Publish-Reports-And-MapDS @mapArgs
}

Write-Host "Deploy completed (root mode: projects at '/<Proyecto>', shared DS at '/Data Sources')."