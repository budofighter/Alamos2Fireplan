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
