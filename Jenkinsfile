pipeline {
  agent { label 'SSRS_PC_I72AG2B' }
  options { skipDefaultCheckout(true) }

  parameters {
    choice(name: 'ENV', choices: ['dev', 'qa', 'prod'], description: 'Ambiente para datasources.map.<ENV>.json')
  }

  environment {
    ENV = "${params.ENV}"
    PORTAL_URL = 'http://localhost/Reports'
    API_URL    = 'http://localhost/ReportServer'
  }

  stages {
    stage('Prepare Workspace') {
      steps { deleteDir() }
    }

    stage('Checkout - Automation Scripts') {
      steps {
        // Checkout del repo en la RAÍZ del workspace
        checkout([
          $class: 'GitSCM',
          branches: [[name: '*/main']],
          userRemoteConfigs: [[
            url: 'https://github.com/leo-morales182/Jenkins_SQL_Automation.git',
            credentialsId: 'Github_leo_morales_credentials'
          ]]
        ])
        // Diagnóstico opcional
        bat 'dir /b'
        bat 'dir /b automation'
        bat 'dir /b jenkins_env'
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

      # Rutas (CON directorio 'automation')
      $script     = Join-Path $env:WORKSPACE "automation\\scripts\\deploy-ssrs.ps1"
      $repoRoot   = Join-Path $env:WORKSPACE "ssrs\\reports"
      $envMapPath = Join-Path $env:WORKSPACE ("automation\\jenkins_env\\datasources.map.{0}.json" -f $env:ENV)

      Write-Host "SCRIPT PATH    : $script"
      Write-Host "REPO ROOT      : $repoRoot"
      Write-Host "ENV MAP PATH   : $envMapPath"

      if (-not (Test-Path $script)) {
        Write-Host "Contenido de WORKSPACE:"; Get-ChildItem $env:WORKSPACE -Force | Out-Host
        Write-Host "Contenido de WORKSPACE\\automation:"; Get-ChildItem (Join-Path $env:WORKSPACE 'automation') -Force | Out-Host
        throw "No encuentro el script: $script (revisa checkout de Jenkins_SQL_Automation en 'automation')."
      }
      if (-not (Test-Path $repoRoot)) {
        Write-Host "Contenido de WORKSPACE\\ssrs:"; Get-ChildItem (Join-Path $env:WORKSPACE 'ssrs') -Force | Out-Host
        throw "No encuentro la carpeta de reports: $repoRoot (revisa checkout de ssrs_projects)."
      }
      if (-not (Test-Path $envMapPath)) {
        Write-Host "Contenido de WORKSPACE\\automation\\jenkins_env:"; `
          Get-ChildItem (Join-Path $env:WORKSPACE 'automation\\jenkins_env') -Force | Out-Host
        throw "No encuentro el mapa de datasources: $envMapPath"
      }

      # (bootstrap PSGallery y módulo como ya lo tienes...)

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
