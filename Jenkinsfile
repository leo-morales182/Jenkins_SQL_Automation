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

      # --- Bootstrap sin prompts, instalando GLOBALMENTE ---
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

      # Instalar para todos los usuarios (evita perfil SYSTEM raro)
      $globalModules = "$env:ProgramFiles\\WindowsPowerShell\\Modules"
      if (-not (Test-Path $globalModules)) { New-Item -Type Directory -Path $globalModules | Out-Null }

      if (-not (Get-Module -ListAvailable -Name ReportingServicesTools)) {
        Install-Module ReportingServicesTools -Scope AllUsers -Force -AllowClobber -Confirm:$false
      }

      # Importar y validar
      Import-Module ReportingServicesTools -Force -ErrorAction Stop
      $cmd = Get-Command Get-RsFolder -ErrorAction Stop
      Write-Host "Módulo cargado OK desde: $($cmd.Source)"

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
