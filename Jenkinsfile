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
            // 1) Mostrar workspace y confirmar rutas
            powershell '''
            Write-Host "WORKSPACE: $env:WORKSPACE"
            Get-ChildItem -Recurse -Filter deploy-smoke-ssrs.ps1 | Select-Object FullName
            '''

            // 2) Crear la ruta que espera el script y copiar el RDL de smoke
            powershell '''
            $rdlOrigen  = Join-Path $env:WORKSPACE "ssrs\\smoke_project\\Smoke_detailed.rdl"
            $rdlDestino = Join-Path $env:WORKSPACE "reports\\RDL\\smoke\\hello_world.rdl"

            if (-not (Test-Path $rdlOrigen)) { throw "No encuentro el RDL de origen: $rdlOrigen" }

            New-Item -ItemType Directory -Force -Path (Split-Path $rdlDestino) | Out-Null
            Copy-Item $rdlOrigen $rdlDestino -Force
            Write-Host "Copiado RDL a: $rdlDestino"
            '''

            powershell '''
            $ErrorActionPreference = "Stop"
            $ProgressPreference = "SilentlyContinue"
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

            # 1) Proveedor NuGet sin prompts
            if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
            }

            # 2) Confiar en PSGallery y evitar confirmaciones
            if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne "Trusted") {
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
            }

            # 3) Instalar ReportingServicesTools sin prompts (si falta)
            if (-not (Get-Module -ListAvailable -Name ReportingServicesTools)) {
                Install-Module ReportingServicesTools -Scope CurrentUser -Force -AllowClobber -Confirm:$false
            }

            # 4) Import explícito
            Import-Module ReportingServicesTools -Force
            '''

            // 3) Ejecutar el script desde /scripts (donde ya lo encontramos)
            powershell '''
            $script = Join-Path $env:WORKSPACE "scripts\\deploy-smoke-ssrs.ps1"
            if (-not (Test-Path $script)) { throw "No encuentro el script: $script" }

            & $script `
                -PortalUrl  "http://localhost/Reports" `
                -ApiUrl     "http://localhost/ReportServer" `
                -TargetFolder "/Apps/Smoke"
            '''
        }
        }

        }
}
