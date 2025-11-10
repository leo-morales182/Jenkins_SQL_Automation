param(
  [Parameter(Mandatory=$true)] [string]$PortalUrl,      # ej: http://localhost/Reports (solo informativo)
  [Parameter(Mandatory=$true)] [string]$ApiUrl,         # ej: http://localhost/ReportServer
  [Parameter()] [string]$TargetBase = "/",              # ahora raíz del servidor SSRS
  [string]$RepoRoot,
  [string]$User,
  [string]$Pass,
  [string]$EnvMapPath                                    # p.ej. C:\...\jenkins_env\datasources.map.dev.json
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

# Resolver RepoRoot a la carpeta 'reports' si no viene
if (-not $RepoRoot -or -not (Test-Path $RepoRoot)) {
  $candidate1 = Join-Path $PSScriptRoot "..\reports"
  $candidate2 = Join-Path $env:WORKSPACE "ssrs\reports"
  if     (Test-Path $candidate1) { $RepoRoot = $candidate1 }
  elseif (Test-Path $candidate2) { $RepoRoot = $candidate2 }
  else  { throw "Not 'reports' folder in: `n - $candidate1 `n - $candidate2" }
}
Write-Host "RepoRoot: $RepoRoot"

# === Carpeta DS compartidos en raíz ===
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

# --- Publicadores ---
function Publish-Resources {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][string]$LocalFolder,
    [Parameter(Mandatory=$true)][string]$RsFolder
  )
  if (-not (Test-Path $LocalFolder)) { return }
  $files = Get-ChildItem -Path $LocalFolder -File -Recurse |
           Where-Object { $_.Extension -in '.jpg', '.png' }
  foreach ($f in $files) {
    $args = @{
      ReportServerUri = $ApiUrl
      Path            = $f.FullName
      RsFolder        = (Normalize-RsPath $RsFolder)
      Overwrite       = $true
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
  $dss = Get-ChildItem -Path $LocalFolder -File -Recurse -Filter *.rds
  foreach ($ds in $dss) {
    $args = @{
      ReportServerUri = $ApiUrl
      Path            = $ds.FullName
      RsFolder        = (Normalize-RsPath $RsFolder)
      Overwrite       = $true
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
  $sets = Get-ChildItem -Path $LocalFolder -File -Recurse -Filter *.rsd
  foreach ($s in $sets) {
    $args = @{
      ReportServerUri = $ApiUrl
      Path            = $s.FullName
      RsFolder        = (Normalize-RsPath $RsFolder)
      Overwrite       = $true
    }
    if ($script:cred) { $args.Credential = $script:cred }
    Write-RsCatalogItem @args | Out-Null
    Write-Host "DataSet: $($s.Name) published in $RsFolder"
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

  throw "DataSources can't be readen from the RDL (namespace no reconocido o estructura inesperada)."
}

function Publish-Reports-And-MapDS {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][string]$LocalReportsFolder,
    [Parameter(Mandatory=$true)][string]$ProjectRsFolder,      # /<Proyecto>
    [Parameter(Mandatory=$true)][string]$SharedDsFolder        # /Data Sources
  )
  if (-not (Test-Path $LocalReportsFolder)) {
    Write-Warning "Carpeta de RDL no existe: $LocalReportsFolder"
    return
  }

  $destReports = Normalize-RsPath "$ProjectRsFolder/Reports"
  Ensure-RsPath -ApiUrl $ApiUrl -Path $destReports

  # PS 5.1: usar -Filter
  $rdls = Get-ChildItem -Path $LocalReportsFolder -File -Recurse -Filter *.rdl
  Write-Host "RDL encontrados en '$LocalReportsFolder': $($rdls.Count)"
  if ($rdls.Count -eq 0) { return }

  $SetDsRef = Get-Command 'ReportingServicesTools\Set-RsDataSourceReference' -ErrorAction Stop
  Remove-Item alias:Set-RsDataSourceReference -ErrorAction SilentlyContinue
  Remove-Item alias:Set-RsDataSource          -ErrorAction SilentlyContinue

  foreach ($rdl in $rdls) {
    $pubArgs = @{
      ReportServerUri = $ApiUrl
      Path            = $rdl.FullName
      RsFolder        = $destReports
      Overwrite       = $true
    }
    if ($script:cred) { $pubArgs.Credential = $script:cred }
    Write-RsCatalogItem @pubArgs | Out-Null
    Write-Host "RDL publicado: $($rdl.Name) -> $destReports"

    # Re-mapear DS
    $dsList = Get-RdlDataSourceRefs -RdlPath $rdl.FullName
    $reportItemPath = "$destReports/" + [System.IO.Path]::GetFileNameWithoutExtension($rdl.Name)

    foreach ($ds in $dsList) {
      if (-not $ds.Reference) { Write-Host "  - DS '$($ds.Name)' embebido."; continue }

      $targetRef = if ($ds.Reference.StartsWith('/')) { $ds.Reference } else { Normalize-RsPath "$SharedDsFolder/$($ds.Reference)" }

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

# === Publicar RDS únicos a /Data Sources ===
function Publish-SharedRdsFromProjects {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][System.IO.DirectoryInfo[]]$ProjectDirs,
    [Parameter(Mandatory=$true)][string]$SharedDsFolder
  )

  Ensure-RsPath -ApiUrl $ApiUrl -Path $SharedDsFolder

  # .rds en la RAÍZ del proyecto (no dentro de Reports/)
  $allRds = foreach ($proj in $ProjectDirs) {
    Get-ChildItem -Path $proj.FullName -File -Filter *.rds
  }

  # Dedupe por nombre
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

  foreach ($name in $byName.Keys) {
    $src = $byName[$name]
    $args = @{
      ReportServerUri = $ApiUrl
      Path            = $src
      RsFolder        = (Normalize-RsPath $SharedDsFolder)
      Overwrite       = $true
    }
    if ($script:cred) { $args.Credential = $script:cred }
    Write-RsCatalogItem @args | Out-Null
    Write-Host "Shared DS: $name (from $src) -> $(Normalize-RsPath $SharedDsFolder)"
  }
}

# === Recursos del proyecto desde su RAÍZ (excluye .rds y Reports/) ===
function Publish-ProjectResourcesFromRoot {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][System.IO.DirectoryInfo]$ProjectDir
  )
  $target = "/$($ProjectDir.Name)/Resources"
  Ensure-RsPath -ApiUrl $ApiUrl -Path "/$($ProjectDir.Name)"
  Ensure-RsPath -ApiUrl $ApiUrl -Path $target

  $files = Get-ChildItem -Path $ProjectDir.FullName -File |
           Where-Object { $_.Extension -in '.jpg', '.png' }

  foreach ($f in $files) {
    $args = @{
      ReportServerUri = $ApiUrl
      Path            = $f.FullName
      RsFolder        = (Normalize-RsPath $target)
      Overwrite       = $true
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
    [Parameter(Mandatory)][string] $MappingFile     # p.ej. automation\jenkins_env\datasources.map.dev.json
  )

  if (-not (Test-Path $MappingFile)) { throw "No existe $MappingFile" }
  $map = Get-Content $MappingFile -Raw | ConvertFrom-Json

  # Detectar cmdlet y parámetros soportados
  $setCmd = Get-Command -Name Set-RsDataSource -ErrorAction SilentlyContinue
  $supportsModule = $false
  $paramConnName  = $null
  if ($setCmd) {
    $pnames = ($setCmd.Parameters.Keys | ForEach-Object { $_.ToLowerInvariant() })
    if ($pnames -contains 'connectionstring') { $paramConnName = 'ConnectionString'; $supportsModule = $true }
    elseif ($pnames -contains 'connectstring') { $paramConnName = 'ConnectString'; $supportsModule = $true }
  }

  foreach ($ds in $map.items) {
    $dsPath = Normalize-RsPath "$SharedDsFolder/$($ds.name)"

    # Si es Store, levantar credenciales desde variables de entorno (si vienen definidas en el JSON)
    $user=$null;$pass=$null
    if ($ds.credentialMode -eq "Store") {
      $userEnv = $ds.usernameEnv
      $passEnv = $ds.passwordEnv
      if ($userEnv -and $passEnv) {
        $user = [Environment]::GetEnvironmentVariable($userEnv)
        $pass = [Environment]::GetEnvironmentVariable($passEnv)
        if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($pass)) {
          throw "Faltan variables $userEnv/$passEnv para $($ds.name)"
        }
      } else {
        throw "credentialMode=Store pero falta usernameEnv/passwordEnv para $($ds.name)"
      }
    }

    try {
      if ($supportsModule) {
        # Usar cmdlet del módulo con el nombre de parámetro correcto
        $p = @{
          ReportServerUri     = $ApiUrl
          Path                = $dsPath
          Extension           = $ds.type               # SQL|OLEDB|Oracle...
          CredentialRetrieval = $ds.credentialMode     # Store|Integrated|Prompt|None
        }
        if ($paramConnName) { $p[$paramConnName] = $ds.connectionString }
        if ($ds.credentialMode -eq "Store") {
          $p.UserName = $user; $p.Password = $pass
          if ($null -ne $ds.useWindowsCredentials) { $p.WindowsCredentials = [bool]$ds.useWindowsCredentials }
        }
        Set-RsDataSource @p -ErrorAction Stop
      } else {
        # Fallback: REST v2.0
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

      # Probar conexión (si el server lo permite)
      Test-RsDataSourceConnection -ReportServerUri $ApiUrl -Path $dsPath -ErrorAction Stop | Out-Null
      Write-Host "OK DS: $dsPath"
    } catch {
      Write-Warning ("Fallo DS {0}: {1}" -f $dsPath, $_)
    }
  }
}

# --- ORQUESTADOR ---

$TargetBase = Normalize-RsPath $TargetBase
$SharedDsFolder = Normalize-RsPath $SharedDsFolder

# 0) Estructura base en raíz
Ensure-RsPath -ApiUrl $ApiUrl -Path $TargetBase                # "/"
Ensure-RsPath -ApiUrl $ApiUrl -Path "$TargetBase/Data Sources" # "/Data Sources"

# 1) Proyectos: subcarpetas de RepoRoot
$projects = Get-ChildItem -Path $RepoRoot -Directory | Where-Object { $_.Name -ne 'Shared' }

# 2) Publicar TODOS los RDS únicos en /Data Sources
Publish-SharedRdsFromProjects -ApiUrl $ApiUrl -ProjectDirs $projects -SharedDsFolder "$TargetBase/Data Sources"

# 2.1) Aplicar credenciales desde -EnvMapPath si existe (Integrated/None/Prompt/Store)
if ($EnvMapPath) {
  if (Test-Path $EnvMapPath) {
    Write-Host "Usando mapa de credenciales: $EnvMapPath"
    Set-SharedDataSourceCredentials -ApiUrl $ApiUrl -SharedDsFolder "$TargetBase/Data Sources" -MappingFile $EnvMapPath
  } else {
    Write-Warning "No se encontró el mapa de credenciales: $EnvMapPath. Continúo sin aplicar credenciales."
  }
} else {
  Write-Host "No se pasó -EnvMapPath; continúo sin aplicar credenciales."
}

# 3) Publicar cada proyecto en raíz
foreach ($proj in $projects) {
  $projName     = $proj.Name
  $projRsFolder = "$TargetBase/$projName"       # "/<Proyecto>"
  Ensure-RsPath -ApiUrl $ApiUrl -Path $projRsFolder

  # Recursos desde la RAÍZ del proyecto (excluye .rds y Reports/)
  Publish-ProjectResourcesFromRoot -ApiUrl $ApiUrl -ProjectDir $proj

  # Reportes del proyecto (en <Proyecto>/Reports)
  $mapArgs = @{
    ApiUrl             = $ApiUrl
    LocalReportsFolder = (Join-Path $proj.FullName "Reports")
    ProjectRsFolder    = $projRsFolder
    SharedDsFolder     = "/Data Sources"
  }
  Publish-Reports-And-MapDS @mapArgs
}

Write-Host "Deploy completed (root mode: projects at '/<Proyecto>', shared DS at '/Data Sources')."
