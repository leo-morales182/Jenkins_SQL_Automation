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

# --- Wrapper REST propio (evita Invoke-RsRestMethod) ---
function Invoke-SSRSRest {
  param(
    [Parameter(Mandatory)][string]$ApiUrl,      # http://server/ReportServer
    [Parameter(Mandatory)][string]$Method,      # GET|POST|PATCH
    [Parameter(Mandatory)][string]$RelativeUrl, # ej: api/v2.0/PathLookup
    [Parameter()][object]$Body
  )
  $uri = ($ApiUrl.TrimEnd('/') + '/' + $RelativeUrl.TrimStart('/'))
  $common = @{
    Uri                  = $uri
    Method               = $Method
    ContentType          = 'application/json'
    UseDefaultCredentials= $true
    ErrorAction          = 'Stop'
  }
  if ($script:cred) {
    $common.Remove('UseDefaultCredentials')
    $common.Credential = $script:cred
  }

  if ($PSBoundParameters.ContainsKey('Body') -and $Body -ne $null) {
    $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 8 }
    $common.Body = $json
  }

  return Invoke-RestMethod @common
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
  $dss = @(Get-ChildItem -Path $LocalFolder -File -Recurse -Filter *.rds)
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
  $sets = @(Get-ChildItem -Path $LocalFolder -File -Recurse -Filter *.rsd)
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

  throw "DataSources can't be read from the RDL (namespace no reconocido o estructura inesperada)."
}

function Publish-Reports-And-MapDS {
  param(
    [Parameter(Mandatory=$true)][string]$ApiUrl,
    [Parameter(Mandatory=$true)][string]$LocalReportsFolder,  # carpeta del proyecto que contiene los .rdl (puede ser raíz del proyecto)
    [Parameter(Mandatory=$true)][string]$ProjectRsFolder,     # /<Proyecto>
    [Parameter(Mandatory=$true)][string]$SharedDsFolder       # /Data Sources
  )
  if (-not (Test-Path $LocalReportsFolder)) {
    Write-Warning "Carpeta de RDL no existe: $LocalReportsFolder"
    return
  }

  $destReports = Normalize-RsPath $ProjectRsFolder
  Ensure-RsPath -ApiUrl $ApiUrl -Path $destReports

  # Forzar array
  $rdls = @(Get-ChildItem -Path $LocalReportsFolder -File -Recurse -Filter *.rdl)
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
    [Parameter(Mandatory)][string] $MappingFile     # p.ej. jenkins_env\datasources.map.dev.json
  )

  # --- Validaciones iniciales ---
  if (-not (Test-Path $MappingFile)) { throw "No existe $MappingFile" }
  $SharedDsFolder = (Normalize-RsPath $SharedDsFolder)
  if ($SharedDsFolder -eq "/") { throw "SharedDsFolder no puede ser la raíz '/'" }

  # Asegura la carpeta contenedora
  Ensure-RsPath -ApiUrl $ApiUrl -Path $SharedDsFolder

  # Cargar mapa
  $map = Get-Content $MappingFile -Raw | ConvertFrom-Json

  # Descubrir parámetros soportados por tu versión del módulo
  $setCmd = Get-Command -Name Set-RsDataSource -ErrorAction SilentlyContinue
  $newCmd = Get-Command -Name New-RsDataSource -ErrorAction SilentlyContinue
  if (-not $newCmd) { throw "El módulo ReportingServicesTools no expone New-RsDataSource; actualiza el módulo." }

  $supportsSet         = $false
  $paramConnName       = $null
  $setParamsLower      = @()
  if ($setCmd) {
    $setParamsLower = $setCmd.Parameters.Keys | ForEach-Object { $_.ToLowerInvariant() }
    if ($setParamsLower -contains 'connectionstring') { $paramConnName = 'ConnectionString'; $supportsSet = $true }
    elseif ($setParamsLower -contains 'connectstring') { $paramConnName = 'ConnectString';  $supportsSet = $true }
    else { Write-Warning "Set-RsDataSource está disponible pero no publica parámetro de ConnectionString; se intentará solo con credenciales/flags." }
  } else {
    Write-Warning "Set-RsDataSource no está disponible; solo se intentará crear/forzar con New-RsDataSource cuando falte el DS."
  }

  foreach ($ds in $map.items) {
    $name  = [string]$ds.name
    if ([string]::IsNullOrWhiteSpace($name)) { Write-Warning "Entrada de mapa sin 'name'; se omite."; continue }

    $dsPath = (Normalize-RsPath ("$SharedDsFolder/$name"))

    # Resolver credenciales si aplica
    $user=$null; $pass=$null
    if ($ds.credentialMode -eq "Store") {
      if (-not $ds.usernameEnv -or -not $ds.passwordEnv) {
        throw "credentialMode=Store pero falta usernameEnv/passwordEnv para '$name'"
      }
      $user = [Environment]::GetEnvironmentVariable([string]$ds.usernameEnv)
      $pass = [Environment]::GetEnvironmentVariable([string]$ds.passwordEnv)
      if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($pass)) {
        throw "Faltan variables $($ds.usernameEnv)/$($ds.passwordEnv) para '$name'"
      }
    }

    try {
      # 1) ¿Existe el DS?
      $existing = $null
      try {
        $existing = Get-RsItem -ReportServerUri $ApiUrl -Path $dsPath -ErrorAction Stop
      } catch {
        # Get-RsItem no encontrado en algunas versiones; probamos Get-RsDataSource
        try {
          $existing = Get-RsDataSource -ReportServerUri $ApiUrl -Path $dsPath -ErrorAction Stop
        } catch {
          $existing = $null
        }
      }

      # 2) Si NO existe, crear explícitamente con -Parent (evita el bug del backslash)
      if (-not $existing) {
        $newArgs = @{
          ReportServerUri     = $ApiUrl
          Name                = $name
          Parent              = $SharedDsFolder     # <-- PARENT explícito con slash
          Extension           = [string]$ds.type    # SQL|OLEDB|Oracle...
          CredentialRetrieval = [string]$ds.credentialMode # Integrated|Store|Prompt|None
          Overwrite           = $true
        }
        if ($ds.connectionString) { $newArgs.ConnectionString = [string]$ds.connectionString }
        if ($ds.credentialMode -eq "Store") {
          $newArgs.UserName = $user
          $newArgs.Password = $pass
          if ($null -ne $ds.useWindowsCredentials) { $newArgs.WindowsCredentials = [bool]$ds.useWindowsCredentials }
        }
        if ($script:cred) { $newArgs.Credential = $script:cred }

        New-RsDataSource @newArgs -ErrorAction Stop | Out-Null
        Write-Host "Creado DS: $dsPath"
      }
      else {
        Write-Host "Existe DS: $dsPath"
      }

      # 3) Actualizar propiedades con Set-RsDataSource (si se soporta)
      if ($supportsSet) {
        $setArgs = @{
          ReportServerUri     = $ApiUrl
          Path                = $dsPath
          Extension           = [string]$ds.type
          CredentialRetrieval = [string]$ds.credentialMode
        }
        if ($paramConnName -and $ds.connectionString) { $setArgs[$paramConnName] = [string]$ds.connectionString }
        if ($ds.credentialMode -eq "Store") {
          $setArgs.UserName = $user; $setArgs.Password = $pass
          if ($null -ne $ds.useWindowsCredentials) { $setArgs.WindowsCredentials = [bool]$ds.useWindowsCredentials }
        }
        if ($script:cred) { $setArgs.Credential = $script:cred }

        Set-RsDataSource @setArgs -ErrorAction Stop
        Write-Host "Actualizado DS: $dsPath"
      } else {
        Write-Warning "No se actualizó $dsPath con Set-RsDataSource por falta de cmdlet/parámetro; quedó con los valores al crearse (si era nuevo)."
      }

      # 4) Probar conexión
      Test-RsDataSourceConnection -ReportServerUri $ApiUrl -Path $dsPath -ErrorAction Stop | Out-Null
      Write-Host "OK DS: $dsPath"
    }
    catch {
      Write-Warning ("Fallo DS {0}: {1}" -f $dsPath, $_.Exception.Message)
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

  # Reportes del proyecto (tu estructura actual: los .rdl están en la raíz del proyecto)
  $mapArgs = @{
    ApiUrl             = $ApiUrl
    LocalReportsFolder = $proj.FullName
    ProjectRsFolder    = $projRsFolder
    SharedDsFolder     = "/Data Sources"
  }
  Publish-Reports-And-MapDS @mapArgs
}

Write-Host "Deploy completed (root mode: projects at '/<Proyecto>', shared DS at '/Data Sources')."
