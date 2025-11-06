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

      # Mostrar workspace y ubicar script
      Write-Host "WORKSPACE: $env:WORKSPACE"
      $script = Join-Path $env:WORKSPACE "scripts\\deploy-smoke-ssrs.ps1"
      if (-not (Test-Path $script)) { throw "No encuentro el script: $script" }

      # Copiar RDL de prueba a la ruta estándar que espera el script
      $origen  = Join-Path $env:WORKSPACE "reports\\RDL\\smoke\\Smoke_detailed.rdl"   # <-- ajusta si usas otro nombre
      $destino = Join-Path $env:WORKSPACE "reports\\RDL\\smoke\\Smoke_detailed.rdl"   # ya lo tienes en esa ruta en tu repo
      if (-not (Test-Path $origen)) { throw "No encuentro el RDL: $origen" }

      # Bootstrap sin prompts (misma sesión)
      if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
      }
      if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
        Register-PSRepository -Default -ErrorAction SilentlyContinue
      }
      if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne "Trusted") {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
      }
      if (-not (Get-Module -ListAvailable -Name ReportingServicesTools)) {
        Install-Module ReportingServicesTools -Scope CurrentUser -Force -AllowClobber -Confirm:$false
      }
      Import-Module ReportingServicesTools -Force

      # Ejecutar el script (mismo proceso/sesión, el módulo ya está importado)
      & $script `
        -PortalUrl  "http://desktop-p7l4ng4/Reports" `
        -ApiUrl     "http://desktop-p7l4ng4/ReportServer" `
        -TargetFolder "/Apps/Smoke"
    '''
  }
}


        }
}
