pipeline {
    agent { label 'SSRS_PC_P7L4NG4' }
    options { skipDefaultCheckout(true) }

  stages {

    stage('Prepare Workspace') {
      steps { deleteDir() }
    }

    stage('Checkout - Automation Scripts') {
      steps {
        checkout([
          $class: 'GitSCM',
          branches: [[name: '*/main']],
          userRemoteConfigs: [[
            url: 'https://github.com/leo-morales182/Jenkins_SQL_Automation.git',
            credentialsId: 'Github_leo_morales_credentials'
          ]]
        ])
      }
    }

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
            $script   = Join-Path $env:WORKSPACE "scripts\\deploy-ssrs.ps1"

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

            # --- Descarga e importación del módulo por RUTA ---
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
            $cmd = Get-Command New-RsFolder -ErrorAction Stop
            Write-Host "Módulo cargado OK: $($cmd.Source)  en  $($cmd.Module.ModuleBase)"

            # Asegurar carpetas base mínimas (si quieres mantener este tramo aquí)
            $api = "http://desktop-p7l4ng4/ReportServer"
            if (-not (Get-RsFolderContent -ReportServerUri $api -Path '/' -ErrorAction SilentlyContinue | ? { $_.TypeName -eq 'Folder' -and $_.Name -eq 'Apps' })) {
                New-RsFolder -ReportServerUri $api -Path '/' -Name 'Apps' -ErrorAction Stop | Out-Null
                Write-Host "Creada carpeta: /Apps"
            } else { Write-Host "OK carpeta existe: /Apps" }

            if (-not (Get-RsFolderContent -ReportServerUri $api -Path '/Apps' -ErrorAction SilentlyContinue | ? { $_.TypeName -eq 'Folder' -and $_.Name -eq 'Smoke' })) {
                New-RsFolder -ReportServerUri $api -Path '/Apps' -Name 'Smoke' -ErrorAction Stop | Out-Null
                Write-Host "Creada carpeta: /Apps/Smoke"
            } else { Write-Host "OK carpeta existe: /Apps/Smoke" }

            # === Invocar tu script con parámetros en una sola línea ===
            & "$env:WORKSPACE\\scripts\\deploy-ssrs.ps1" -PortalUrl "http://localhost/Reports" -ApiUrl "http://localhost/ReportServer" -TargetBase "/Apps"
            '''
        }
    }


    }
}
