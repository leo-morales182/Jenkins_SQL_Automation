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
        // (1) Mostrar la estructura de carpetas para ubicar el .ps1
        powershell '''
        Write-Host "=== Listando archivos .ps1 en el workspace ==="
        Get-ChildItem -Recurse -Filter deploy-smoke-ssrs.ps1 | Select-Object FullName
        '''

        // (2) Mostrar estructura general para ver dónde quedó cada repo
        powershell '''
        Write-Host "=== Listando carpetas en el workspace ==="
        Get-ChildItem -Directory | Select-Object Name
        '''

         // (3) Intentar ejecutar (no lo cambiamos aún, solo observamos la salida)
         powershell '''
        & .\\scripts\\deploy-smoke-ssrs.ps1 `
            -PortalUrl  "http://localhost/Reports" `
            -ApiUrl     "http://localhost/ReportServer" `
            -TargetFolder "/Apps/Smoke"
        '''

        powershell '''
          # Ejecutar script desde el repo de automatización,
          # usando los reportes ubicados en el repo ssrs.
          ./automation/scripts/deploy-smoke-ssrs.ps1 `
            -PortalUrl  "http://desktop-p7l4ng4/Reports" `
            -ApiUrl     "http://desktop-p7l4ng4/ReportServer" `
            -TargetFolder "/Apps/Smoke" `
            -ProjectPath "./ssrs"   # <--- si deseas pasar la ruta como parámetro
        '''
      }
    }
  }
}
