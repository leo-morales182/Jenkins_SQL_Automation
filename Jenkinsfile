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
