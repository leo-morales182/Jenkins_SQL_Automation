pipeline {
  agent { label 'SSRS_PC_I72AG2B' }
  options { skipDefaultCheckout(true) }

  parameters {
    choice(name: 'ENV', choices: ['dev', 'qa', 'prod'], description: 'Ambiente para datasources.map.<ENV>.json')
  }

  environment {
    ENV = "${params.ENV}"           // dev/qa/prod
    PORTAL_URL = 'http://localhost/Reports'
    API_URL    = 'http://localhost/ReportServer'
  }

  stages {

    stage('Prepare Workspace') {
      steps { deleteDir() }
    }

    stage('Checkout - Automation Scripts') {
      steps {
        dir('automation_repo') {
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
    }

    stage('Checkout - SSRS Reports') {
      steps {
        dir('ssrs') {
          checkout([
            $class: 'GitSCM',
            branches: [[name: '*/main']],
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
      Write-Host "ENV: ${env:ENV}"

      # === RUTAS (sin Join-Path para evitar rarezas) ===
      $script     = "$env:WORKSPACE\\automation\\scripts\\deploy-ssrs.ps1"
      $repoRoot   = "$env:WORKSPACE\\ssrs\\reports"
      $envMapPath = "$env:WORKSPACE\\automation\\jenkins_env\\datasources.map.$($env:ENV).json"

      Write-Host "SCRIPT PATH    : $script"
      Write-Host "REPO ROOT      : $repoRoot"
      Write-Host "ENV MAP PATH   : $envMapPath"

      if (-not (Test-Path -LiteralPath $script)) {
        Get-ChildItem "$env:WORKSPACE\\automation" -Force | Out-Host
        throw "No encuentro el script: $script (revisa repo Jenkins_SQL_Automation)."
      }
      if (-not (Test-Path -LiteralPath $repoRoot)) {
        Write-Warning "No existe $repoRoot. Contenido de $env:WORKSPACE\\ssrs:"
        Get-ChildItem "$env:WORKSPACE\\ssrs" -Force | Out-Host
        throw "No encuentro la carpeta de reports: $repoRoot (¿tu repo ssrs_projects tiene /reports en la raíz?)."
      }
      if (-not (Test-Path -LiteralPath $envMapPath)) {
        Write-Warning "Contenido de automation\\jenkins_env:"
        Get-ChildItem "$env:WORKSPACE\\automation\\jenkins_env" -Force | Out-Host
        throw "No encuentro el mapa de datasources: $envMapPath"
      }

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
      if (-not (Test-Path $psd1)) { throw "No encontré el .psd1 de $modName bajo $($modPath.FullName)" }

      Import-Module $psd1 -Force -DisableNameChecking -ErrorAction Stop
      Remove-Item alias:Set-RsDataSourceReference  -ErrorAction SilentlyContinue
      Remove-Item alias:Set-RsDataSource           -ErrorAction SilentlyContinue
      Remove-Item alias:Set-RsDataSourceReference2 -ErrorAction SilentlyContinue

      # === Ejecutar deploy ===
      & $script `
        -PortalUrl "${env:PORTAL_URL}" `
        -ApiUrl    "${env:API_URL}" `
        -TargetBase "/" `
        -RepoRoot  $repoRoot `
        -EnvMapPath $envMapPath
    '''
  }
}

  }
}
