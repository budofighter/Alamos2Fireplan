BeforeAll {
    . "$PSScriptRoot/../setup.lib.ps1"
}

Describe 'Update-EnvFile' {
    It 'ersetzt vorhandene Schlüssel und erhält andere Zeilen' {
        $tmp = Join-Path $TestDrive '.env'
        Set-Content -LiteralPath $tmp -Value @(
            'MQTT_BROKER=127.0.0.1',
            'MQTT_USERNAME=alt',
            'FIREPLAN_SECRET=geheim'
        ) -Encoding UTF8

        $result = Update-EnvFile -Path $tmp -Values @{ MQTT_USERNAME = 'neu'; MQTT_PASSWORD = 'pw' }

        $result | Should -Contain 'MQTT_USERNAME=neu'
        $result | Should -Contain 'MQTT_PASSWORD=pw'
        $result | Should -Contain 'FIREPLAN_SECRET=geheim'
        ($result | Where-Object { $_ -like 'MQTT_USERNAME=*' }).Count | Should -Be 1
    }

    It 'legt Schlüssel an, wenn die Datei fehlt' {
        $tmp = Join-Path $TestDrive 'neu.env'
        $result = Update-EnvFile -Path $tmp -Values @{ MQTT_PORT = '1883' }
        $result | Should -Contain 'MQTT_PORT=1883'
        (Test-Path $tmp) | Should -BeTrue
    }
}

Describe 'Get-UpdateCopyPlan' {
    It 'behält nur Code-Elemente und schließt Daten aus' {
        $items = @('app','backend','tools','runserver.py','requirements.txt',
                   'setup.ps1','setup.lib.ps1','install.bat','update.bat','uninstall.bat',
                   'config','alarme.db','logs','backups','.env','README.md')
        $plan = Get-UpdateCopyPlan -SourceItems $items

        $plan | Should -Contain 'app'
        $plan | Should -Contain 'backend'
        $plan | Should -Contain 'setup.ps1'
        $plan | Should -Not -Contain 'config'
        $plan | Should -Not -Contain 'alarme.db'
        $plan | Should -Not -Contain 'logs'
        $plan | Should -Not -Contain 'backups'
        $plan | Should -Not -Contain '.env'
    }
}

Describe 'Get-BackupItems' {
    It 'wählt nur vorhandene schützenswerte Elemente' {
        $items = @('app','config','alarme.db','logs','backups','runserver.py')
        $backup = Get-BackupItems -TargetItems $items
        $backup | Should -Contain 'config'
        $backup | Should -Contain 'alarme.db'
        $backup | Should -Contain 'logs'
        $backup | Should -Not -Contain 'app'
        $backup | Should -Not -Contain 'backups'
    }
}

Describe 'Get-BackupFolderName' {
    It 'formatiert den Zeitstempel deterministisch' {
        $ts = [datetime]'2026-07-15T13:05:09'
        Get-BackupFolderName -Timestamp $ts | Should -Be 'backup_20260715-130509'
    }
}
