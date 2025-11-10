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
function Escape-Xml {
  param([string]$s)
  if ($null -eq $s) { return "" }
  return [System.Security.SecurityElement]::Escape([string]$s)
}

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

function New-RdsXmlFromMapItem {
  param([Parameter(Mandatory)][pscustomobject] $MapItem)

  # Normaliza y calcula valores sin usar operadores '??' ni '?:' en la interpolación
  $ext   = [string]$MapItem.type
  $conn  = [string]$MapItem.connectionString
  $mode  = [string]$MapItem.credentialMode  # Store | Integrated | Prompt | None

  # Defaults seguros
  $winCreds = $false
  if ($MapItem.PSObject.Properties.Name -contains 'useWindowsCredentials') {
    $winCreds = [bool]$MapItem.useWindowsCredentials
  }

  $promptText = 'Enter credentials'
  if ($mode -ieq 'Prompt' -and $MapItem.PSObject.Properties.Name -contains 'promptText' -and
      -not [string]::IsNullOrWhiteSpace($MapItem.promptText)) {
    $promptText = [string]$MapItem.promptText
  }

  $user = ''
  $pass = ''
  if ($MapItem.PSObject.Properties.Name -contains 'username') { $user = [string]$MapItem.username }
  if ($MapItem.PSObject.Properties.Name -contains 'password') { $pass = [string]$MapItem.password }

  # SSRS espera <CredentialRetrieval> con uno de: Store | Integrated | Prompt | None
  $credRetrieval = switch -Regex ($mode) {
    '^Store$'      { 'Store';      break }
    '^Integrated$' { 'Integrated'; break }
    '^Prompt$'     { 'Prompt';     break }
    default        { 'None' }
  }

@"
<?xml version="1.0" encoding="utf-8"?>
<DataSourceDefinition xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                      xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <Extension>$(Escape-Xml $ext)</Extension>
  <ConnectString>$(Escape-Xml $conn)</ConnectString>
  <CredentialRetrieval>$credRetrieval</CredentialRetrieval>
  <Prompt>$(Escape-Xml $promptText)</Prompt>
  <WindowsCredentials>$([string]$winCreds).ToLower()</WindowsCredentials>
  <ImpersonateUser>false</ImpersonateUser>
  <Enabled>true</Enabled>
  <UserName>$(Escape-Xml $user)</UserName>
  <Password>$(Escape-Xml $pass)</Password>
</DataSourceDefinition>
"@
}

function Publish-RdsFromMap {
  param(
    [Parameter(Mandatory)][string] $ApiUrl,
    [Parameter(Mandatory)][string] $SharedDsFolder,   # "/Data Sources"
    [Parameter(Mandatory)][string] $MappingFile       # json
  )

  if (-not (Test-Path $MappingFile)) { throw "No existe $MappingFile" }
  $map = Get-Content $MappingFile -Raw | ConvertFrom-Json

  # Garantiza carpeta destino
  $folderNorm = Normalize-RsPath $SharedDsFolder
  Ensure-RsPath -ApiUrl $ApiUrl -Path $folderNorm

  foreach ($item in $map.items) {
    # Resuelve credenciales según mode y env vars (si aplica)
    switch ($item.credentialMode) {
      'Store' {
        if (-not $item.usernameEnv -or -not $item.passwordEnv) {
          throw "credentialMode=Store pero falta usernameEnv/passwordEnv para $($item.name)"
        }
        $u = [Environment]::GetEnvironmentVariable([string]$item.usernameEnv)
        $p = [Environment]::GetEnvironmentVariable([string]$item.passwordEnv)
        if ([string]::IsNullOrWhiteSpace($u) -or [string]::IsNullOrWhiteSpace($p)) {
          throw "Faltan variables $($item.usernameEnv)/$($item.passwordEnv) para $($item.name)"
        }
        # Anexa campos concretos que la función New-RdsXmlFromMapItem consume
        $item | Add-Member -NotePropertyName username -NotePropertyValue $u -Force
        $item | Add-Member -NotePropertyName password -NotePropertyValue $p -Force
      }
      'Prompt' {
        if (-not $item.PSObject.Properties.Name -contains 'promptText' -or
            [string]::IsNullOrWhiteSpace($item.promptText)) {
          $item | Add-Member -NotePropertyName promptText -NotePropertyValue 'Enter credentials' -Force
        }
        $item | Add-Member -NotePropertyName username -NotePropertyValue '' -Force
        $item | Add-Member -NotePropertyName password -NotePropertyValue '' -Force
      }
      'Integrated' {
        $item | Add-Member -NotePropertyName username -NotePropertyValue '' -Force
        $item | Add-Member -NotePropertyName password -NotePropertyValue '' -Force
      }
      default { # None
        $item | Add-Member -NotePropertyName username -NotePropertyValue '' -Force
        $item | Add-Member -NotePropertyName password -NotePropertyValue '' -Force
      }
    }

    # Genera .rds temporal con el nombre correcto del ítem
    $xml = New-RdsXmlFromMapItem -MapItem $item
    $tmp = Join-Path $env:TEMP ("{0}.rds" -f [IO.Path]::GetFileNameWithoutExtension($item.name))
    Set-Content -Path $tmp -Value $xml -Encoding UTF8

    # Sube/actualiza el DS como ítem de catálogo (sin 'Parent' ni REST manual)
    $args = @{
      ReportServerUri = $ApiUrl
      Path            = $tmp
      RsFolder        = $folderNorm
      Overwrite       = $true
    }
    if ($script:cred) { $args.Credential = $script:cred }

    try {
      Write-RsCatalogItem @args | Out-Null
      Write-Host "OK DS publicado: $folderNorm/$($item.name)"
    }
    catch {
      Write-Warning "Fallo publicando DS $($item.name) en $folderNorm: $_"
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

# 2) Publicar/actualizar los DataSources desde el mapa (genera .rds y los sube con overwrite)
if ($EnvMapPath -and (Test-Path $EnvMapPath)) {
  Write-Host "Publicando DS desde mapa: $EnvMapPath"
  Publish-RdsFromMap -ApiUrl $ApiUrl -SharedDsFolder "$TargetBase/Data Sources" -MappingFile $EnvMapPath
} else {
  Write-Warning "No se encontró -EnvMapPath (o archivo no existe); se omitirá la publicación de DS por mapa."
}

# 2.1) (Opcional) Publicar .rds del repositorio para completar los que no estén en el mapa
Publish-SharedRdsFromProjects -ApiUrl $ApiUrl -ProjectDirs $projects -SharedDsFolder "$TargetBase/Data Sources"


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
