pipeline {
  agent { label 'SSRS_PC_P7L4NG4' }

  stages {

    stage('Checkout - SSRS Reports') {
        steps {
            dir('ssrs') {
            checkout([
                $class: 'GitSCM',
                branches: [[name: '*/main']],  // ajusta si usas otra rama
                userRemoteConfigs: [[
                url: 'https://github.com/leo-morales182/ssrs_projects.git',
                credentialsId: 'github-pat-leo'
                ]]
            ])
            }
        }
        }

stage('Deploy SSRS') {
  steps {
    powershell '''
      $ErrorActionPreference = "Stop"
      $ProgressPreference = "SilentlyContinue"
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

      Write-Host "WORKSPACE: $env:WORKSPACE"

      # Rutas
      $script   = Join-Path $env:WORKSPACE "scripts\\deploy-smoke-ssrs.ps1"
      $origen   = Join-Path $env:WORKSPACE "ssrs\\reports\\RDL\\smoke\\Smoke_detailed.rdl"
      $destino  = Join-Path $env:WORKSPACE "reports\\RDL\\smoke\\Smoke_detailed.rdl"

      if (-not (Test-Path $script))  { throw "No encuentro el script: $script" }
      if (-not (Test-Path $origen))  { throw "No encuentro el RDL de origen: $origen" }

      New-Item -ItemType Directory -Force -Path (Split-Path $destino) | Out-Null
      Copy-Item $origen $destino -Force
      Write-Host "Copiado RDL a: $destino"

      # --- Bootstrap PSGallery/NuGet sin prompts ---
      if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
      }
      try {
        $repo = Get-PSRepository -Name PSGallery -ErrorAction Stop
        if ($repo.InstallationPolicy -ne "Trusted") {
          Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }
      } catch {
        Register-PSRepository -Default -ErrorAction SilentlyContinue
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
      }

      # --- Descarga e importación del módulo por RUTA (a prueba de balas) ---
      $modBase = "C:\\jenkins\\psmodules"
      $modName = "ReportingServicesTools"
      if (-not (Test-Path $modBase)) { New-Item -Type Directory -Path $modBase | Out-Null }
      if (-not (Get-ChildItem -Directory (Join-Path $modBase $modName) -ErrorAction SilentlyContinue)) {
        Save-Module -Name $modName -Path $modBase -Force
      }
      $modPath = Get-ChildItem -Directory (Join-Path $modBase $modName) | Sort-Object Name -Descending | Select-Object -First 1
      if (-not $modPath) { throw "No pude descargar $modName a $modBase" }
      $psd1 = Get-ChildItem -Path $modPath.FullName -Filter *.psd1 -Recurse | Select-Object -First 1 -Expand FullName
      if (-not (Test-Path $psd1)) { throw "No encontré el archivo .psd1 de $modName bajo $($modPath.FullName)" }

      Import-Module $psd1 -Force -DisableNameChecking -ErrorAction Stop
      # valida con un cmdlet estable del módulo
      $cmd = Get-Command New-RsFolder -ErrorAction Stop
      Write-Host "Módulo cargado OK: $($cmd.Source)  en  $($cmd.Module.ModuleBase)"

      # --- Ejecutar el deploy (misma sesión) ---
      & $script `
        -PortalUrl  "http://desktop-p7l4ng4/Reports" `
        -ApiUrl     "http://desktop-p7l4ng4/ReportServer" `
        -TargetFolder "/Apps/Smoke"
    '''
  }
}




        }
}
