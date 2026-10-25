#Requires -Version 5.1
# ============================================================
#  HS-TECH - CENTRAL DE FERRAMENTAS v3.6
#  Modulos: painel ao vivo, limpeza, desempenho, perfis por jogo,
#  disco (saude/verificacao/otimizacao/benchmark), rede + DNS,
#  GPU/visuais, bloatware, alertas de temperatura, agendamento,
#  relatorio antes/depois e desfazer.
# ============================================================
param([switch]$Manutencao)

# Compatibilidade com PS2EXE: dentro dele a variavel do caminho do script fica vazia
# e os parametros podem chegar apenas pela linha de comando do executavel.
if (-not $Manutencao) {
    foreach ($argLinha in [Environment]::GetCommandLineArgs()) {
        if ($argLinha -ieq '-Manutencao') { $Manutencao = [switch]$true }
    }
}
$script:PacoteProgramasBase64 = '__HS_TECH_PROGRAMAS_BASE64__'
$script:CaminhoScript = $PSCommandPath
$script:EhExe = $false
if ([string]::IsNullOrWhiteSpace($script:CaminhoScript)) {
    $script:EhExe = $true
    $script:CaminhoScript = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}

# Sem console (executavel sem janela preta) esta linha causaria erro
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------- Auto-elevacao (precisa de administrador) ----------
$ehAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $ehAdmin) {
    try {
        $extras = @()
        if ($Manutencao) { $extras += '-Manutencao' }
        if ($script:EhExe) {
            if ($extras.Count -gt 0) { Start-Process -FilePath $script:CaminhoScript -Verb RunAs -ArgumentList $extras }
            else { Start-Process -FilePath $script:CaminhoScript -Verb RunAs }
        } else {
            $argsElev = ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`" {1}" -f $script:CaminhoScript, ($extras -join ' ')).Trim()
            Start-Process powershell -Verb RunAs -ArgumentList $argsElev
        }
    } catch { }
    exit
}

# ---------- Esconde a janela preta do console (se existir) ----------
try {
    Add-Type -Name Win -Namespace Native -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);'
    [void][Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0)
} catch { }

# ============================================================
#  CONFIGURACAO
# ============================================================
if ($script:EhExe) { $script:Pasta = Join-Path $env:LOCALAPPDATA 'OtimizadorGamer' }
else { $script:Pasta = Split-Path -Parent $script:CaminhoScript }

# O executável contém um ZIP dos programas permitidos. Na primeira execução,
# os arquivos são extraídos para o perfil do usuário; o EXE pode ser levado em USB.
if ($script:EhExe -and $script:PacoteProgramasBase64.Length -gt 1000 -and $env:LOCALAPPDATA) {
    try {
        $pastaPacote = Join-Path $env:LOCALAPPDATA 'HS-Tech\programas'
        $seloPacote = Join-Path $pastaPacote '.hs-tech-bundle-v1'
        if (-not (Test-Path -LiteralPath $seloPacote)) {
            $raizPacote = Split-Path $pastaPacote -Parent
            if (-not (Test-Path $raizPacote)) { New-Item -ItemType Directory -Path $raizPacote -Force | Out-Null }
            if (Test-Path -LiteralPath $pastaPacote) { Remove-Item -LiteralPath $pastaPacote -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $pastaPacote -Force | Out-Null
            $zipPacote = Join-Path $env:TEMP ('HS-Tech-programas-' + [guid]::NewGuid().ToString('N') + '.zip')
            [IO.File]::WriteAllBytes($zipPacote, [Convert]::FromBase64String($script:PacoteProgramasBase64))
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($zipPacote, $pastaPacote)
            Remove-Item -LiteralPath $zipPacote -Force -ErrorAction SilentlyContinue
            New-Item -ItemType File -Path $seloPacote -Force | Out-Null
        }
    } catch {
        try { Log ("Não foi possível preparar os programas incorporados: " + $_.Exception.Message) Yellow } catch { }
    }
}
if (-not (Test-Path $script:Pasta)) { New-Item -ItemType Directory -Path $script:Pasta -Force | Out-Null }
$script:LogFile       = Join-Path $script:Pasta ("log_{0}.txt" -f (Get-Date -Format 'yyyyMMdd'))
$script:BackupFile    = Join-Path $script:Pasta 'backup_ajustes.json'
$script:JogosFile     = Join-Path $script:Pasta 'jogos.json'
$script:CfgFile       = Join-Path $script:Pasta 'config.json'
$script:RelatorioFile = Join-Path $script:Pasta 'relatorios.txt'

# Processos de segundo plano fechados no Modo Performance (sem .exe)
$script:ProcessosFechar = @('OneDrive','Teams','ms-teams','Skype','Dropbox','GoogleDriveFS','YourPhone','PhoneExperienceHost')
$script:LimiteEspacoLivre = 15

# Jogos monitorados (nome do processo, sem .exe) - editavel na aba JOGOS
$script:Jogos = @('cs2','VALORANT-Win64-Shipping','FortniteClient-Win64-Shipping','GTA5','RobloxPlayerBeta','Overwatch','r5apex','destiny2')
if (Test-Path $script:JogosFile) {
    try { $script:Jogos = @(Get-Content $script:JogosFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
}

# Alertas e opcoes
$script:Cfg = @{ CpuMax = 90; GpuMax = 85; DiscoMax = 60; Alertas = $true; Auto = $true }
if (Test-Path $script:CfgFile) {
    try {
        $lido = Get-Content $script:CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $lido.PSObject.Properties) { $script:Cfg[$p.Name] = $p.Value }
    } catch { }
}

# Estado
$script:Silencioso = [bool]$Manutencao
$script:EncerrarAposAcao = $false
$script:TxtLog = $null
$script:BarraFill = $null
$script:BarraFundo = $null
$script:Ocupado = $false
$script:EmTick = $false
$script:TickN = 0
$script:ModoJogoAtivo = $false
$script:JogoAtual = $null
$script:PlanoAnterior = $null
$script:UltimoAlerta = @{}
$script:TempDisco = $null
$script:TemNvidia = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)
$script:Botoes = New-Object System.Collections.ArrayList
$script:NavBotoes = New-Object System.Collections.ArrayList
$script:Paginas = @{}

$script:Paleta = @{
    Fundo = '#090A0D'; Lateral = '#111216'; Painel = '#191B21'; Hover = '#262831'
    Neon = '#FF2638'; Rosa = '#FF5364'; Cian = '#35B8FF'; Amarelo = '#FFC857'
    Texto = '#EAF4FF'; Mudo = '#91A8C2'
    Borda = '#343640'; Trilho = '#22242B'
}

# ============================================================
#  UTILITARIOS
# ============================================================
function ParaCor { param([string]$Hex) return [System.Drawing.ColorTranslator]::FromHtml($Hex) }

function Fonte {
    param([string]$Nome = 'Segoe UI', [double]$Tam = 10, [string]$Estilo = 'Regular')
    return (New-Object System.Drawing.Font($Nome, [single]$Tam, [System.Drawing.FontStyle]$Estilo))
}

function Log {
    param([string]$Msg, [string]$Cor = 'Gray')
    $linha = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Msg
    try { Add-Content -Path $script:LogFile -Value $linha -Encoding UTF8 } catch { }
    if ($null -ne $script:TxtLog) {
        $mapa = @{ Gray = '#A9BBD0'; Green = '#00E6A0'; Red = '#FF5C7A'; Yellow = '#FFB020'; Cyan = '#16B8FF'; Magenta = '#A78BFA' }
        $hex = $mapa[$Cor]
        if (-not $hex) { $hex = '#B4B4C8' }
        $script:TxtLog.SelectionStart = $script:TxtLog.TextLength
        $script:TxtLog.SelectionLength = 0
        $script:TxtLog.SelectionColor = (ParaCor $hex)
        $script:TxtLog.AppendText($linha + "`r`n")
        $script:TxtLog.SelectionColor = $script:TxtLog.ForeColor
        $script:TxtLog.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Confirmar {
    param([string]$Pergunta)
    if ($script:Silencioso) { return $true }
    $r = [System.Windows.Forms.MessageBox]::Show($Pergunta, 'HS-Tech', 'YesNo', 'Question')
    return ($r -eq 'Yes')
}

function Definir-Progresso {
    param([int]$Pct)
    if ($null -ne $script:BarraFill -and $null -ne $script:BarraFundo) {
        $script:BarraFill.Width = [int]($script:BarraFundo.Width * $Pct / 100)
    }
}

function Passo {
    param([int]$N, [int]$Total, [string]$Texto)
    Definir-Progresso ([int](($N / $Total) * 100))
    Log "[$N/$Total] $Texto" Magenta
}

function Salvar-Backup {
    param([string]$Chave, $Valor)
    $b = @{}
    if (Test-Path $script:BackupFile) {
        $atual = Get-Content $script:BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $atual.PSObject.Properties) { $b[$p.Name] = $p.Value }
    }
    if (-not $b.ContainsKey($Chave)) {   # guarda so o valor ORIGINAL
        $b[$Chave] = $Valor
        $b | ConvertTo-Json | Set-Content -Path $script:BackupFile -Encoding UTF8
    }
}

function Ler-Backup {
    param([string]$Chave)
    if (-not (Test-Path $script:BackupFile)) { return $null }
    $b = Get-Content $script:BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $p = $b.PSObject.Properties[$Chave]
    if ($p) { return $p.Value }
    return $null
}

function Definir-Reg {
    param([string]$Caminho, [string]$Nome, [int]$Valor)
    if (-not (Test-Path $Caminho)) { New-Item -Path $Caminho -Force | Out-Null }
    $atual = (Get-ItemProperty -Path $Caminho -Name $Nome -ErrorAction SilentlyContinue).$Nome
    if ($null -eq $atual) { $atual = '__AUSENTE__' }
    Salvar-Backup -Chave "$Caminho|$Nome" -Valor $atual
    Set-ItemProperty -Path $Caminho -Name $Nome -Value $Valor -Type DWord
}

function Plano-Atual {
    $saida = powercfg /getactivescheme
    if ($saida -match '([0-9a-fA-F\-]{36})') { return $Matches[1] }
    return $null
}

function Rodar-EmJob {
    # Roda um bloco em segundo plano mantendo a janela responsiva
    param([scriptblock]$Bloco, [object[]]$Argumentos)
    $job = Start-Job -ScriptBlock $Bloco -ArgumentList $Argumentos
    while ($job.State -eq 'Running') {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
    }
    $saida = Receive-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force
    return $saida
}

# ---------- Leituras do sistema (independentes de idioma) ----------
function Uso-CPU {
    try {
        $c = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        return [int]$c.PercentProcessorTime
    } catch { return $null }
}

function Uso-RAM {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        return [int](100 * ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize)
    } catch { return $null }
}

function Temp-CPU {
    try {
        $t = Get-CimInstance -Namespace 'root/wmi' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        $max = ($t | Measure-Object -Property CurrentTemperature -Maximum).Maximum
        $v = [math]::Round(($max / 10) - 273.15)
        if ($v -gt 0 -and $v -lt 130) { return [int]$v }
    } catch { }
    return $null
}

function Info-GPU {
    # Retorna valores nulos quando o Windows/driver nao fornece sensores confiaveis.
    # NVIDIA: nvidia-smi. Outras GPUs: contadores do Windows e sensores opcionais.
    $r = @{ Uso = $null; Temp = $null; Fabricante = 'Desconhecido'; Nome = 'GPU nao identificada' }
    try {
        $adaptadores = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.Name -and $_.Name -notmatch 'Microsoft Basic Display|Remote Display|Virtual Display' })
        if ($adaptadores.Count -gt 0) {
            $principal = $adaptadores | Select-Object -First 1
            $r.Nome = [string]$principal.Name
            $r.Fabricante = [string]$principal.AdapterCompatibility
            if ([string]::IsNullOrWhiteSpace($r.Fabricante)) {
                if ($r.Nome -match 'NVIDIA|GeForce|Quadro|RTX|GTX') { $r.Fabricante = 'NVIDIA' }
                elseif ($r.Nome -match 'AMD|Radeon') { $r.Fabricante = 'AMD' }
                elseif ($r.Nome -match 'Intel|Arc|UHD|Iris') { $r.Fabricante = 'Intel' }
            }
        }
    } catch { }

    # NVIDIA: telemetria direta pelo driver quando nvidia-smi estiver disponivel.
    if ($script:TemNvidia) {
        try {
            $linha = & nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>$null | Select-Object -First 1
            if ($linha) {
                $partes = $linha -split ','
                $usoNvidia = 0
                $tempNvidia = 0
                if ([int]::TryParse($partes[0].Trim(), [ref]$usoNvidia)) { $r.Uso = [Math]::Max(0, [Math]::Min(100, $usoNvidia)) }
                if ([int]::TryParse($partes[1].Trim(), [ref]$tempNvidia)) { $r.Temp = $tempNvidia }
                $r.Fabricante = 'NVIDIA'
            }
        } catch { }
    }

    # Uso agregado dos motores GPU do Windows; pode incluir mais de um adaptador.
    if ($null -eq $r.Uso) {
        try {
            $lista = @(Get-Counter -ListSet 'GPU Engine' -ErrorAction Stop |
                Select-Object -ExpandProperty Counter |
                Where-Object { $_ -match 'Utilization Percentage' })
            if ($lista.Count -gt 0) {
                $amostras = @(Get-Counter -Counter $lista -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop)
                $valores = @($amostras.CounterSamples | Where-Object { $_.CookedValue -ge 0 } |
                    ForEach-Object { [double]$_.CookedValue })
                if ($valores.Count -gt 0) {
                    $soma = ($valores | Measure-Object -Sum).Sum
                    $r.Uso = [int][Math]::Max(0, [Math]::Min(100, [Math]::Round($soma)))
                }
            }
        } catch { }
    }

    # Temperatura por LibreHardwareMonitor/OpenHardwareMonitor, se instalado e ativo.
    if ($null -eq $r.Temp) {
        foreach ($namespace in @('root/LibreHardwareMonitor', 'root/OpenHardwareMonitor')) {
            try {
                $sensores = @(Get-CimInstance -Namespace $namespace -ClassName Sensor -ErrorAction Stop |
                    Where-Object { $_.SensorType -eq 'Temperature' -and $_.Name -match 'GPU|Core|Hot Spot|Junction' })
                if ($sensores.Count -gt 0) {
                    $temperatura = $sensores | Measure-Object -Property Value -Maximum
                    if ($null -ne $temperatura.Maximum -and $temperatura.Maximum -gt 0 -and $temperatura.Maximum -lt 125) {
                        $r.Temp = [int][Math]::Round($temperatura.Maximum)
                        break
                    }
                }
            } catch { }
        }
    }
    return $r
}

function Temp-Disco {
    try {
        $m = Get-PhysicalDisk | Get-StorageReliabilityCounter -ErrorAction Stop |
             Where-Object { $_.Temperature } | Measure-Object -Property Temperature -Maximum
        if ($m.Maximum) { return [int]$m.Maximum }
    } catch { }
    return $null
}

function Medir-Latencia {
    param([string]$Alvo)
    try {
        $p = Test-Connection -ComputerName $Alvo -Count 3 -ErrorAction Stop
        return [int][math]::Round(($p | Measure-Object -Property ResponseTime -Average).Average)
    } catch { return $null }
}


function Diagnostico-RedeCompleto {
    Log '--- Diagnostico de rede ---' Cyan
    try {
        $adaptadores = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
        if ($adaptadores.Count -eq 0) { Log 'Nenhum adaptador de rede ativo foi encontrado.' Yellow }
        foreach ($a in $adaptadores) {
            Log ("Adaptador ativo: {0} | {1} | velocidade {2}" -f $a.Name, $a.InterfaceDescription, $a.LinkSpeed) Green
        }
        $config = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.NetAdapter.Status -eq 'Up' })
        foreach ($n in $config) {
            Log ("IP: {0} | Gateway: {1} | DNS: {2}" -f ($n.IPv4Address.IPAddress -join ','), ($n.IPv4DefaultGateway.NextHop -join ','), ($n.DNSServer.ServerAddresses -join ',')) Cyan
        }
        foreach ($alvo in @('1.1.1.1','8.8.8.8')) {
            $ms = Medir-Latencia $alvo
            if ($null -eq $ms) { Log ("Ping {0}: sem resposta (pode haver bloqueio ICMP)" -f $alvo) Yellow }
            else { Log ("Ping {0}: media {1} ms" -f $alvo,$ms) Green }
        }
        try {
            $dns = Resolve-DnsName 'www.microsoft.com' -ErrorAction Stop | Select-Object -First 1
            Log ("DNS: resolucao de www.microsoft.com respondeu ({0})" -f $dns.Name) Green
        } catch { Log 'DNS: a consulta de nome falhou. Verifique conexao, DNS ou firewall.' Yellow }
        Log 'O ping mede latencia ate o destino, nao mede diretamente o ping dentro do jogo.' Yellow
    } catch { Log ("Falha no diagnostico de rede: {0}" -f $_.Exception.Message) Red }
}

function Recomendar-Armazenamento {
    Log '--- Recomendacoes de armazenamento ---' Cyan
    try {
        $volumes = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.Size -gt 0 })
        foreach ($v in $volumes) {
            $livrePct = [math]::Round(($v.SizeRemaining / $v.Size) * 100, 1)
            $tipo = 'tipo nao identificado'
            try {
                $part = Get-Partition -DriveLetter $v.DriveLetter -ErrorAction Stop | Select-Object -First 1
                $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
                $phys = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceId -eq "$($disk.Number)" } | Select-Object -First 1
                if ($phys -and $phys.MediaType -ne 'Unspecified') { $tipo = [string]$phys.MediaType }
            } catch { }
            $livreGB = [math]::Round($v.SizeRemaining / 1GB, 1)
            $msg = "Unidade $($v.DriveLetter): tipo $tipo; livre $livreGB GB ($livrePct%)."
            if ($livrePct -lt 10) { Log ($msg + ' CRITICO: libere espaco com cuidado.') Red }
            elseif ($livrePct -lt $script:LimiteEspacoLivre) { Log ($msg + ' Recomendacao: revisar arquivos grandes e temporarios.') Yellow }
            else { Log $msg Green }
            if ($tipo -eq 'SSD') { Log ("Unidade {0}: o Windows deve gerenciar TRIM; evite desfragmentacao manual repetida." -f $v.DriveLetter) Cyan }
            elseif ($tipo -eq 'HDD') { Log ("Unidade {0}: a otimizacao do Windows pode desfragmentar quando apropriado." -f $v.DriveLetter) Cyan }
        }
    } catch { Log ("Nao foi possivel analisar volumes: {0}" -f $_.Exception.Message) Yellow }
}

function Abrir-Historico {
    if (-not (Test-Path $script:LogFile)) {
        Log 'Ainda nao existe arquivo de log para hoje.' Yellow
        return
    }
    try { Start-Process notepad.exe -ArgumentList "`"$($script:LogFile)`"" }
    catch { Log 'Nao foi possivel abrir o historico de atividades.' Red }
}

# ============================================================
#  SEGURANCA
# ============================================================
function Criar-PontoRestauracao {
    Log '--- Ponto de restauracao ---' Cyan
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Checkpoint-Computer -Description 'OtimizadorGamer' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Log 'Ponto de restauracao criado.' Green
    } catch {
        Log "Nao foi possivel criar (o Windows limita a 1 a cada 24h): $($_.Exception.Message)" Yellow
    }
}

function Desfazer-Ajustes {
    Log '--- Desfazendo ajustes ---' Cyan
    if (-not (Test-Path $script:BackupFile)) { Log 'Nenhum backup encontrado.' Yellow; return }
    $b = Get-Content $script:BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $falhaRestauracaoDNS = $false
    foreach ($p in $b.PSObject.Properties) {
        if ($p.Name -eq 'PlanoEnergia') {
            powercfg /setactive $p.Value 2>$null
            Log 'Plano de energia restaurado.'
        } elseif ($p.Name -eq 'DNSAlterado') {
            # Marcador legado: a restauracao real e feita pelas entradas DNSOriginal.
            continue
        } elseif ($p.Name -like 'DNSOriginal|*') {
            try {
                $dns = $p.Value
                $indice = [int]$dns.InterfaceIndex
                $servidores = @($dns.ServerAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                if ($servidores.Count -gt 0) {
                    Set-DnsClientServerAddress -InterfaceIndex $indice -ServerAddresses $servidores -ErrorAction Stop
                } else {
                    Set-DnsClientServerAddress -InterfaceIndex $indice -ResetServerAddresses -ErrorAction Stop
                }
                Log "DNS original restaurado: $($dns.InterfaceAlias)" Green
            } catch {
                $falhaRestauracaoDNS = $true
                Log "Nao foi possivel restaurar o DNS ($($p.Name)): $($_.Exception.Message)" Yellow
            }
        } elseif ($p.Name -like 'Energia|*') {
            $partesEn = $p.Name -split '\|'
            powercfg /setacvalueindex $partesEn[1] SUB_PROCESSOR $partesEn[2] ([int]$p.Value) | Out-Null
            Log "Energia restaurada: $($partesEn[2])"
        } elseif ($p.Name -like '*|*') {
            $partes = $p.Name -split '\|', 2
            $caminho = $partes[0]; $nome = $partes[1]
            if ($p.Value -eq '__AUSENTE__') {
                Remove-ItemProperty -Path $caminho -Name $nome -ErrorAction SilentlyContinue
            } else {
                Set-ItemProperty -Path $caminho -Name $nome -Value ([int]$p.Value) -Type DWord
            }
            Log "Restaurado: $nome"
        }
    }
    $gAtual = Plano-Atual
    if ($gAtual) { powercfg /setactive $gAtual | Out-Null }
    if ($falhaRestauracaoDNS) {
        Log 'O backup foi mantido porque algum DNS nao foi restaurado. Corrija a conexao e tente DESFAZER novamente.' Yellow
    } else {
        Remove-Item $script:BackupFile -Force
        Log 'Ajustes revertidos. Reinicie o PC para concluir.' Green
    }
}


# ---------- Perfis reversiveis de desempenho ----------
function Aplicar-Perfil {
    param([ValidateSet('Equilibrado','Jogos','Economia','Maximo')][string]$Perfil)
    if ($Perfil -eq 'Maximo') { Ativar-DesempenhoMaximo; return }
    if (-not (Confirmar "Aplicar o perfil $Perfil? O plano de energia sera alterado e o anterior ficara salvo para restauracao.")) {
        Log 'Aplicacao de perfil cancelada.' Yellow
        return
    }
    $atual = Plano-Atual
    if ($atual) { Salvar-Backup -Chave 'PlanoEnergia' -Valor $atual }
    switch ($Perfil) {
        'Jogos' {
            $alvo = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
            powercfg /setactive $alvo 2>$null
            if ($LASTEXITCODE -ne 0) { Log 'Plano Alto desempenho indisponivel; nenhum plano alternativo foi forcado.' Yellow; return }
            Log 'Perfil Jogos aplicado. O consumo de energia pode aumentar.' Green
        }
        'Equilibrado' {
            $alvo = '381b4222-f694-41f0-9685-ff5bb260df2e'
            powercfg /setactive $alvo 2>$null
            if ($LASTEXITCODE -eq 0) { Log 'Perfil Equilibrado aplicado.' Green } else { Log 'Nao foi possivel ativar o plano Equilibrado.' Yellow }
        }
        'Economia' {
            $alvo = 'a1841308-3541-4fab-bc81-f71556f20b4a'
            powercfg /setactive $alvo 2>$null
            if ($LASTEXITCODE -eq 0) { Log 'Perfil Economia aplicado.' Green } else { Log 'Plano Economia indisponivel neste Windows.' Yellow }
        }
    }
}

function Mostrar-ResumoHardware {
    Log '--- Resumo de hardware ---' Cyan
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
        $discos = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
        $ram = Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum
        Log ("Windows: {0} | build {1}" -f $os.Caption, $os.BuildNumber) Cyan
        Log ("CPU: {0}" -f $cpu.Name) Green
        Log ("RAM instalada: {0:N1} GB" -f ($ram.Sum / 1GB)) Green
        foreach ($gpu in $gpus) { Log ("GPU: {0}" -f $gpu.Name) Green }
        foreach ($d in $discos) { Log ("Disco: {0} | {1} | {2}" -f $d.FriendlyName, $d.MediaType, $d.HealthStatus) Green }
        Log 'Temperaturas dependem do suporte do fabricante/driver; N/D nao significa defeito.' Yellow
    } catch { Log "Falha ao ler hardware: $($_.Exception.Message)" Red }
}

function Abrir-GerenciadorInicializacao {
    Log 'Abrindo ferramentas nativas. Nenhum aplicativo sera desativado automaticamente.' Cyan
    try { Start-Process 'ms-settings:startupapps' -ErrorAction Stop }
    catch {
        try { Start-Process 'taskmgr.exe' -ErrorAction Stop; Log 'No Gerenciador de Tarefas, abra Aplicativos de inicializacao.' Yellow }
        catch { Log 'Nao foi possivel abrir o gerenciador de inicializacao.' Red }
    }
}

function Exportar-RelatorioSistema {
    $destino = Join-Path $script:Pasta ("relatorio_sistema_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $ram = Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum
        $gpu = @(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name })
        $discos = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FriendlyName) | $($_.MediaType) | $($_.HealthStatus)" })
        @(
            'RELATORIO DO OTIMIZADOR GAMER',
            "Data: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')",
            "Windows: $($os.Caption) (build $($os.BuildNumber))",
            "CPU: $($cpu.Name)",
            ("RAM instalada: {0:N1} GB" -f ($ram.Sum / 1GB)),
            "Uso CPU agora: $(Uso-CPU)%",
            "Uso RAM agora: $(Uso-RAM)%",
            "GPU: $($gpu -join '; ')",
            "Discos: $($discos -join '; ')",
            '',
            'Temperaturas e FPS dependem de ferramentas compativeis; nao sao estimados.'
        ) | Set-Content -Path $destino -Encoding UTF8
        Log "Relatorio exportado: $destino" Green
        Start-Process notepad.exe -ArgumentList "`"$destino`""
    } catch { Log "Falha ao exportar relatorio: $($_.Exception.Message)" Red }
}

# ============================================================
#  LIMPEZA E DESEMPENHO
# ============================================================
function Gerenciar-MemoriaProcessos {
    # O Windows administra a RAM automaticamente; a opcao segura e revisar aplicativos e fechar apenas os escolhidos pelo usuario.
    Log '--- Analise de memoria e processos ---' Cyan
    try {
        $todos = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID } | Sort-Object -Property WorkingSet64 -Descending)
        $protegidos = @('System','Idle','Registry','smss','csrss','wininit','services','lsass','svchost','winlogon','dwm','fontdrvhost','spoolsv','MsMpEng','SecurityHealthService','SearchIndexer','Memory Compression','audiodg','WmiPrvSE','conhost','powershell','pwsh','OtimizadorGamer')
        $formMem = New-Object System.Windows.Forms.Form
        $formMem.Text = 'HS-Tech - Memoria e processos'
        $formMem.Size = New-Object System.Drawing.Size(760, 540)
        $formMem.StartPosition = 'CenterParent'
        $formMem.BackColor = (ParaCor $script:Paleta.Fundo)
        $formMem.ForeColor = (ParaCor $script:Paleta.Texto)
        $formMem.Font = (Fonte 'Segoe UI' 9 'Regular')
        $dica = New-Object System.Windows.Forms.Label
        $dica.Text = 'Selecione somente aplicativos que voce reconhece e nao esta usando. Processos essenciais sao protegidos. Fechar um aplicativo pode perder trabalho nao salvo.'
        $dica.Location = New-Object System.Drawing.Point(16, 14)
        $dica.Size = New-Object System.Drawing.Size(710, 42)
        $dica.ForeColor = (ParaCor $script:Paleta.Mudo)
        $formMem.Controls.Add($dica)
        $lista = New-Object System.Windows.Forms.ListView
        $lista.Location = New-Object System.Drawing.Point(16, 62)
        $lista.Size = New-Object System.Drawing.Size(710, 360)
        $lista.View = 'Details'
        $lista.CheckBoxes = $true
        $lista.FullRowSelect = $true
        $lista.GridLines = $true
        $lista.BackColor = (ParaCor $script:Paleta.Painel)
        $lista.ForeColor = (ParaCor $script:Paleta.Texto)
        [void]$lista.Columns.Add('Processo', 210)
        [void]$lista.Columns.Add('PID', 80)
        [void]$lista.Columns.Add('Memoria RAM', 120)
        [void]$lista.Columns.Add('Estado', 260)
        foreach ($p in ($todos | Select-Object -First 100)) {
            $mb = [math]::Round($p.WorkingSet64 / 1MB, 1)
            $seguro = ($protegidos -notcontains $p.ProcessName)
            $item = New-Object System.Windows.Forms.ListViewItem([string]$p.ProcessName)
            [void]$item.SubItems.Add([string]$p.Id)
            [void]$item.SubItems.Add("$mb MB")
            if ($seguro) {
                [void]$item.SubItems.Add('Aplicativo/processo - revisar antes de fechar')
                $item.Tag = [pscustomobject]@{ Id = $p.Id; Nome = $p.ProcessName; Seguro = $true }
            } else {
                [void]$item.SubItems.Add('PROTEGIDO - nao pode ser encerrado por aqui')
                $item.ForeColor = (ParaCor $script:Paleta.Amarelo)
                $item.Tag = [pscustomobject]@{ Id = $p.Id; Nome = $p.ProcessName; Seguro = $false }
            }
            [void]$lista.Items.Add($item)
        }
        $formMem.Controls.Add($lista)
        $btnAtualizar = Novo-BotaoPequeno 'ATUALIZAR LISTA' {
            $formMem.Close()
            Gerenciar-MemoriaProcessos
        } $script:Paleta.Cian 160 36
        $btnAtualizar.Location = New-Object System.Drawing.Point(16, 438)
        $formMem.Controls.Add($btnAtualizar)
        $btnFechar = Novo-BotaoPequeno 'ENCERRAR SELECIONADOS' {
            $selecionados = @($lista.CheckedItems | ForEach-Object { $_.Tag } | Where-Object { $_ -and $_.Seguro })
            if ($selecionados.Count -eq 0) {
                [void][System.Windows.Forms.MessageBox]::Show('Marque um ou mais processos nao protegidos que voce reconhece e deseja fechar.', 'HS-Tech', 'OK', 'Information')
                return
            }
            $nomes = ($selecionados | ForEach-Object { "$($_.Nome) (PID $($_.Id))" }) -join [Environment]::NewLine
            $pergunta = "Fechar os processos selecionados? Salve seu trabalho antes." + [Environment]::NewLine + [Environment]::NewLine + $nomes
            $res = [System.Windows.Forms.MessageBox]::Show($pergunta, 'Confirmar encerramento', 'YesNo', 'Warning')
            if ($res -ne 'Yes') { return }
            foreach ($itemProc in $selecionados) {
                try {
                    $proc = Get-Process -Id ([int]$itemProc.Id) -ErrorAction Stop
                    if ($proc.ProcessName -ne $itemProc.Nome -or $protegidos -contains $proc.ProcessName) {
                        Log "Processo $($itemProc.Nome) ignorado por verificacao de seguranca." Yellow
                        continue
                    }
                    Stop-Process -Id $proc.Id -ErrorAction Stop
                    Log "Processo encerrado por solicitacao do usuario: $($proc.ProcessName) (PID $($proc.Id))." Green
                } catch {
                    Log "Nao foi possivel encerrar $($itemProc.Nome) (PID $($itemProc.Id)): $($_.Exception.Message)" Yellow
                }
            }
            $formMem.Close()
            [void][System.Windows.Forms.MessageBox]::Show('Acao concluida. O Windows continuara gerenciando a memoria automaticamente.', 'HS-Tech', 'OK', 'Information')
        } $script:Paleta.Rosa 210 36
        $btnFechar.Location = New-Object System.Drawing.Point(516, 438)
        $formMem.Controls.Add($btnFechar)
        [void]$formMem.ShowDialog($script:Form)
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os -and $os.TotalVisibleMemorySize -gt 0) {
            $usada = [math]::Round(100 * ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize, 1)
            Log "Uso de RAM apos a analise: $usada%." Cyan
        }
    } catch {
        Log "Falha ao analisar memoria/processos: $($_.Exception.Message)" Red
        [void][System.Windows.Forms.MessageBox]::Show("Nao foi possivel abrir a analise de processos." + [Environment]::NewLine + $_.Exception.Message, 'HS-Tech', 'OK', 'Error')
    }
}



# ---------- BACKUP E RESTAURACAO ----------
function Obter-ArquivosBackup {
 $cats=@($script:BackupChecks.Keys|Where-Object {$script:BackupChecks[$_].Checked});$roots=@();$u=[Environment]::GetFolderPath('UserProfile')
 $precisaPastas=@($cats|Where-Object {$_ -in @('Pastas pessoais','Fotos','Videos','Documentos','Musicas','Compactados','Projetos')}).Count -gt 0
 if($precisaPastas){
   foreach($p in @('Desktop','Documents','Downloads','Pictures','Videos','Music','Saved Games')){$x=Join-Path $u $p;if(Test-Path -LiteralPath $x -PathType Container){$roots+= $x}}
   $oneDrive=Join-Path $u 'OneDrive';if(Test-Path -LiteralPath $oneDrive -PathType Container){$roots+=$oneDrive}
 }
 if($cats -contains 'Jogos e saves'){
   foreach($x in @((Join-Path $u 'Saved Games'),(Join-Path $u 'Documents\My Games'),(Join-Path $env:APPDATA 'Microsoft\Windows\GameBar'),(Join-Path $env:APPDATA 'Minecraft'),(Join-Path $env:APPDATA 'Godot'),(Join-Path $env:LOCALAPPDATA 'Packages'),(Join-Path $env:ProgramFiles 'Steam\userdata'))){if($x -and (Test-Path -LiteralPath $x -PathType Container)){$roots+=$x}}
 }
 $ext=@{Fotos=@('.jpg','.jpeg','.png','.gif','.bmp','.webp','.heic','.tif','.tiff','.raw','.cr2','.nef','.arw','.dng');Videos=@('.mp4','.mkv','.mov','.avi','.wmv','.webm','.m4v','.mpeg','.mpg','.3gp');Documentos=@('.pdf','.doc','.docx','.xls','.xlsx','.ppt','.pptx','.txt','.rtf','.odt','.ods','.csv');Musicas=@('.mp3','.wav','.flac','.aac','.m4a','.ogg','.wma');Compactados=@('.zip','.7z','.rar','.tar','.gz','.iso');Projetos=@('.ps1','.py','.js','.ts','.html','.css','.java','.cpp','.c','.cs','.sln','.blend','.psd')}
 $out=New-Object 'System.Collections.Generic.List[System.IO.FileInfo]';$seen=@{}
 foreach($root in ($roots|Select-Object -Unique)){try{Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue|ForEach-Object {$f=$_;$take=$false;if($cats -contains 'Pastas pessoais' -and $root -like "$u*"){$take=$true};if($cats -contains 'Jogos e saves' -and ($root -like '*Saved Games*' -or $root -like '*My Games*' -or $root -like '*Steam*userdata*' -or $root -like '*GameBar*' -or $root -like '*Minecraft*' -or $root -like '*Godot*')){$take=$true};foreach($c in $cats){if($ext.ContainsKey($c) -and $ext[$c] -contains $f.Extension.ToLowerInvariant()){$take=$true}};if($take -and !$seen.ContainsKey($f.FullName)){$seen[$f.FullName]=$true;$out.Add($f)}}}catch{}}
 return @($out)
}
function Escolher-DestinoBackup {$d=New-Object Windows.Forms.FolderBrowserDialog;$d.Description='Escolha HD externo, pendrive ou outro disco (não o que será formatado).';if($d.ShowDialog($script:Form)-eq[Windows.Forms.DialogResult]::OK){$script:BackupDestino=$d.SelectedPath;$script:BackupDestinoLabel.Text='Destino: '+$d.SelectedPath}}
function Analisar-Backup {$script:BackupEstado.Text='Analisando...';$script:BackupEstado.Refresh();$files=@(Obter-ArquivosBackup);$bytes=0L;foreach($f in $files){$bytes+=[long]$f.Length};$script:BackupFiles=$files;$script:BackupBytes=$bytes;$free='Escolha o destino para verificar espaço livre.';if($script:BackupDestino){$d=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($script:BackupDestino));$free='Livre no destino: {0:N2} GB' -f ($d.AvailableFreeSpace/1GB)};$script:BackupEstado.Text=('Encontrados {0:N0} arquivos | Necessário {1:N2} GB | {2}' -f $files.Count,($bytes/1GB),$free);Log $script:BackupEstado.Text Cyan}
function Fazer-Backup {
 if(!$script:BackupDestino){[void][Windows.Forms.MessageBox]::Show('Escolha o destino primeiro.','HS-Tech','OK','Warning');return};if(!$script:BackupFiles -or !$script:BackupFiles.Count){Analisar-Backup};$files=@($script:BackupFiles);if(!$files.Count){return}
 $drv=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($script:BackupDestino));if($drv.AvailableFreeSpace -lt ($script:BackupBytes+1GB)){[void][Windows.Forms.MessageBox]::Show('Espaço insuficiente no destino.','HS-Tech','OK','Error');return}
 if(!(Confirmar ('Copiar {0} arquivos ({1:N2} GB) para {2}?' -f $files.Count,($script:BackupBytes/1GB),$script:BackupDestino))){return}
 $folder=Join-Path $script:BackupDestino ('HS-Tech-Backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss'));$data=Join-Path $folder 'Arquivos';New-Item -ItemType Directory -Path $data -Force|Out-Null;$manifest=New-Object 'System.Collections.Generic.List[object]';$i=0
 foreach($f in $files){$i++;$root=[IO.Path]::GetPathRoot($f.FullName);$rel=$f.FullName.Substring($root.Length).TrimStart('\');$dest=Join-Path (Join-Path $data ($root.TrimEnd('\').Replace(':',''))) $rel;$parent=Split-Path $dest -Parent;try{if(!(Test-Path $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null};Copy-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction Stop;$status='OK'}catch{$status='ERRO'};$manifest.Add([pscustomobject]@{Original=$f.FullName;Backup=$dest;Status=$status;Bytes=[long]$f.Length});if($i%50-eq 0){$script:BackupEstado.Text="Copiando $i de $($files.Count)...";$script:BackupEstado.Refresh();[Windows.Forms.Application]::DoEvents()}}
 $manifest|ConvertTo-Json -Depth 3|Set-Content (Join-Path $folder 'manifest.json') -Encoding UTF8;$ok=@($manifest|Where-Object Status -eq 'OK').Count;$script:BackupEstado.Text="Backup concluído: $ok de $($files.Count) arquivos. Pasta: $folder";[void][Windows.Forms.MessageBox]::Show($script:BackupEstado.Text,'HS-Tech','OK','Information')
}
function Restaurar-Backup {
 $found=@();foreach($d in [IO.DriveInfo]::GetDrives()){if($d.IsReady -and $d.DriveType -in @([IO.DriveType]::Fixed,[IO.DriveType]::Removable)){try{$found+=Get-ChildItem -LiteralPath $d.RootDirectory.FullName -Directory -Filter 'HS-Tech-Backup-*' -ErrorAction SilentlyContinue|Where-Object {Test-Path (Join-Path $_.FullName 'manifest.json')}|ForEach-Object {$_.FullName}}catch{}}}
 if(!$found.Count){[void][Windows.Forms.MessageBox]::Show('Nenhum backup HS-Tech encontrado nos discos conectados.','HS-Tech','OK','Information');return}
 $dlg=New-Object Windows.Forms.Form;$dlg.Text='Selecionar backup';$dlg.Size=New-Object Drawing.Size(760,300);$dlg.StartPosition='CenterParent';$list=New-Object Windows.Forms.ListBox;$list.Location=New-Object Drawing.Point(10,10);$list.Size=New-Object Drawing.Size(720,190);foreach($f in $found){[void]$list.Items.Add($f)};$dlg.Controls.Add($list);$b=New-Object Windows.Forms.Button;$b.Text='Restaurar';$b.Location=New-Object Drawing.Point(10,210);$b.Add_Click({if($list.SelectedItem){$dlg.Tag=[string]$list.SelectedItem;$dlg.DialogResult='OK';$dlg.Close()}});$dlg.Controls.Add($b);if($dlg.ShowDialog($script:Form)-ne[Windows.Forms.DialogResult]::OK){$dlg.Dispose();return};$folder=[string]$dlg.Tag;$dlg.Dispose();$manifest=@(Get-Content (Join-Path $folder 'manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json);$good=@($manifest|Where-Object {$_.Status -eq 'OK' -and (Test-Path -LiteralPath $_.Backup)});if(!(Confirmar ("Restaurar {0} arquivos? Sim: caminhos originais; Não: pasta HS-Tech-Restaurado." -f $good.Count))){return};$choice=[Windows.Forms.MessageBox]::Show('Restaurar nos caminhos originais? Sim = original; Não = pasta segura.','HS-Tech','YesNoCancel','Warning');if($choice-eq'Cancel'){return};$count=0;foreach($f in $good){try{$to=if($choice-eq'Yes'){[string]$f.Original}else{Join-Path (Join-Path $env:USERPROFILE 'HS-Tech-Restaurado') ([string]$f.Original).TrimStart('\').Replace(':','')};$parent=Split-Path $to -Parent;if(!(Test-Path $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null};Copy-Item -LiteralPath $f.Backup -Destination $to -Force;$count++}catch{}};$script:BackupEstado.Text="Restauração: $count arquivos copiados.";[void][Windows.Forms.MessageBox]::Show($script:BackupEstado.Text,'HS-Tech','OK','Information')
}
function Obter-EspacoNaoAlocadoDisco {
 param([Parameter(Mandatory=$true)][object]$Disco)
 $limite=[long]$Disco.Size
 $particoes=@(Get-Partition -DiskNumber ([int]$Disco.Number) -ErrorAction SilentlyContinue | Sort-Object Offset)
 $intervalos=New-Object System.Collections.Generic.List[object]
 $cursor=[long]0
 foreach($part in $particoes){
   $inicio=[long]$part.Offset
   $tamanho=[long]$part.Size
   if($inicio -gt $cursor){
     $livre=$inicio-$cursor
     if($livre -ge 1MB){$intervalos.Add([pscustomobject]@{Inicio=$cursor;Tamanho=$livre})}
   }
   $fim=$inicio+$tamanho
   if($fim -gt $cursor){$cursor=$fim}
 }
 if($limite -gt $cursor){
   $livre=$limite-$cursor
   if($livre -ge 1MB){$intervalos.Add([pscustomobject]@{Inicio=$cursor;Tamanho=$livre})}
 }
 $maior=$null
 foreach($iv in $intervalos){if($null -eq $maior -or $iv.Tamanho -gt $maior.Tamanho){$maior=$iv}}
 [pscustomobject]@{Disco=$Disco;Particoes=$particoes;Intervalos=@($intervalos);TotalNaoAlocado=[long](($intervalos|Measure-Object Tamanho -Sum).Sum);MaiorIntervalo=$maior}
}

function Criar-ParticaoBackup {
  $nl=[Environment]::NewLine
  $volumeOriginalTamanho = $null
  $discoOriginalNumero = $null
  $particaoOriginalNumero = $null
  $volumeReduzido = $false
  $particaoNovaCriada = $false
  try {
    foreach($cmd in @('Get-Partition','Get-Volume','Get-PartitionSupportedSize','Resize-Partition','New-Partition','Format-Volume')) {
      if(-not (Get-Command $cmd -ErrorAction SilentlyContinue)){[void][Windows.Forms.MessageBox]::Show("O Windows não disponibilizou o comando $cmd. Execute o HS-Tech como administrador e tente novamente.",'HS-Tech - Verificação de partição','OK','Warning');return}
    }
    Log 'Analisando volumes e limite de redução informado pelo Windows...' Cyan
    $candidatos=@()
    foreach($part in @(Get-Partition -ErrorAction Stop | Where-Object {$_.DriveLetter -and $_.Type -notin @('System','Reserved','Recovery') -and -not $_.IsSystem -and -not $_.IsBoot})) {
      try {
        $vol=Get-Volume -DriveLetter $part.DriveLetter -ErrorAction Stop
        if($vol.FileSystem -ne 'NTFS' -or $vol.Size -le 0){continue}
        $disk=Get-Disk -Number $part.DiskNumber -ErrorAction Stop
        if($disk.IsOffline -or $disk.IsReadOnly -or $disk.PartitionStyle -eq 'RAW'){continue}
        $supported=Get-PartitionSupportedSize -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -ErrorAction Stop
        $max=[math]::Max(0,[long]$part.Size-[long]$supported.SizeMin)
        $free=[long]$vol.SizeRemaining
        # Sugestão conservadora: no máximo metade do limite aceito pelo Windows e metade do espaço livre atual.
        $recomendado=[long]([math]::Floor([math]::Min(($max*0.5),($free*0.5))/1GB)*1GB)
        if($max -ge 1GB) {
          $item=[pscustomobject]@{Particao=$part;Volume=$vol;Disco=$disk;Suportado=$supported;MaxReducao=$max;Livre=$free;Recomendado=$recomendado}
          $candidatos+= $item
          Log ("Volume {0}: tamanho {1:N2} GB; livre {2:N2} GB; máximo de redução informado pelo Windows {3:N2} GB; sugestão conservadora {4:N2} GB." -f ($part.DriveLetter+':'),($part.Size/1GB),($free/1GB),($max/1GB),($recomendado/1GB)) Cyan
        }
      } catch { Log ("Volume {0}: não foi possível avaliar a redução: {1}" -f $part.DriveLetter,$_.Exception.Message) Yellow }
    }
    if(!$candidatos.Count){[void][Windows.Forms.MessageBox]::Show('Nenhum volume NTFS de dados foi encontrado com pelo menos 1 GB de redução suportada. O HS-Tech não alterou nenhum disco.','HS-Tech - Sem opção segura','OK','Information');return}
    $opcoes=foreach($c in $candidatos){"Unidade $($c.Particao.DriveLetter): | Disco $($c.Disco.Number) - $($c.Disco.FriendlyName) | Tamanho $([math]::Round($c.Particao.Size/1GB,2)) GB | Livre $([math]::Round($c.Livre/1GB,2)) GB | Máximo Windows $([math]::Round($c.MaxReducao/1GB,2)) GB | Sugestão $([math]::Round($c.Recomendado/1GB,2)) GB"}
    $escolha=[Microsoft.VisualBasic.Interaction]::InputBox(('AVALIAÇÃO DE REDUÇÃO'+$nl+$nl+($opcoes -join $nl)+$nl+$nl+'Digite a letra da unidade que deseja reduzir (ex.: D). Nenhuma alteração ocorrerá nesta etapa.'),'HS-Tech - Escolher volume','')
    if([string]::IsNullOrWhiteSpace($escolha)){return}
    $letra=$escolha.Trim().TrimEnd(':').ToUpperInvariant()
    $sel=@($candidatos | Where-Object {$_.Particao.DriveLetter.ToString().ToUpperInvariant() -eq $letra}) | Select-Object -First 1
    if(!$sel){[void][Windows.Forms.MessageBox]::Show('Unidade inválida. Nenhuma alteração foi feita.','HS-Tech','OK','Warning');return}
    # Reavaliar imediatamente antes de alterar para evitar usar uma estimativa desatualizada.
    $partAtual=Get-Partition -DiskNumber $sel.Particao.DiskNumber -PartitionNumber $sel.Particao.PartitionNumber -ErrorAction Stop
    $volAtual=Get-Volume -DriveLetter $sel.Particao.DriveLetter -ErrorAction Stop
    $limiteAtual=Get-PartitionSupportedSize -DiskNumber $partAtual.DiskNumber -PartitionNumber $partAtual.PartitionNumber -ErrorAction Stop
    $maxAtual=[math]::Max(0,[long]$partAtual.Size-[long]$limiteAtual.SizeMin)
    $livreAtual=[long]$volAtual.SizeRemaining
    $sugestaoAtual=[long]([math]::Floor([math]::Min(($maxAtual*0.5),($livreAtual*0.5))/1GB)*1GB)
    if($maxAtual -lt 1GB){[void][Windows.Forms.MessageBox]::Show('O limite de redução mudou e agora é inferior a 1 GB. Nada foi alterado.','HS-Tech','OK','Warning');return}
    $prompt=('Unidade {0}: tamanho atual {1:N2} GB; espaço livre {2:N2} GB.'+$nl+'Máximo de redução que o Windows informa ser suportado: {3:N2} GB.'+$nl+'Sugestão conservadora (metade do máximo e do espaço livre): {4:N2} GB.'+$nl+$nl+'Digite quantos GB deseja separar para a nova partição. O valor precisa ser menor ou igual ao máximo suportado. Para reduzir o risco, prefira a sugestão conservadora.' -f $letra,($partAtual.Size/1GB),($livreAtual/1GB),($maxAtual/1GB),($sugestaoAtual/1GB))
    $entrada=[Microsoft.VisualBasic.Interaction]::InputBox($prompt,'HS-Tech - Espaço a reduzir',([math]::Round($sugestaoAtual/1GB,2)).ToString([Globalization.CultureInfo]::InvariantCulture))
    if([string]::IsNullOrWhiteSpace($entrada)){return}
    $gb=0.0
    $normalizado=$entrada.Trim().Replace(',','.')
    if(-not [double]::TryParse($normalizado,[Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture,[ref]$gb) -or $gb -le 0){[void][Windows.Forms.MessageBox]::Show('Digite um número de GB válido, maior que zero. Nenhuma alteração foi feita.','HS-Tech','OK','Warning');return}
    $bytes=[long]([math]::Floor(($gb*1GB)/1MB)*1MB)
    if($bytes -gt $maxAtual){[void][Windows.Forms.MessageBox]::Show(('O valor informado excede o máximo que o Windows suporta agora ({0:N2} GB). Nada foi alterado.' -f ($maxAtual/1GB)),'HS-Tech','OK','Warning');return}
    $tamanhoNovo=[long]$partAtual.Size-$bytes
    if($tamanhoNovo -lt [long]$limiteAtual.SizeMin){[void][Windows.Forms.MessageBox]::Show('O tamanho final ficaria abaixo do limite suportado pelo Windows. Nada foi alterado.','HS-Tech','OK','Warning');return}
    $confirmacao=('ATENÇÃO: a unidade {0}: será reduzida em {1:N2} GB.'+$nl+'O tamanho atual passará de {2:N2} GB para aproximadamente {3:N2} GB.'+$nl+'O Windows informa que a redução é suportada, mas isso não garante risco zero. Faça backup dos arquivos importantes antes de continuar.'+$nl+$nl+'Após reduzir, o HS-Tech criará uma NOVA partição no espaço liberado e formatará somente essa nova partição em NTFS. ATENÇÃO: ela ficará no MESMO disco físico; se você apagar ou formatar o disco inteiro, o backup também poderá ser perdido. Mantenha outra cópia em HD externo ou outro disco físico. Confirme o disco e os dados antes de prosseguir.' -f $letra,($bytes/1GB),($partAtual.Size/1GB),($tamanhoNovo/1GB))
    if(-not (Confirmar $confirmacao)){return}
    Log ("Reduzindo a unidade {0}: em {1:N2} GB após validação do Windows..." -f $letra,($bytes/1GB)) Cyan
    $volumeOriginalTamanho = [long]$partAtual.Size
    $discoOriginalNumero = [int]$partAtual.DiskNumber
    $particaoOriginalNumero = [int]$partAtual.PartitionNumber
    Resize-Partition -DiskNumber $partAtual.DiskNumber -PartitionNumber $partAtual.PartitionNumber -Size $tamanhoNovo -ErrorAction Stop
    $volumeReduzido = $true
    Start-Sleep -Milliseconds 700
    $discoDepois=Get-Disk -Number $partAtual.DiskNumber -ErrorAction Stop
    $analiseDepois=Obter-EspacoNaoAlocadoDisco -Disco $discoDepois
    $bloco=$null
    foreach($iv in $analiseDepois.Intervalos){if($null -eq $bloco -or $iv.Tamanho -gt $bloco.Tamanho){$bloco=$iv}}
    if(!$bloco -or $bloco.Tamanho -lt $bytes){
      $motivo = if(!$bloco){'nenhum espaço não alocado foi identificado'}else{('o maior bloco livre tem {0:N2} GB, abaixo dos {1:N2} GB solicitados' -f ($bloco.Tamanho/1GB),($bytes/1GB))}
      Log ("Não foi possível criar a partição: {0}. Tentando restaurar o tamanho original do volume." -f $motivo) Yellow
      $revertido = $false
      try {
        $limiteRollback = Get-PartitionSupportedSize -DiskNumber $partAtual.DiskNumber -PartitionNumber $partAtual.PartitionNumber -ErrorAction Stop
        if ([long]$partAtual.Size -le [long]$limiteRollback.SizeMax) {
          Resize-Partition -DiskNumber $partAtual.DiskNumber -PartitionNumber $partAtual.PartitionNumber -Size ([long]$partAtual.Size) -ErrorAction Stop
          $revertido = $true
          Log 'Tamanho original do volume restaurado após falha ao localizar espaço suficiente.' Green
        }
      } catch { Log ("A restauração automática do tamanho original falhou: {0}" -f $_.Exception.Message) Red }
      $aviso = 'O volume foi reduzido, mas não havia um bloco contíguo suficiente para criar a nova partição.'
      if($revertido){$aviso += ' O tamanho original do volume foi restaurado.'}else{$aviso += ' Não foi possível confirmar a reversão; verifique Gerenciamento de Disco antes de continuar.'}
      $aviso += ' Nenhum volume existente foi formatado.'
      [void][Windows.Forms.MessageBox]::Show($aviso,'HS-Tech - Espaço liberado','OK','Warning')
      return
    }
    $novo=New-Partition -DiskNumber $partAtual.DiskNumber -Offset ([UInt64]$bloco.Inicio) -Size $bytes -AssignDriveLetter -ErrorAction Stop
    $particaoNovaCriada = $true
    $fmt=Format-Volume -Partition $novo -FileSystem NTFS -NewFileSystemLabel 'HS-TECH-BACKUP' -Confirm:$false -ErrorAction Stop
    $volumeReduzido = $false
    $script:BackupDestino=$fmt.DriveLetter+':\'
    $script:BackupDestinoLabel.Text='Destino: '+$script:BackupDestino
    Log ("Criada partição HS-TECH-BACKUP em {0}; volume original {1}: reduzido em {2:N2} GB." -f $script:BackupDestino,$letra,($bytes/1GB)) Green
    [void][Windows.Forms.MessageBox]::Show(('Concluído.'+$nl+'Volume original: '+$letra+':'+$nl+'Redução solicitada: '+[math]::Round($bytes/1GB,2)+' GB'+$nl+'Nova partição formatada em NTFS: '+$script:BackupDestino+$nl+$nl+'A partição original não foi formatada. Mesmo assim, redimensionar partições nunca é risco zero. Mantenha uma cópia dos dados importantes em outro disco físico.'),'HS-Tech - Partição criada','OK','Information')
  } catch {
    $rollbackMensagem = ''
    if ($volumeReduzido -and -not $particaoNovaCriada -and $null -ne $volumeOriginalTamanho) {
      try {
        $estadoAtual = Get-Partition -DiskNumber $discoOriginalNumero -PartitionNumber $particaoOriginalNumero -ErrorAction Stop
        $limiteRollback = Get-PartitionSupportedSize -DiskNumber $discoOriginalNumero -PartitionNumber $particaoOriginalNumero -ErrorAction Stop
        if ($volumeOriginalTamanho -le [long]$limiteRollback.SizeMax) {
          Resize-Partition -DiskNumber $discoOriginalNumero -PartitionNumber $particaoOriginalNumero -Size $volumeOriginalTamanho -ErrorAction Stop
          $rollbackMensagem = ' O tamanho original do volume foi restaurado.'
          Log 'Restauração automática do tamanho original concluída após falha na criação da partição.' Green
        } else {
          $rollbackMensagem = ' A restauração automática não foi possível; confira Gerenciamento de Disco.'
        }
      } catch {
        $rollbackMensagem = ' A restauração automática falhou; confira Gerenciamento de Disco antes de continuar.'
        Log ("Falha ao restaurar tamanho original: {0}" -f $_.Exception.Message) Red
      }
    } elseif ($particaoNovaCriada) {
      $rollbackMensagem = ' Uma nova partição pode existir sem formatação concluída; verifique Gerenciamento de Disco.'
    }
    Log ("Erro ao avaliar/reduzir/criar partição: {0}" -f $_.Exception.Message) Red
    [void][Windows.Forms.MessageBox]::Show(('Não foi possível concluir a operação. Verifique Gerenciamento de Disco e os dados antes de tentar novamente.'+$rollbackMensagem+$nl+'Erro: '+$($_.Exception.Message)),'HS-Tech - Erro','OK','Error')
  }
}
function Localizar-PastaProgramas {$c=@();if($env:LOCALAPPDATA){$c+=(Join-Path (Join-Path $env:LOCALAPPDATA 'HS-Tech') 'programas')};if($PSScriptRoot){$c+=(Join-Path $PSScriptRoot 'programas');$c+=(Join-Path $PSScriptRoot 'HS-Tech-Extras');$c+=(Join-Path (Split-Path $PSScriptRoot -Parent) 'programas')};if($script:CaminhoScript){$b=Split-Path $script:CaminhoScript -Parent;$c+=(Join-Path $b 'programas');$c+=(Join-Path $b 'HS-Tech-Extras');$c+=(Join-Path (Split-Path $b -Parent) 'programas')};foreach($x in ($c|Select-Object -Unique)){if(Test-Path -LiteralPath $x -PathType Container){return $x}};return $null}
function Ler-BibliotecaProgramas {$b=if($env:LOCALAPPDATA){$env:LOCALAPPDATA}else{$env:USERPROFILE};$f=Join-Path (Join-Path $b 'HS-Tech') 'programas.json';if(Test-Path $f){try{return @((Get-Content $f -Raw -Encoding UTF8|ConvertFrom-Json))}catch{}};return @()}
function Salvar-BibliotecaProgramas {try{$b=if($env:LOCALAPPDATA){$env:LOCALAPPDATA}else{$env:USERPROFILE};$d=Join-Path $b 'HS-Tech';if(!(Test-Path $d)){[void](New-Item -ItemType Directory -Path $d -Force)};ConvertTo-Json -InputObject @($script:BibliotecaProgramas) -Depth 4|Set-Content (Join-Path $d 'programas.json') -Encoding UTF8}catch{Log "Falha ao salvar biblioteca: $($_.Exception.Message)" Red}}
function Atualizar-ListaProgramas {if(!$script:ListaProgramasUI){return};$script:ListaProgramasUI.BeginUpdate();try{$script:ListaProgramasUI.Items.Clear();$q='';if($script:BuscaProgramasUI){$q=$script:BuscaProgramasUI.Text.Trim()};foreach($p in @($script:BibliotecaProgramas)){if(!$p.Caminho -or !(Test-Path -LiteralPath ([string]$p.Caminho))){continue};if($q -and $p.Nome -notlike "*$q*" -and $p.Caminho -notlike "*$q*"){continue};$e=[IO.Path]::GetExtension([string]$p.Caminho).ToLowerInvariant();$t=switch($e){'.exe'{'Aplicativo/instalador'}'.msi'{'Instalador MSI'}'.lnk'{'Atalho'}'.cmd'{'Script CMD'}'.bat'{'Script BAT'}'.ps1'{'Script PowerShell'}'.vbs'{'Script VBScript'}'.js'{'Script JavaScript'}'.reg'{'Registro do Windows'}'.appx'{'Pacote APPX'}'.msix'{'Pacote MSIX'}'.jar'{'Aplicativo Java'}default{'Arquivo ('+$e+')'}};$st=if($p.Risco){'Requer confirmação'}else{'Disponível'};$it=New-Object System.Windows.Forms.ListViewItem([string]$p.Nome);[void]$it.SubItems.Add($t);[void]$it.SubItems.Add($st);[void]$it.SubItems.Add([string]$p.Caminho);$it.Tag=$p;[void]$script:ListaProgramasUI.Items.Add($it)}}finally{$script:ListaProgramasUI.EndUpdate()}}
function Importar-PastaProgramas {param([string]$Pasta);if(!(Test-Path -LiteralPath $Pasta -PathType Container)){return};$n=0;foreach($a in Get-ChildItem -LiteralPath $Pasta -Recurse -File -ErrorAction SilentlyContinue){if(@($script:BibliotecaProgramas|Where-Object{$_.Caminho -eq $a.FullName}).Count -gt 0){continue};$e=$a.Extension.ToLowerInvariant();$risco=($e -notin @('.exe','.msi','.lnk')) -or ($a.Name -match 'Windows Update OFF|Printing OFF|Windows Search OFF|Pause Activate|activator|removeedge');$script:BibliotecaProgramas += [pscustomobject]@{Nome=[IO.Path]::GetFileNameWithoutExtension($a.Name);Caminho=$a.FullName;Risco=[bool]$risco};$n++};Salvar-BibliotecaProgramas;Atualizar-ListaProgramas;Log "Biblioteca atualizada: $n arquivo(s) adicionado(s)." Green}
function Importar-PastaProgramasLocal {$achou=$false;$p=Localizar-PastaProgramas;if($p){Importar-PastaProgramas $p;$achou=$true};$extras=@();if($script:CaminhoScript){$extras+=Join-Path (Split-Path $script:CaminhoScript -Parent) 'HS-Tech-Extras'};if($PSScriptRoot){$extras+=Join-Path $PSScriptRoot 'HS-Tech-Extras'};foreach($x in ($extras|Select-Object -Unique)){if((Test-Path -LiteralPath $x -PathType Container) -and $x -ne $p){Importar-PastaProgramas $x;$achou=$true}};if(!$achou){[void][Windows.Forms.MessageBox]::Show("Nenhuma pasta de programas encontrada. Use ADICIONAR ARQUIVOS ou IMPORTAR PASTA.",'HS-Tech','OK','Information')}}
function Adicionar-PastaProgramas {$d=New-Object Windows.Forms.FolderBrowserDialog;$d.Description='Selecione a pasta programas';if($d.ShowDialog($script:Form) -eq [Windows.Forms.DialogResult]::OK){Importar-PastaProgramas $d.SelectedPath}}
function Adicionar-ArquivosProgramas {$d=New-Object System.Windows.Forms.OpenFileDialog;$d.Title='Selecione programas ou instaladores para adicionar ao HS-Tech';$d.Multiselect=$true;$d.Filter='Todos os arquivos e programas (*.*)|*.*';if($d.ShowDialog($script:Form) -ne [Windows.Forms.DialogResult]::OK){return};$base=$null;try{if($script:CaminhoScript){$base=Split-Path $script:CaminhoScript -Parent}}catch{};if(!$base -or !$script:EhExe){$base=Join-Path $env:USERPROFILE 'HS-Tech-Portatil'};$destino=Join-Path $base 'HS-Tech-Extras';try{if(!(Test-Path -LiteralPath $destino)){New-Item -ItemType Directory -Path $destino -Force|Out-Null};foreach($arquivo in $d.FileNames){$nome=[IO.Path]::GetFileName($arquivo);$alvo=Join-Path $destino $nome;if((Test-Path -LiteralPath $alvo) -and ((Get-Item -LiteralPath $alvo).FullName -ne (Get-Item -LiteralPath $arquivo).FullName)){$nome=[IO.Path]::GetFileNameWithoutExtension($arquivo)+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+[IO.Path]::GetExtension($arquivo);$alvo=Join-Path $destino $nome};Copy-Item -LiteralPath $arquivo -Destination $alvo -Force};Importar-PastaProgramas $destino;[void][Windows.Forms.MessageBox]::Show("Arquivo(s) copiado(s) para:`r`n$destino`r`n`r`nPara levar esses extras a outro computador, copie também a pasta HS-Tech-Extras junto do EXE.",'HS-Tech','OK','Information')}catch{[void][Windows.Forms.MessageBox]::Show("Não foi possível adicionar os arquivos:`r`n$($_.Exception.Message)",'HS-Tech','OK','Error')}}
function Abrir-ProgramaSelecionado {if(!$script:ListaProgramasUI -or !$script:ListaProgramasUI.SelectedItems.Count){return};$p=$script:ListaProgramasUI.SelectedItems[0].Tag;$c=[string]$p.Caminho;if(!(Test-Path -LiteralPath $c -PathType Leaf)){return};$e=[IO.Path]::GetExtension($c).ToLowerInvariant();$nl=[Environment]::NewLine;if([Windows.Forms.MessageBox]::Show("Confirmar abertura/execução:$nl$c$nlConfirme a origem antes de continuar.",'HS-Tech','YesNo','Warning') -ne 'Yes'){return};try{switch($e){'.exe'{Start-Process $c}'.lnk'{Start-Process $c}'.cmd'{Start-Process $env:ComSpec -ArgumentList @('/d','/c','start','""',('"' + $c + '"')) -WorkingDirectory (Split-Path $c -Parent)}'.bat'{Start-Process $env:ComSpec -ArgumentList @('/d','/c','start','""',('"' + $c + '"')) -WorkingDirectory (Split-Path $c -Parent)}'.ps1'{Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$c+'"')) -WorkingDirectory (Split-Path $c -Parent)}'.msi'{Start-Process msiexec.exe -ArgumentList @('/i',('"'+$c+'"')) -Wait}'.reg'{if([Windows.Forms.MessageBox]::Show('Importar alterações no Registro?','HS-Tech','YesNo','Warning') -eq 'Yes'){Start-Process regedit.exe -ArgumentList @('/s',('"' + $c + '"'))}}'.appx'{if([Windows.Forms.MessageBox]::Show('Instalar pacote APPX?','HS-Tech','YesNo','Warning') -eq 'Yes'){$cmd="Add-AppxPackage -Path '$($c.Replace("'","''"))'";Start-Process powershell.exe -ArgumentList @('-NoProfile','-Command',$cmd) -Verb RunAs}}}}catch{Log "Falha ao abrir item: $($_.Exception.Message)" Red}}
function Remover-ProgramaSelecionado {if(!$script:ListaProgramasUI -or !$script:ListaProgramasUI.SelectedItems.Count){return};$p=$script:ListaProgramasUI.SelectedItems[0].Tag;$script:BibliotecaProgramas=@($script:BibliotecaProgramas|Where-Object{$_.Caminho -ne $p.Caminho});Salvar-BibliotecaProgramas;Atualizar-ListaProgramas}
$script:BibliotecaProgramas=@(Ler-BibliotecaProgramas)

function Limpar-Temporarios {
    param([switch]$SemConfirmar)
    Log '--- Limpeza de temporarios ---' Cyan
    if (-not $SemConfirmar -and -not (Confirmar "A limpeza remove arquivos temporarios que podem estar em uso. Os caches de shaders e a Lixeira serao preservados para evitar recompilacao e perda de arquivos. Continuar?")) {
        Log 'Limpeza cancelada pelo usuario.' Yellow
        return
    }
    # Nao apagar caches de shaders: o Windows/jogos podem precisar recompila-los,
    # causando travamentos temporarios depois da limpeza.
    $alvos = @(
        $env:TEMP, "$env:SystemRoot\Temp"
    )
    $letra = $env:SystemDrive.TrimEnd(':')
    $livreAntes = (Get-PSDrive -Name $letra).Free
    foreach ($a in $alvos) {
        if (Test-Path $a) {
            Get-ChildItem -Path $a -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Log "Limpo: $a"
        }
    }
    # A Lixeira e preservada intencionalmente; esvazia-la pode causar perda de dados.
    $livreDepois = (Get-PSDrive -Name $letra).Free
    $liberado = [math]::Round(($livreDepois - $livreAntes) / 1MB)
    Log "Espaco liberado: aproximadamente $liberado MB" Green
}

function Ajustar-Energia {
    Log '--- Plano de energia ---' Cyan
    $atual = Plano-Atual
    if ($atual) { Salvar-Backup -Chave 'PlanoEnergia' -Valor $atual }
    $altoDesempenho = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    powercfg /setactive $altoDesempenho 2>$null
    if ($LASTEXITCODE -ne 0) {
        $novo = powercfg -duplicatescheme $altoDesempenho 2>$null
        if ($novo -match '([0-9a-fA-F\-]{36})') { powercfg /setactive $Matches[1] }
    }
    $planoFinal = Plano-Atual
    if ($planoFinal -eq $altoDesempenho) {
        Log 'Plano Alto desempenho ativado e confirmado.' Green
    } else {
        Log 'O Windows nao confirmou a ativacao do plano Alto desempenho. Mantendo o plano atual.' Yellow
    }
}

function Ativar-DesempenhoMaximo {
    Log '--- Plano Desempenho máximo ---' Cyan
    if (Tem-Bateria) {
        if (-not (Confirmar "O plano Desempenho máximo mantém o processador no limite o tempo todo: aumenta o consumo e o calor e reduz a duração da bateria em notebook.`n`nÉ indicado para PC de mesa ou notebook ligado na tomada. Continuar?")) {
            Log 'Cancelado.' Yellow
            return
        }
    }
    $atual = Plano-Atual
    if ($atual) { Salvar-Backup -Chave 'PlanoEnergia' -Valor $atual }
    $guidModelo = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    $padraoGuid = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
    $alvo = $null

    # 1) o plano oculto ja foi criado antes neste PC?
    $lista = (powercfg /list | Out-String)
    foreach ($linha in ($lista -split "`r?`n")) {
        if ($linha -match $padraoGuid) {
            $g = $Matches[1]
            if (($g -ieq $guidModelo) -or ($linha -match 'Ultimate|Desempenho\s+m')) { $alvo = $g; break }
        }
    }
    # 2) senao, cria a partir do modelo do Windows
    if (-not $alvo) {
        $saida = (powercfg -duplicatescheme $guidModelo 2>&1 | Out-String)
        if ($saida -match $padraoGuid) { $alvo = $Matches[1] }
    }
    # 3) ativa e confirma
    if ($alvo) {
        powercfg /setactive $alvo 2>&1 | Out-Null
        $agora = Plano-Atual
        if ($agora -and ($agora -ieq $alvo)) {
            Log ("Plano Desempenho máximo ativado ({0})." -f (Nome-PlanoEnergia)) Green
            Adicionar-Achado 'Energia' 'Plano de energia Desempenho máximo ativado.' 'ok'
            return
        }
    }
    Log 'O plano Desempenho máximo não está disponível neste PC (comum em notebooks e em sistemas com modo de espera moderno). Será usado o Alto desempenho.' Yellow
    Adicionar-Achado 'Energia' 'Desempenho máximo indisponível neste PC; foi usado o plano Alto desempenho.' 'aviso'
    Ajustar-Energia
}

function Ajustar-ModoJogo {
    Log '--- Modo Jogo do Windows ---' Cyan
    Definir-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
    Definir-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Definir-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Definir-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Log 'Modo Jogo ativo e captura em segundo plano desativada.' Green
}

function Entrar-ModoPerformance {
    Log '--- Modo Performance: ON ---' Cyan
    if (-not $script:PlanoAnterior) { $script:PlanoAnterior = Plano-Atual }
    foreach ($p in $script:ProcessosFechar) {
        $procs = Get-Process -Name $p -ErrorAction SilentlyContinue
        if ($procs) {
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Log "Fechado: $p"
        }
    }
    Ajustar-Energia
    Silenciar-Notificacoes
    Log 'Modo Performance ativo.' Green
}

function Sair-ModoPerformance {
    Log '--- Modo Performance: OFF ---' Cyan
    $alvo = $script:PlanoAnterior
    if (-not $alvo) { $alvo = Ler-Backup 'PlanoEnergia' }
    if ($alvo) {
        powercfg /setactive $alvo 2>$null
        Log 'Plano de energia anterior restaurado.' Green
    } else {
        Log 'Nao ha plano anterior salvo.' Yellow
    }
    Restaurar-Notificacoes
    $script:PlanoAnterior = $null
}

function Listar-Inicializacao {
    Log '--- Apps que iniciam com o Windows ---' Cyan
    $itens = @(Get-CimInstance Win32_StartupCommand)
    foreach ($i in $itens) { Log ("{0}  ({1})" -f $i.Name, $i.Location) }
    Log "Total: $($itens.Count). Desative os desnecessarios em Gerenciador de Tarefas > Inicializar." Yellow
}

function Liberar-RAM {
    Log '--- Liberar RAM em espera ---' Cyan
    if (-not ('MemTool' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class MemTool {
    [DllImport("ntdll.dll")] static extern int NtSetSystemInformation(int cls, IntPtr info, int len);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string sys, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disable, ref TOKEN_PRIVILEGES np, int len, IntPtr prev, IntPtr ret);
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct TOKEN_PRIVILEGES { public int Count; public long Luid; public int Attr; }
    public static int PurgeStandby() {
        IntPtr token;
        OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, 0x28, out token);
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.Count = 1; tp.Attr = 2;
        LookupPrivilegeValue(null, "SeProfileSingleProcessPrivilege", out tp.Luid);
        AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        IntPtr p = Marshal.AllocHGlobal(4);
        Marshal.WriteInt32(p, 4);
        int r = NtSetSystemInformation(80, p, 4);
        Marshal.FreeHGlobal(p);
        return r;
    }
}
'@
    }
    $antes = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
    $r = [MemTool]::PurgeStandby()
    Start-Sleep -Milliseconds 500
    $depois = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
    if ($r -eq 0) {
        Log "RAM livre: $antes MB -> $depois MB" Green
    } else {
        Log "O Windows recusou a operacao (codigo $r)." Yellow
    }
}

function Ajustar-GPUSistema {
    Log '--- Ajustes de GPU e efeitos visuais ---' Cyan
    if (-not (Confirmar "Isto ativa o agendamento de GPU acelerado por hardware (HAGS), reduz efeitos visuais e desativa transparencias.`n`nPrecisa reiniciar o PC. Pode ser desfeito em DESFAZER. Continuar?")) {
        Log 'Cancelado.' Yellow; return
    }
    Definir-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
    Definir-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
    Definir-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
    Log 'Ajustes aplicados. Reinicie o PC. (HAGS so funciona em GPUs/drivers compativeis.)' Green
}

function Definir-HorarioAtivo {
    Log '--- Horario ativo do Windows Update ---' Cyan
    if (-not (Confirmar "Define o horario ativo das 08:00 as 02:00, evitando reinicios do Windows Update enquanto voce joga. Continuar?")) {
        Log 'Cancelado.' Yellow; return
    }
    Definir-Reg 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'ActiveHoursStart' 8
    Definir-Reg 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'ActiveHoursEnd' 2
    Log 'Horario ativo definido: 08:00 - 02:00.' Green
}

function Remover-Bloatware {
    Log '--- Remocao de bloatware ---' Cyan
    $lista = @('Microsoft.BingNews','Microsoft.BingWeather','Microsoft.GetHelp','Microsoft.Getstarted',
               'Microsoft.MicrosoftSolitaireCollection','Microsoft.MicrosoftOfficeHub','Microsoft.People',
               'Microsoft.WindowsFeedbackHub','Microsoft.YourPhone','Microsoft.ZuneMusic','Microsoft.ZuneVideo',
               'Clipchamp.Clipchamp','MicrosoftTeams','Microsoft.Todos','Microsoft.PowerAutomateDesktop')
    $instalados = @(Get-AppxPackage | Where-Object { $lista -contains $_.Name })
    if ($instalados.Count -eq 0) { Log 'Nenhum app da lista esta instalado.' Green; return }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Remover apps'
    $dlg.Size = New-Object System.Drawing.Size(460, 470)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = (ParaCor $script:Paleta.Fundo)
    $dlg.ForeColor = (ParaCor $script:Paleta.Texto)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false

    $aviso = New-Object System.Windows.Forms.Label
    $aviso.Text = "Marque os apps que deseja remover.`nPara reinstalar depois, use a Microsoft Store."
    $aviso.AutoSize = $true
    $aviso.Location = New-Object System.Drawing.Point(14, 12)
    $dlg.Controls.Add($aviso)

    $lb = New-Object System.Windows.Forms.CheckedListBox
    $lb.Location = New-Object System.Drawing.Point(14, 56)
    $lb.Size = New-Object System.Drawing.Size(414, 310)
    $lb.CheckOnClick = $true
    $lb.BackColor = (ParaCor $script:Paleta.Painel)
    $lb.ForeColor = (ParaCor $script:Paleta.Texto)
    $lb.BorderStyle = 'FixedSingle'
    foreach ($i in $instalados) { [void]$lb.Items.Add($i.Name) }
    $dlg.Controls.Add($lb)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'REMOVER'; $ok.Location = New-Object System.Drawing.Point(214, 380)
    $ok.Size = New-Object System.Drawing.Size(100, 34)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.FlatStyle = 'Flat'; $ok.ForeColor = (ParaCor $script:Paleta.Rosa)
    $dlg.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'CANCELAR'; $cancel.Location = New-Object System.Drawing.Point(328, 380)
    $cancel.Size = New-Object System.Drawing.Size(100, 34)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.FlatStyle = 'Flat'
    $dlg.Controls.Add($cancel)
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $marcados = @($lb.CheckedItems)
        foreach ($nome in $marcados) {
            foreach ($pkg in ($instalados | Where-Object { $_.Name -eq $nome })) {
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                    Log "Removido: $nome" Green
                } catch {
                    Log "Falha ao remover ${nome}: $($_.Exception.Message)" Yellow
                }
            }
        }
        if ($marcados.Count -eq 0) { Log 'Nada selecionado.' Yellow }
    } else {
        Log 'Cancelado.' Yellow
    }
    $dlg.Dispose()
}

# ============================================================
#  REDE
# ============================================================
function Otimizar-Rede {
    Log '--- Rede ---' Cyan
    ipconfig /flushdns | Out-Null
    Log 'Cache DNS limpo.' Green
    foreach ($alvo in @('1.1.1.1', '8.8.8.8')) {
        $ms = Medir-Latencia $alvo
        if ($null -ne $ms) { Log "Latencia media para ${alvo}: $ms ms" } else { Log "Sem resposta de $alvo" Yellow }
    }
}

function Aplicar-DNS {
    param([string]$Opcao)
    Log "--- DNS: $Opcao ---" Cyan
    $adaptadores = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
    foreach ($a in $adaptadores) {
        try {
            # Guarda a configuracao IPv4 original de cada adaptador apenas uma vez.
            # Um array vazio significa DNS automatico/DHCP e tambem precisa ser restaurado.
            if ($Opcao -ne 'Automatico') {
                $chaveBackup = "DNSOriginal|$($a.ifIndex)"
                if ($null -eq (Ler-Backup $chaveBackup)) {
                    $dnsOriginal = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
                        Select-Object -ExpandProperty ServerAddresses)
                    Salvar-Backup -Chave $chaveBackup -Valor ([pscustomobject]@{
                        InterfaceIndex = [int]$a.ifIndex
                        InterfaceAlias = [string]$a.Name
                        ServerAddresses = @($dnsOriginal)
                    })
                }
            }

            if ($Opcao -eq 'Cloudflare') {
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @('1.1.1.1', '1.0.0.1') -ErrorAction Stop
            } elseif ($Opcao -eq 'Google') {
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @('8.8.8.8', '8.8.4.4') -ErrorAction Stop
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
            }
            Log "Adaptador $($a.Name): DNS $Opcao aplicado." Green
        } catch {
            Log "Falha no adaptador $($a.Name): $($_.Exception.Message)" Yellow
        }
    }
    if ($Opcao -ne 'Automatico') { Salvar-Backup -Chave 'DNSAlterado' -Valor 1 }
    ipconfig /flushdns | Out-Null
}

# ============================================================
#  DISCO
# ============================================================
function Saude-Disco {
    Log '=== Saude dos discos ===' Cyan
    foreach ($pd in Get-PhysicalDisk) {
        $tam = [math]::Round($pd.Size / 1GB)
        $cor = if ($pd.HealthStatus -eq 'Healthy') { 'Green' } else { 'Red' }
        Log ("{0} | {1} | {2} GB | Saude: {3}" -f $pd.FriendlyName, $pd.MediaType, $tam, $pd.HealthStatus) $cor
        $c = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        if ($c) {
            if ($c.Temperature)            { Log ("   Temperatura: {0} C" -f $c.Temperature) }
            if ($null -ne $c.Wear)         { Log ("   Desgaste (SSD): {0}%" -f $c.Wear) }
            if ($null -ne $c.PowerOnHours) { Log ("   Horas ligado: {0}" -f $c.PowerOnHours) }
            if ($null -ne $c.ReadErrorsTotal -and $c.ReadErrorsTotal -gt 0) {
                Log ("   ATENCAO: {0} erros de leitura registrados" -f $c.ReadErrorsTotal) Red
            }
        }
    }
    Log '--- Espaco livre ---' Cyan
    foreach ($v in Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter }) {
        $pct = [math]::Round(($v.SizeRemaining / $v.Size) * 100)
        $cor = if ($pct -lt $script:LimiteEspacoLivre) { 'Red' } else { 'Green' }
        Log ("{0}: {1} GB livres de {2} GB ({3}%)" -f $v.DriveLetter, [math]::Round($v.SizeRemaining / 1GB), [math]::Round($v.Size / 1GB), $pct) $cor
        if ($pct -lt $script:LimiteEspacoLivre) {
            Log "   Pouco espaco livre em $($v.DriveLetter): - prejudica o desempenho e a vida util do SSD." Yellow
        }
    }
}

function Verificar-Disco {
    Log '=== Verificacao do sistema de arquivos (somente leitura) ===' Cyan
    foreach ($v in Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter }) {
        $letra = [string]$v.DriveLetter
        Log "Verificando ${letra}: ..."
        $r = Rodar-EmJob { param($l) Repair-Volume -DriveLetter $l -Scan } @($letra)
        $txt = "$r".Trim()
        if ($txt -eq 'NoErrorsFound') {
            Log "Resultado de ${letra}: nenhum erro encontrado." Green
        } elseif ($txt) {
            Log "Resultado de ${letra}: $txt - considere agendar a verificacao com reparo." Red
        } else {
            Log "Resultado de ${letra}: indeterminado." Yellow
        }
    }
}

function Otimizar-Disco {
    Log '=== Otimizacao de discos ===' Cyan
    foreach ($v in Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter }) {
        $letra = [string]$v.DriveLetter
        $tipo = 'Unspecified'
        try {
            $disk = Get-Partition -DriveLetter $letra -ErrorAction Stop | Get-Disk
            $pd = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq "$($disk.Number)" }
            if ($pd) { $tipo = [string]$pd.MediaType }
        } catch { }

        $bloco = {
            param($l, $m)
            if ($m -eq 'ReTrim') { Optimize-Volume -DriveLetter $l -ReTrim }
            elseif ($m -eq 'Defrag') { Optimize-Volume -DriveLetter $l -Defrag }
            else { Optimize-Volume -DriveLetter $l -Analyze }
        }
        if ($tipo -eq 'SSD') {
            Log "${letra}: e SSD -> executando TRIM (nunca desfragmentar SSD)."
            [void](Rodar-EmJob $bloco @($letra, 'ReTrim'))
            Log "TRIM concluido em ${letra}:" Green
        } elseif ($tipo -eq 'HDD') {
            Log "${letra}: e HDD -> desfragmentando (pode demorar)."
            [void](Rodar-EmJob $bloco @($letra, 'Defrag'))
            Log "Desfragmentacao concluida em ${letra}:" Green
        } else {
            Log "${letra}: tipo nao identificado -> apenas analise (seguro)."
            [void](Rodar-EmJob $bloco @($letra, 'Analyze'))
        }
    }
}

function Agendar-VerificacaoReparo {
    Log '=== Agendar verificacao com reparo (CHKDSK) ===' Cyan
    $unid = [Microsoft.VisualBasic.Interaction]::InputBox('Letra da unidade a verificar na proxima reinicializacao (ex: C):', 'Verificacao com reparo', 'C')
    $unid = "$unid".Trim().TrimEnd(':')
    if ($unid -notmatch '^[a-zA-Z]$') { Log 'Cancelado ou letra invalida.' Yellow; return }
    if (Confirmar "Marcar ${unid}: para ser verificado e reparado na proxima reinicializacao? Isso pode demorar na inicializacao.") {
        fsutil dirty set "${unid}:" | Out-Null
        Log "Unidade ${unid}: marcada. O Windows fara a verificacao ao reiniciar." Green
    } else {
        Log 'Cancelado.' Yellow
    }
}

function Verificar-ArquivosWindows {
    Log '=== SFC: verificando arquivos do Windows (demorado) ===' Cyan
    $p = Start-Process -FilePath 'sfc.exe' -ArgumentList '/scannow' -WindowStyle Hidden -PassThru
    while (-not $p.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 300
    }
    if ($p.ExitCode -eq 0) { Log 'SFC finalizado: nenhuma violacao de integridade.' Green }
    else { Log "SFC finalizado (codigo $($p.ExitCode)). Detalhes em %windir%\Logs\CBS\CBS.log" Yellow }
}

function Benchmark-Disco {
    Log '=== Benchmark do disco (arquivo temporario de 512 MB) ===' Cyan
    $tamMB = 512
    $arq = Join-Path $env:TEMP 'otg_bench.tmp'
    $bloco = New-Object byte[] 1048576
    (New-Object System.Random).NextBytes($bloco)
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $fs = New-Object System.IO.FileStream($arq, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1048576, [System.IO.FileOptions]::WriteThrough)
        for ($i = 0; $i -lt $tamMB; $i++) {
            $fs.Write($bloco, 0, $bloco.Length)
            if ($i % 32 -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
        }
        $fs.Flush($true); $fs.Dispose(); $sw.Stop()
        $w = [math]::Round($tamMB / $sw.Elapsed.TotalSeconds)
        Log "Escrita sequencial: $w MB/s" Green

        $sw.Restart()
        $fs = New-Object System.IO.FileStream($arq, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None, 1048576, [System.IO.FileOptions]::SequentialScan)
        $lido = 0
        while (($n = $fs.Read($bloco, 0, $bloco.Length)) -gt 0) {
            $lido += $n
            if (($lido / 1048576) % 32 -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
        }
        $fs.Dispose(); $sw.Stop()
        $r = [math]::Round(($lido / 1MB) / $sw.Elapsed.TotalSeconds)
        Log "Leitura sequencial: $r MB/s (pode estar acima do real por causa do cache do Windows)" Green
    } catch {
        Log "Falha no benchmark: $($_.Exception.Message)" Red
    } finally {
        if (Test-Path $arq) { Remove-Item $arq -Force -ErrorAction SilentlyContinue }
    }
}

# ============================================================
#  RELATORIO ANTES x DEPOIS
# ============================================================
function Snapshot {
    $sysLetra = $env:SystemDrive.TrimEnd(':')
    $vol = Get-Volume -DriveLetter $sysLetra
    [pscustomobject]@{
        LivreGB   = [math]::Round($vol.SizeRemaining / 1GB, 1)
        RamPct    = Uso-RAM
        Processos = @(Get-Process).Count
        Latencia  = Medir-Latencia '1.1.1.1'
    }
}

function Mostrar-Relatorio {
    param($A, $D)
    $linhas = @()
    $linhas += '=== RELATORIO ANTES x DEPOIS ==='
    $linhas += ("Espaco livre no sistema: {0} GB -> {1} GB ({2} GB)" -f $A.LivreGB, $D.LivreGB, [math]::Round($D.LivreGB - $A.LivreGB, 1))
    $linhas += ("RAM em uso: {0}% -> {1}%" -f $A.RamPct, $D.RamPct)
    $linhas += ("Processos em execucao: {0} -> {1}" -f $A.Processos, $D.Processos)
    if ($null -ne $A.Latencia -and $null -ne $D.Latencia) {
        $linhas += ("Latencia (1.1.1.1): {0} ms -> {1} ms" -f $A.Latencia, $D.Latencia)
    }
    foreach ($l in $linhas) { Log $l Cyan }
    Add-Content -Path $script:RelatorioFile -Value ("`r`n--- {0} ---" -f (Get-Date -Format 'dd/MM/yyyy HH:mm')) -Encoding UTF8
    Add-Content -Path $script:RelatorioFile -Value $linhas -Encoding UTF8
}

# ============================================================
#  AGENDAMENTO
# ============================================================
function Agendar-Manutencao {
    Log '--- Agendando manutencao semanal ---' Cyan
    try {
        if ($script:EhExe) {
            # Copia o executavel para uma pasta fixa: a tarefa continua funcionando mesmo se o .exe for movido.
            $destinoExe = Join-Path $script:Pasta 'HS-Tech.exe'
            if ($script:CaminhoScript -ne $destinoExe) {
                try { Copy-Item -Path $script:CaminhoScript -Destination $destinoExe -Force -ErrorAction Stop }
                catch { if (-not (Test-Path $destinoExe)) { throw } }
            }
            $acao = New-ScheduledTaskAction -Execute $destinoExe -Argument '-Manutencao'
        } else {
            $acao = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"{0}`" -Manutencao" -f $script:CaminhoScript)
        }
        $gatilho = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '04:00'
        $princ = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
        $cfg = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName 'OtimizadorGamer-Manutencao' -Action $acao -Trigger $gatilho -Principal $princ -Settings $cfg -Force | Out-Null
        Log 'Agendado: todo domingo as 04:00 (limpeza + verificacao e otimizacao de disco). Se o PC estiver desligado, roda ao ligar.' Green
    } catch {
        Log "Falha ao agendar: $($_.Exception.Message)" Red
    }
}

function Remover-Agendamento {
    try {
        Unregister-ScheduledTask -TaskName 'OtimizadorGamer-Manutencao' -Confirm:$false -ErrorAction Stop
        Log 'Agendamento removido.' Green
    } catch {
        Log 'Nao havia agendamento para remover.' Yellow
    }
}

# ============================================================
#  MODO MANUTENCAO (sem interface, usado pela tarefa agendada)
# ============================================================
if ($Manutencao) {
    Log '=== Manutencao automatica semanal ===' Cyan
    Limpar-Temporarios
    Saude-Disco
    Verificar-Disco
    Otimizar-Disco
    Log 'Manutencao concluida.' Green
    exit
}

# ============================================================
#  MONITORAMENTO, ALERTAS E DETECCAO DE JOGOS
# ============================================================
function Monitorar-Console {
    Log '--- Monitoramento (10 amostras) ---' Cyan
    for ($i = 1; $i -le 10; $i++) {
        $g = Info-GPU
        $linha = "CPU: $(Uso-CPU)%  |  RAM: $(Uso-RAM)%"
        if ($null -ne $g.Uso) { $linha += "  |  GPU: $($g.Uso)% a $($g.Temp) C" }
        Log $linha
        for ($k = 0; $k -lt 10; $k++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
    }
}

function Alertar {
    param([string]$Chave, [string]$Msg)
    $agora = Get-Date
    if ($script:UltimoAlerta.ContainsKey($Chave) -and (($agora - $script:UltimoAlerta[$Chave]).TotalMinutes -lt 5)) { return }
    $script:UltimoAlerta[$Chave] = $agora
    Log "ALERTA: $Msg" Red
    $script:Tray.ShowBalloonTip(6000, 'Alerta de temperatura', $Msg, [System.Windows.Forms.ToolTipIcon]::Warning)
}

function Verificar-Jogos {
    if (-not $script:ChkAuto.Checked) { return }
    $rodando = $null
    foreach ($j in $script:Jogos) {
        if (Get-Process -Name $j -ErrorAction SilentlyContinue) { $rodando = $j; break }
    }
    if ($rodando -and -not $script:ModoJogoAtivo) {
        $script:ModoJogoAtivo = $true
        $script:JogoAtual = $rodando
        $script:LblStatusJogo.Text = "Jogo detectado: $rodando  (Modo Performance ATIVO)"
        $script:LblStatusJogo.ForeColor = (ParaCor $script:Paleta.Neon)
        Log "Jogo detectado: $rodando" Magenta
        Entrar-ModoPerformance
        Otimizar-ProcessoJogo $rodando
        $script:Tray.ShowBalloonTip(3000, 'HS-Tech | Central de Ferramentas', "Modo Performance ativado para $rodando", [System.Windows.Forms.ToolTipIcon]::Info)
    } elseif (-not $rodando -and $script:ModoJogoAtivo) {
        $script:ModoJogoAtivo = $false
        Log "Jogo encerrado: $($script:JogoAtual)" Magenta
        $script:JogoAtual = $null
        Sair-ModoPerformance
        $script:LblStatusJogo.Text = 'Aguardando um jogo da lista...'
        $script:LblStatusJogo.ForeColor = (ParaCor $script:Paleta.Mudo)
    }
}

function Nome-PlanoEnergia {
    try {
        $saida = (powercfg /getactivescheme | Out-String)
        $m = [regex]::Matches($saida, '\(([^\)]+)\)')
        if ($m.Count -gt 0) { return $m[$m.Count - 1].Groups[1].Value }
    } catch { }
    return '--'
}

function Definir-Barra {
    param($Card, $Pct)
    if ($null -eq $Pct) { $Card.Barra.Width = 0; return }
    $p = [math]::Max(0, [math]::Min(100, [int]$Pct))
    $Card.Barra.Width = [int]($Card.Trilho.Width * $p / 100)
    if ($p -ge 90) { $cor = '#FF5C7A' } elseif ($p -ge 75) { $cor = $script:Paleta.Amarelo } else { $cor = $Card.Cor }
    $Card.Barra.BackColor = (ParaCor $cor)
}

function Atualizar-Painel {
    $cpu = Uso-CPU
    $ram = Uso-RAM
    $gpu = Info-GPU
    $tc = Temp-CPU
    $script:TickN++
    if ($script:TickN % 20 -eq 1) { $script:TempDisco = Temp-Disco }
    if ($script:TickN % 10 -eq 1) { $script:LblPlano.Text = Nome-PlanoEnergia }
    Add-Hist $cpu $gpu.Uso $tc $gpu.Temp

    $script:CardCPU.Valor.Text = if ($null -ne $cpu) { "$cpu%" } else { 'N/D' }
    Definir-Barra $script:CardCPU $cpu
    $script:CardRAM.Valor.Text = if ($null -ne $ram) { "$ram%" } else { 'N/D' }
    Definir-Barra $script:CardRAM $ram
    $script:CardGPU.Valor.Text = if ($null -ne $gpu.Uso) { "$($gpu.Uso)%" } else { 'N/D' }
    Definir-Barra $script:CardGPU $gpu.Uso

    $tcTxt = if ($null -ne $tc) { "$tc" } else { '--' }
    $tgTxt = if ($null -ne $gpu.Temp) { "$($gpu.Temp)" } else { '--' }
    $script:CardTemp.Valor.Text = "$tcTxt / $tgTxt" + [char]0x00B0
    $maxT = $null
    if ($null -ne $tc) { $maxT = $tc }
    if ($null -ne $gpu.Temp -and ($null -eq $maxT -or $gpu.Temp -gt $maxT)) { $maxT = $gpu.Temp }
    Definir-Barra $script:CardTemp $maxT

    try {
        $v = Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':'))
        $script:CardDisco.Valor.Text = "{0} GB livres" -f [math]::Round($v.SizeRemaining / 1GB)
        Definir-Barra $script:CardDisco ([int](100 - (100 * $v.SizeRemaining / $v.Size)))
    } catch { }

    if ($script:ModoJogoAtivo) { $script:LblModoPerf.Text = "Ativo - $($script:JogoAtual)" }
    elseif ($script:PlanoAnterior) { $script:LblModoPerf.Text = 'Ativo (manual)' }
    else { $script:LblModoPerf.Text = 'Inativo' }
    $script:LblDeteccao.Text = if ($script:ChkAuto.Checked) { 'Ligada' } else { 'Desligada' }

    if ($script:ChkAlertas.Checked) {
        if ($null -ne $tc -and $tc -ge [int]$script:NumCpu.Value) { Alertar 'cpu' "CPU a $tc C (limite $([int]$script:NumCpu.Value) C)" }
        if ($null -ne $gpu.Temp -and $gpu.Temp -ge [int]$script:NumGpu.Value) { Alertar 'gpu' "GPU a $($gpu.Temp) C (limite $([int]$script:NumGpu.Value) C)" }
        if ($null -ne $script:TempDisco -and $script:TempDisco -ge [int]$script:NumDisco.Value) { Alertar 'disco' "Disco a $($script:TempDisco) C (limite $([int]$script:NumDisco.Value) C)" }
    }
}

function Salvar-Config {
    $script:Cfg = @{
        CpuMax = [int]$script:NumCpu.Value; GpuMax = [int]$script:NumGpu.Value; DiscoMax = [int]$script:NumDisco.Value
        Alertas = [bool]$script:ChkAlertas.Checked; Auto = [bool]$script:ChkAuto.Checked
    }
    $script:Cfg | ConvertTo-Json | Set-Content -Path $script:CfgFile -Encoding UTF8
}

function Salvar-Jogos {
    ConvertTo-Json -InputObject @($script:Jogos) | Set-Content -Path $script:JogosFile -Encoding UTF8
}

# ============================================================
#  ESTADO DO RELATORIO E DO HISTORICO
# ============================================================
$script:Achados = New-Object System.Collections.ArrayList
$script:Etapas = New-Object System.Collections.ArrayList
$script:UltimoAntes = $null
$script:UltimoDepois = $null
$script:ToastAnterior = $null
$script:Grafico = $null
$script:Hist = New-Object System.Collections.ArrayList
for ($ih = 0; $ih -lt 4; $ih++) { [void]$script:Hist.Add((New-Object System.Collections.ArrayList)) }
$script:HistHoras = New-Object System.Collections.ArrayList

function Adicionar-Achado {
    param([string]$Area, [string]$Texto, [string]$Nivel = 'ok')
    [void]$script:Achados.Add([pscustomobject]@{ Area = $Area; Texto = $Texto; Nivel = $Nivel })
}

function Registrar-Etapa {
    param([string]$Rotulo, [string]$Status)
    [void]$script:Etapas.Add([pscustomobject]@{ Rotulo = $Rotulo; Status = $Status })
}

function Rodar-Processo {
    # Executa um programa oculto, mantendo a janela responsiva; devolve codigo de saida e texto
    param([string]$Exe, [string]$Argumentos)
    $tmp = Join-Path $env:TEMP ('otg_' + [guid]::NewGuid().ToString('N') + '.txt')
    $p = Start-Process -FilePath $Exe -ArgumentList $Argumentos -WindowStyle Hidden -PassThru -RedirectStandardOutput $tmp -ErrorAction Stop
    while (-not $p.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 300
    }
    $saida = ''
    if (Test-Path $tmp) {
        $saida = [string](Get-Content $tmp -Raw -ErrorAction SilentlyContinue)
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    return @{ Codigo = $p.ExitCode; Saida = $saida }
}

function Tem-Bateria {
    try { return (@(Get-CimInstance Win32_Battery -ErrorAction Stop).Count -gt 0) } catch { return $false }
}

# ============================================================
#  NUCLEOS, PRIORIDADE DO JOGO E NOTIFICACOES
# ============================================================
function Info-CPU {
    $c = @(Get-CimInstance Win32_Processor)
    $fis = ($c | Measure-Object -Property NumberOfCores -Sum).Sum
    $log = ($c | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    return @{ Nome = ([string]$c[0].Name).Trim(); Fisicos = [int]$fis; Logicos = [int]$log; ClockMax = [int]$c[0].MaxClockSpeed }
}

function Ler-LimiteBoot {
    param([string]$Chave)
    $saida = bcdedit /enum '{current}' 2>$null
    foreach ($l in $saida) {
        if ($l -match ('^\s*' + $Chave + '\s+(\S+)')) { return $Matches[1] }
    }
    return $null
}

function Ler-IndiceAC {
    param([string]$Guid, [string]$Cfg)
    $saida = (powercfg /query $Guid SUB_PROCESSOR $Cfg 2>$null | Out-String)
    $m = [regex]::Matches($saida, '0x[0-9a-fA-F]{8}')
    if ($m.Count -ge 2) { return [Convert]::ToInt32($m[$m.Count - 2].Value.Substring(2), 16) }
    return $null
}

function Liberar-Nucleos {
    Log '--- Liberar todos os núcleos ---' Cyan
    $i = Info-CPU
    Log ("CPU: {0} | {1} núcleos físicos | {2} threads" -f $i.Nome, $i.Fisicos, $i.Logicos)
    if ($i.Logicos -gt $i.Fisicos) { Log 'Multithreading (SMT/Hyper-Threading) ativo.' Green }
    else { Log 'Sem multithreading (ou desativado na BIOS).' Yellow }

    $limite = Ler-LimiteBoot 'numproc'
    if ($null -ne $limite) {
        Log "Limite de processadores encontrado no boot ($limite). Removendo..." Yellow
        bcdedit /deletevalue numproc | Out-Null
        Log 'Limite removido. Reinicie o PC para aplicar.' Green
        Adicionar-Achado 'Núcleos' "Havia um limite de $limite processadores no boot; foi removido (reinicie para aplicar)." 'aviso'
    } else {
        Log 'Nenhum limite de núcleos no boot: o Windows já usa todos.' Green
        Adicionar-Achado 'Núcleos' "Todos os $($i.Logicos) threads estão liberados no boot." 'ok'
    }
    $um = Ler-LimiteBoot 'onecpu'
    if ($um -match '^(Yes|Sim)$') {
        bcdedit /deletevalue onecpu | Out-Null
        Log 'Modo de 1 processador removido do boot.' Green
    }

    $guid = Plano-Atual
    if ($guid) {
        foreach ($cfg in @('CPMINCORES', 'PROCTHROTTLEMIN')) {
            $ant = Ler-IndiceAC $guid $cfg
            if ($null -ne $ant) { Salvar-Backup -Chave "Energia|$guid|$cfg" -Valor $ant }
            powercfg /setacvalueindex $guid SUB_PROCESSOR $cfg 100 | Out-Null
        }
        powercfg /setactive $guid | Out-Null
        Log 'Core parking desativado e estado mínimo do processador em 100% (na tomada).' Green
        Adicionar-Achado 'Núcleos' 'Core parking desativado e estado mínimo do processador em 100% (na tomada).' 'ok'
    }
}

function Otimizar-ProcessoJogo {
    param([string]$Nome)
    $n = [Environment]::ProcessorCount
    foreach ($p in @(Get-Process -Name $Nome -ErrorAction SilentlyContinue)) {
        try {
            $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
            Log "Prioridade ALTA: $($p.ProcessName) (PID $($p.Id))" Green
        } catch {
            Log "Não foi possível mudar a prioridade (jogos com anti-cheat podem bloquear): $($_.Exception.Message)" Yellow
        }
        if ($n -le 62) {
            try {
                $p.ProcessorAffinity = [IntPtr]([int64]([math]::Pow(2, $n) - 1))
                Log "Afinidade: todos os $n threads liberados para o jogo."
            } catch { }
        }
    }
}

function Silenciar-Notificacoes {
    if ($null -ne $script:ToastAnterior) { return }
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'
    $atual = (Get-ItemProperty -Path $k -Name ToastEnabled -ErrorAction SilentlyContinue).ToastEnabled
    if ($null -eq $atual) { $atual = 1 }
    $script:ToastAnterior = [int]$atual
    Definir-Reg $k 'ToastEnabled' 0
    Log 'Notificações do Windows silenciadas durante o Modo Performance.' Green
}

function Restaurar-Notificacoes {
    if ($null -eq $script:ToastAnterior) { return }
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'
    try { Set-ItemProperty -Path $k -Name ToastEnabled -Value $script:ToastAnterior -Type DWord } catch { }
    $script:ToastAnterior = $null
    Log 'Notificações do Windows restauradas.' Green
}

# ============================================================
#  DIAGNOSTICOS
# ============================================================
function Diagnostico-PC {
    Log '--- Diagnóstico do hardware ---' Cyan
    try {
        $i = Info-CPU
        Log ("CPU: {0} | {1} núcleos / {2} threads" -f $i.Nome, $i.Fisicos, $i.Logicos) Green
        Adicionar-Achado 'CPU' ("{0}: {1} núcleos e {2} threads." -f $i.Nome, $i.Fisicos, $i.Logicos) 'info'
    } catch { Log 'Não foi possível ler a CPU.' Yellow }

    try {
        $mods = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $totalGB = [math]::Round((($mods | Measure-Object -Property Capacity -Sum).Sum) / 1GB)
        Log "RAM: $totalGB GB em $($mods.Count) pente(s)" Green
        Adicionar-Achado 'Memória' "$totalGB GB de RAM em $($mods.Count) pente(s)." 'info'
        foreach ($m in $mods) {
            $nom = [int]$m.Speed; $conf = [int]$m.ConfiguredClockSpeed
            if ($nom -gt 0 -and $conf -gt 0) {
                Log ("   Pente: {0} MHz (nominal {1} MHz)" -f $conf, $nom)
                if ($conf -lt $nom) {
                    Log '   Rodando abaixo da velocidade nominal: pode faltar ativar XMP/EXPO na BIOS.' Yellow
                    Adicionar-Achado 'Memória' "RAM a $conf MHz, abaixo dos $nom MHz nominais: verifique XMP/EXPO na BIOS." 'aviso'
                }
            }
        }
        if ($mods.Count -eq 1) {
            Log 'Apenas 1 pente de RAM (canal único). Dois pentes iguais rendem mais em jogos.' Yellow
            Adicionar-Achado 'Memória' 'Apenas 1 pente de RAM (canal único): dois pentes iguais (dual channel) rendem mais.' 'aviso'
        }
    } catch { Log 'Não foi possível ler a memória.' Yellow }

    try {
        foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
            if ($v.CurrentRefreshRate) {
                Log ("Vídeo: {0} | {1}x{2} a {3} Hz" -f $v.Name, $v.CurrentHorizontalResolution, $v.CurrentVerticalResolution, $v.CurrentRefreshRate)
                if ([int]$v.CurrentRefreshRate -le 60) {
                    Adicionar-Achado 'Vídeo' ("{0} a {1} Hz. Se o monitor for de 120/144/165 Hz, ajuste em Configurações > Tela > Tela avançada." -f $v.Name, $v.CurrentRefreshRate) 'aviso'
                } else {
                    Adicionar-Achado 'Vídeo' ("{0} a {1} Hz." -f $v.Name, $v.CurrentRefreshRate) 'ok'
                }
            }
        }
    } catch { }

    $hags = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
    if ($hags -eq 2) { Log 'HAGS (agendamento de GPU por hardware): ligado.' Green }
    elseif ($hags -eq 1) { Log 'HAGS (agendamento de GPU por hardware): desligado.' Gray }
}

function Diagnostico-Sistema {
    Log '--- Tempo ligado e reinício pendente ---' Cyan
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $dias = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
        if ($dias -gt 7) {
            Log "O PC está ligado há $dias dias sem reiniciar." Yellow
            Adicionar-Achado 'Sistema' "PC ligado há $dias dias sem reiniciar: reinicie (use Reiniciar, não Desligar)." 'aviso'
        } else {
            Log "Tempo desde a última inicialização: $dias dias." Green
            Adicionar-Achado 'Sistema' "Tempo desde a última inicialização: $dias dias." 'ok'
        }
    } catch { }
    $fast = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($fast -eq 1) {
        Log 'Inicialização rápida ativada: "Desligar" não reinicia o sistema de verdade; use "Reiniciar" para aplicar atualizações.' Gray
    }
    $motivos = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $motivos += 'componentes do Windows' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $motivos += 'Windows Update' }
    $pfro = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pfro) { $motivos += 'arquivos aguardando troca' }
    if ($motivos.Count -gt 0) {
        $txt = $motivos -join ', '
        Log "Reinício pendente ($txt)." Yellow
        Adicionar-Achado 'Sistema' "Reinício pendente ($txt): reinicie o PC para concluir." 'aviso'
    } else {
        Log 'Nenhum reinício pendente.' Green
        Adicionar-Achado 'Sistema' 'Nenhum reinício pendente.' 'ok'
    }
}

function Diagnostico-Eventos {
    Log '--- Erros do Windows (últimos 7 dias) ---' Cyan
    $desde = (Get-Date).AddDays(-7)
    $erros = @()
    try {
        $erros = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $desde } -MaxEvents 800 -ErrorAction Stop)
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
            Log "Não foi possível ler o log do sistema: $($_.Exception.Message)" Yellow
            Adicionar-Achado 'Eventos' 'Não foi possível ler o log de eventos do sistema.' 'aviso'
            return
        }
    }
    if ($erros.Count -eq 0) {
        Log 'Nenhum erro crítico no log do sistema nos últimos 7 dias.' Green
        Adicionar-Achado 'Eventos' 'Nenhum erro crítico no log do sistema (7 dias).' 'ok'
    } else {
        Log ("{0} eventos de erro ou críticos no log do sistema." -f $erros.Count) Yellow
        $grupos = @($erros | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 6)
        foreach ($g in $grupos) { Log ("   {0}: {1}x" -f $g.Name, $g.Count) }
        $kp = @($erros | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41 }).Count
        $disco = @($erros | Where-Object { $_.ProviderName -in @('disk', 'Ntfs', 'volmgr', 'stornvme', 'storahci') }).Count
        $whea = @($erros | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-WHEA-Logger' }).Count
        $video = @($erros | Where-Object { $_.ProviderName -in @('nvlddmkm', 'amdkmdag', 'amdwddmg', 'igfx', 'Display') }).Count
        if ($kp -gt 0) { Adicionar-Achado 'Eventos' "Reinicializações inesperadas: $kp (queda de energia, travamento ou superaquecimento)." 'erro' }
        if ($disco -gt 0) { Adicionar-Achado 'Eventos' "Erros de disco ou sistema de arquivos: $disco. Verifique a saúde do disco." 'erro' }
        if ($whea -gt 0) { Adicionar-Achado 'Eventos' "Erros de hardware (WHEA): $whea. Pode indicar CPU, RAM ou placa-mãe com problema." 'erro' }
        if ($video -gt 0) { Adicionar-Achado 'Eventos' "Falhas do driver de vídeo: $video. Atualize ou reinstale o driver." 'aviso' }
        if (($kp + $disco + $whea + $video) -eq 0) {
            Adicionar-Achado 'Eventos' ("{0} erros no log do sistema, sem padrão crítico de disco, hardware ou energia." -f $erros.Count) 'aviso'
        }
    }
    try {
        $app = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $desde } -MaxEvents 300 -ErrorAction Stop)
        if ($app.Count -gt 0) {
            $topo = @($app | ForEach-Object { [string]$_.Properties[0].Value } | Group-Object | Sort-Object Count -Descending | Select-Object -First 5)
            $resumo = ($topo | ForEach-Object { "{0} ({1}x)" -f $_.Name, $_.Count }) -join ', '
            Log "Aplicativos que travaram: $resumo" Yellow
            Adicionar-Achado 'Eventos' "Aplicativos que travaram nos últimos 7 dias: $resumo." 'aviso'
        }
    } catch { }
}

function Verificar-Drivers {
    param([bool]$Abrir = $true)
    Log '--- Drivers de vídeo ---' Cyan
    $url = $null
    try {
        foreach ($g in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
            $ver = [string]$g.DriverVersion
            $txt = $ver
            if ($g.Name -match 'NVIDIA' -and $ver -match '^\d+\.\d+\.(\d+)\.(\d+)$') {
                $num = $Matches[1] + $Matches[2]
                $num = $num.Substring($num.Length - 5)
                $txt = "{0}.{1} (versão NVIDIA)" -f $num.Substring(0, 3), $num.Substring(3)
            }
            $dataTxt = 'data desconhecida'
            $idade = $null
            if ($g.DriverDate) {
                $dataTxt = ([datetime]$g.DriverDate).ToString('dd/MM/yyyy')
                $idade = [int]((Get-Date) - [datetime]$g.DriverDate).TotalDays
            }
            Log ("{0}: driver {1}, de {2}" -f $g.Name, $txt, $dataTxt)
            if ($g.Name -match 'NVIDIA' -and -not $url) { $url = 'https://www.nvidia.com/Download/index.aspx' }
            elseif ($g.Name -match 'AMD|Radeon' -and -not $url) { $url = 'https://www.amd.com/en/support/download/drivers.html' }
            elseif ($g.Name -match 'Intel' -and -not $url) { $url = 'https://www.intel.com/content/www/us/en/download-center/home.html' }
            if ($null -ne $idade -and $idade -gt 180) {
                Log '   Driver com mais de 6 meses: vale verificar uma versão mais nova.' Yellow
                Adicionar-Achado 'Drivers' ("{0}: driver {1} de {2} (mais de 6 meses)." -f $g.Name, $txt, $dataTxt) 'aviso'
            } else {
                Adicionar-Achado 'Drivers' ("{0}: driver {1} de {2}." -f $g.Name, $txt, $dataTxt) 'ok'
            }
        }
    } catch { Log 'Não foi possível ler os drivers de vídeo.' Yellow; return }
    if ($Abrir -and $url) {
        if (Confirmar 'Abrir a página oficial de downloads do fabricante da placa de vídeo?') { Start-Process $url }
    }
}

function Saude-Bateria {
    param([bool]$Abrir = $true)
    Log '--- Saúde da bateria ---' Cyan

    # Alguns notebooks expõem Win32_Battery, mas não publicam as classes
    # BatteryFullChargedCapacity/BatteryStaticData em root\wmi.
    $baterias = @()
    try { $baterias = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop) } catch { }
    if ($baterias.Count -eq 0) {
        Log 'O Windows não conseguiu identificar uma bateria por WMI. Vou tentar gerar o relatório nativo.' Yellow
        Adicionar-Achado 'Bateria' 'Bateria não identificada pelo WMI; confira o relatório de bateria do Windows.' 'aviso'
    } else {
        $full = $null
        $proj = $null

        try {
            $dadosFull = @(Get-CimInstance -Namespace 'root/wmi' -ClassName BatteryFullChargedCapacity -ErrorAction Stop)
            if ($dadosFull.Count -gt 0) { $full = $dadosFull[0].FullChargedCapacity }
        } catch { }
        try {
            $dadosProj = @(Get-CimInstance -Namespace 'root/wmi' -ClassName BatteryStaticData -ErrorAction Stop)
            if ($dadosProj.Count -gt 0) { $proj = $dadosProj[0].DesignedCapacity }
        } catch { }

        # Fallback para drivers que publicam as capacidades diretamente em Win32_Battery.
        if (-not $full -and $baterias[0].FullChargeCapacity) { $full = $baterias[0].FullChargeCapacity }
        if (-not $proj -and $baterias[0].DesignCapacity) { $proj = $baterias[0].DesignCapacity }

        if ($full -and $proj -and [double]$full -gt 0 -and [double]$proj -gt 0) {
            $saude = [int][math]::Round(100 * [double]$full / [double]$proj)
            # Valores acima de 100% podem ocorrer por calibração; não são erro de leitura.
            Log ("Capacidade de carga: {0} mWh; capacidade de projeto: {1} mWh; saúde estimada: {2}%." -f $full, $proj, $saude)
            if ($saude -lt 60) { Adicionar-Achado 'Bateria' "Bateria com saúde estimada de $saude%: recomenda-se avaliar a troca." 'erro' }
            elseif ($saude -lt 80) { Adicionar-Achado 'Bateria' "Bateria com saúde estimada de $saude%: desgaste moderado." 'aviso' }
            else { Adicionar-Achado 'Bateria' "Saúde estimada da bateria: $saude%." 'ok' }
        } else {
            Log 'O Windows detectou a bateria, mas este driver não disponibiliza a capacidade de carga e/ou a capacidade de projeto via WMI.' Yellow
            Adicionar-Achado 'Bateria' 'Bateria detectada; capacidade de saúde não fornecida pelo driver. Consulte o relatório de bateria.' 'info'
        }
    }

    # O relatório nativo pode conter o histórico e as capacidades mesmo quando o WMI falha.
    try {
        $arq = Join-Path $script:Pasta 'bateria.html'
        $saidaPowerCfg = & powercfg.exe /batteryreport /output $arq 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path $arq)) {
            Log "Relatório completo de bateria do Windows: $arq" Green
            if ($Abrir) { Start-Process $arq }
        } else {
            Log ("O Windows não conseguiu gerar o relatório de bateria: {0}" -f ($saidaPowerCfg -join ' ')) Yellow
        }
    } catch {
        Log ("Falha ao gerar o relatório de bateria: {0}" -f $_.Exception.Message) Yellow
    }
}

function Diagnostico-Seguranca {
    Log '--- Segurança e atualizações ---' Cyan
    try {
        $avs = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { $_.displayName })
        if ($avs.Count -gt 0) {
            Log ("Antivírus registrado: {0}" -f ($avs -join ', ')) Green
            Adicionar-Achado 'Segurança' ("Antivírus registrado: {0}." -f ($avs -join ', ')) 'ok'
        } else {
            Log 'Nenhum antivírus registrado no Windows.' Red
            Adicionar-Achado 'Segurança' 'Nenhum antivírus registrado no Windows.' 'erro'
        }
    } catch { Log 'Não foi possível consultar o Centro de Segurança do Windows.' Yellow }
    try {
        $m = Get-MpComputerStatus -ErrorAction Stop
        if (-not $m.RealTimeProtectionEnabled) {
            Log 'Proteção em tempo real do Defender desativada.' Yellow
            Adicionar-Achado 'Segurança' 'Proteção em tempo real do Microsoft Defender desativada.' 'aviso'
        }
        $idade = [int]((Get-Date) - $m.AntivirusSignatureLastUpdated).TotalDays
        if ($idade -gt 7) {
            Log "Definições do Defender desatualizadas ($idade dias)." Yellow
            Adicionar-Achado 'Segurança' "Definições do Defender desatualizadas há $idade dias." 'aviso'
        } else {
            Log "Definições do Defender atualizadas ($idade dias)." Green
        }
    } catch { }
    try {
        $ultimo = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($ultimo) {
            $d = [int]((Get-Date) - $ultimo.InstalledOn).TotalDays
            if ($d -gt 60) {
                Log "Última atualização do Windows instalada há $d dias." Yellow
                Adicionar-Achado 'Atualizações' "Última atualização do Windows instalada há $d dias: verifique o Windows Update." 'aviso'
            } else {
                Log "Última atualização do Windows instalada há $d dias." Green
                Adicionar-Achado 'Atualizações' "Última atualização do Windows instalada há $d dias." 'ok'
            }
        }
    } catch { }
    $wu = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    if ($wu -and $wu.StartType -eq 'Disabled') {
        Log 'O serviço do Windows Update está desativado.' Yellow
        Adicionar-Achado 'Atualizações' 'O serviço do Windows Update está desativado.' 'aviso'
    }
}

function Escanear-Defender {
    Log '--- Verificação rápida do Microsoft Defender ---' Cyan
    if (-not (Confirmar 'Executar uma verificação rápida do Microsoft Defender? Pode levar alguns minutos.')) { Log 'Cancelado.' Yellow; return }
    try {
        [void](Rodar-EmJob { param($x) Start-MpScan -ScanType QuickScan } @(0))
        Log 'Verificação rápida concluída.' Green
        Adicionar-Achado 'Segurança' 'Verificação rápida do Microsoft Defender concluída.' 'ok'
    } catch {
        Log "Não foi possível executar a verificação: $($_.Exception.Message)" Yellow
    }
}

function Testar-Memoria {
    Log '--- Teste de memória do Windows ---' Cyan
    if (Confirmar "O Diagnóstico de Memória do Windows vai oferecer reiniciar o PC para testar a RAM.`n`nSalve seus trabalhos antes. Abrir agora?") {
        Start-Process mdsched.exe
        Log 'Diagnóstico de Memória do Windows aberto.' Green
    } else { Log 'Cancelado.' Yellow }
}

function Teste-Estabilidade {
    param([int]$Segundos = 60)
    Log "--- Teste de estabilidade da CPU ($Segundos s) ---" Cyan
    if (-not (Confirmar "O teste leva a CPU a 100% por $Segundos segundos e pode esquentar o PC.`n`nEm notebook, conecte o carregador. Continuar?")) { Log 'Cancelado.' Yellow; return }
    $n = [Environment]::ProcessorCount
    $jobs = @()
    $maxT = $null; $somaCpu = 0; $amostras = 0; $perfMin = $null; $perfMax = $null; $abortou = $false
    try {
        for ($i = 0; $i -lt $n; $i++) {
            $jobs += Start-Job -ScriptBlock { $x = 1.0; while ($true) { $x = [math]::Sqrt($x + 12345.678) } }
        }
        Log "Estressando $n threads..."
        $fim = (Get-Date).AddSeconds($Segundos)
        while ((Get-Date) -lt $fim) {
            for ($k = 0; $k -lt 20; $k++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
            $cpu = Uso-CPU
            $tc = Temp-CPU
            $perf = $null
            try { $perf = [int](Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorPerformance } catch { }
            if ($null -ne $cpu) { $somaCpu += $cpu; $amostras++ }
            if ($null -ne $tc -and ($null -eq $maxT -or $tc -gt $maxT)) { $maxT = $tc }
            if ($null -ne $perf) {
                if ($null -eq $perfMin -or $perf -lt $perfMin) { $perfMin = $perf }
                if ($null -eq $perfMax -or $perf -gt $perfMax) { $perfMax = $perf }
            }
            $linha = "CPU {0}%" -f $cpu
            if ($null -ne $tc) { $linha += " | temp $tc C" }
            if ($null -ne $perf) { $linha += " | desempenho $perf%" }
            Log $linha
            if ($null -ne $tc -and $tc -ge 95) {
                $abortou = $true
                Log 'Temperatura crítica (95 C). Teste interrompido por segurança.' Red
                break
            }
        }
    } finally {
        foreach ($j in $jobs) { Stop-Job $j -ErrorAction SilentlyContinue; Remove-Job $j -Force -ErrorAction SilentlyContinue }
    }
    $media = 0
    if ($amostras -gt 0) { $media = [int]($somaCpu / $amostras) }
    Log "Teste finalizado. Uso médio da CPU: $media%." Green
    if ($abortou) {
        Adicionar-Achado 'Estabilidade' 'Teste de estresse interrompido: a CPU atingiu 95 C. Verifique cooler, pasta térmica e ventilação.' 'erro'
    } elseif ($null -ne $maxT) {
        if ($maxT -ge 90) { Adicionar-Achado 'Estabilidade' "Teste de estresse: pico de $maxT C (alto). Verifique cooler e pasta térmica." 'erro' }
        elseif ($maxT -ge 80) { Adicionar-Achado 'Estabilidade' "Teste de estresse: pico de $maxT C (elevado, mas aceitável)." 'aviso' }
        else { Adicionar-Achado 'Estabilidade' "Teste de estresse de $Segundos s concluído sem travar; pico de $maxT C." 'ok' }
    } else {
        Adicionar-Achado 'Estabilidade' "Teste de estresse de $Segundos s concluído sem travar (temperatura da CPU indisponível neste PC)." 'ok'
    }
    if ($null -ne $perfMin -and $null -ne $perfMax -and $perfMax -gt 0 -and $perfMin -lt ($perfMax * 0.7)) {
        Log "A frequência caiu para $perfMin% (pico $perfMax%): possível limitação por calor ou energia." Yellow
        Adicionar-Achado 'Estabilidade' "Durante o estresse a frequência caiu de $perfMax% para $perfMin%: possível limitação por temperatura ou energia." 'aviso'
    }
}

function Diagnostico-Completo {
    Log '=== Diagnóstico completo ===' Cyan
    $script:Achados.Clear()
    $passos = @(
        @('Hardware', { Diagnostico-PC }),
        @('Tempo ligado e reinício', { Diagnostico-Sistema }),
        @('Erros do Windows', { Diagnostico-Eventos }),
        @('Drivers de vídeo', { Verificar-Drivers $false }),
        @('Dispositivos com problema', { Verificar-DispositivosProblema }),
        @('Segurança e atualizações', { Diagnostico-Seguranca }),
        @('Bateria', { Saude-Bateria $false }),
        @('Saúde dos discos', { Saude-Disco })
    )
    $n = 0
    foreach ($p in $passos) {
        $n++
        Passo $n $passos.Count $p[0]
        try { & $p[1] } catch { Log "Falha em $($p[0]): $($_.Exception.Message)" Yellow }
    }
    $erros = @($script:Achados | Where-Object { $_.Nivel -eq 'erro' }).Count
    $avisos = @($script:Achados | Where-Object { $_.Nivel -eq 'aviso' }).Count
    Log ("Diagnóstico concluído: {0} problema(s), {1} ponto(s) de atenção." -f $erros, $avisos) Green
    Relatorio-HTML-Agora
}

# ============================================================
#  REPARO DO WINDOWS (DISM + SFC)
# ============================================================
function Reparar-Imagem {
    Log '--- DISM: reparo da imagem do Windows ---' Cyan
    Log 'Executando DISM /RestoreHealth (precisa de internet e pode levar vários minutos)...'
    try {
        $r = Rodar-Processo 'dism.exe' '/Online /Cleanup-Image /RestoreHealth'
        if ($r.Codigo -eq 0) {
            Log 'DISM concluído: imagem do Windows verificada e reparada quando necessário.' Green
            Adicionar-Achado 'Reparo' 'DISM RestoreHealth concluído sem erros.' 'ok'
        } else {
            Log ("DISM terminou com o código {0}. Confira a conexão e o arquivo C:\Windows\Logs\DISM\dism.log" -f $r.Codigo) Yellow
            Adicionar-Achado 'Reparo' ("DISM RestoreHealth terminou com o código {0}." -f $r.Codigo) 'aviso'
        }
    } catch { Log "Não foi possível executar o DISM: $($_.Exception.Message)" Red }
}

function Reparo-Completo {
    if (-not (Confirmar "O reparo completo executa o DISM e depois o SFC.`n`nPode levar de 20 a 40 minutos e precisa de internet. Continuar?")) { Log 'Cancelado.' Yellow; return }
    Passo 1 2 'DISM RestoreHealth'
    Reparar-Imagem
    Passo 2 2 'SFC /scannow'
    Verificar-ArquivosWindows
}

# ============================================================
#  LIMPEZA DE NAVEGADORES
# ============================================================
function Limpar-Navegadores {
    Log '--- Limpeza de cache dos navegadores ---' Cyan
    $abertos = @(Get-Process -Name chrome, msedge, firefox, brave -ErrorAction SilentlyContinue)
    if ($abertos.Count -gt 0) {
        if (-not (Confirmar "Há navegadores abertos. Para limpar o cache eles precisam ser fechados.`n`nAs abas abertas serão perdidas; senhas, favoritos e histórico não são afetados. Fechar e continuar?")) {
            Log 'Cancelado.' Yellow; return
        }
        $abertos | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }
    $alvos = New-Object System.Collections.ArrayList
    foreach ($base in @("$env:LOCALAPPDATA\Google\Chrome\User Data", "$env:LOCALAPPDATA\Microsoft\Edge\User Data", "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data")) {
        if (Test-Path $base) {
            foreach ($perfil in @(Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
                foreach ($sub in @('Cache', 'Code Cache', 'GPUCache')) {
                    $c = Join-Path $perfil.FullName $sub
                    if (Test-Path $c) { [void]$alvos.Add($c) }
                }
            }
        }
    }
    $ff = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path $ff) {
        foreach ($perfil in @(Get-ChildItem -Path $ff -Directory -ErrorAction SilentlyContinue)) {
            $c = Join-Path $perfil.FullName 'cache2'
            if (Test-Path $c) { [void]$alvos.Add($c) }
        }
    }
    if ($alvos.Count -eq 0) { Log 'Nenhum cache de navegador encontrado.' Gray; return }
    $total = 0
    foreach ($c in $alvos) {
        $soma = (Get-ChildItem -Path $c -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($soma) { $total += $soma }
        Get-ChildItem -Path $c -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    $mb = [math]::Round($total / 1MB)
    Log "Cache dos navegadores limpo: aproximadamente $mb MB (senhas e favoritos preservados)." Green
    Adicionar-Achado 'Limpeza' "Cache de navegadores limpo: cerca de $mb MB liberados." 'ok'
}

# ============================================================
#  INICIALIZACAO: ATIVAR / DESATIVAR APPS
# ============================================================
function Obter-ItensInicializacao {
    $fontes = @(
        @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Aprov = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Rot = 'Usuário' },
        @{ Run = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Aprov = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Rot = 'Sistema' },
        @{ Run = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Aprov = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Rot = 'Sistema (32 bits)' }
    )
    $internos = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
    $lista = New-Object System.Collections.ArrayList
    foreach ($f in $fontes) {
        if (-not (Test-Path $f.Run)) { continue }
        $itens = Get-ItemProperty -Path $f.Run
        $aprov = $null
        if (Test-Path $f.Aprov) { $aprov = Get-ItemProperty -Path $f.Aprov }
        foreach ($p in $itens.PSObject.Properties) {
            if ($internos -contains $p.Name) { continue }
            $desativado = $false
            if ($aprov) {
                $ap = $aprov.PSObject.Properties[$p.Name]
                if ($ap -and ($ap.Value -is [byte[]]) -and $ap.Value.Length -gt 0) { $desativado = (($ap.Value[0] -band 1) -eq 1) }
            }
            [void]$lista.Add([pscustomobject]@{ Nome = $p.Name; Aprov = $f.Aprov; Rot = $f.Rot; Desativado = $desativado })
        }
    }
    return $lista
}

function Gerenciar-Inicializacao {
    Log '--- Apps de inicialização: ativar ou desativar ---' Cyan
    $itensReg = @(Obter-ItensInicializacao)
    if ($itensReg.Count -eq 0) { Log 'Nenhum app de inicialização encontrado no registro.' Yellow; return }
    $lista = @()
    for ($i = 0; $i -lt $itensReg.Count; $i++) {
        $lista += [pscustomobject]@{ Id = [string]$i; Rotulo = ("[{0}] {1}" -f $itensReg[$i].Rot, $itensReg[$i].Nome); Marcado = [bool]$itensReg[$i].Desativado }
    }
    $r = Mostrar-ListaMarcavel 'Apps de inicialização' "Marque os apps que deseja DESATIVAR na inicialização do Windows.`nDesmarque para reativar. Nada é apagado: você pode reverter quando quiser." $lista 'APLICAR'
    if ($null -eq $r) { Log 'Cancelado.' Yellow; return }
    $alt = 0
    for ($i = 0; $i -lt $itensReg.Count; $i++) {
        $marcado = [bool]$r[[string]$i]
        if ($marcado -ne [bool]$itensReg[$i].Desativado) {
            $it = $itensReg[$i]
            try {
                if (-not (Test-Path $it.Aprov)) { New-Item -Path $it.Aprov -Force | Out-Null }
                if ($marcado) { $bytes = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) } else { $bytes = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
                Set-ItemProperty -Path $it.Aprov -Name $it.Nome -Value $bytes -Type Binary -ErrorAction Stop
                if ($marcado) { Log "Desativado na inicialização: $($it.Nome)" Green } else { Log "Reativado na inicialização: $($it.Nome)" Green }
                $alt++
            } catch { Log "Não foi possível alterar $($it.Nome): $($_.Exception.Message)" Yellow }
        }
    }
    if ($alt -eq 0) { Log 'Nenhuma alteração.' Gray }
    else { Adicionar-Achado 'Inicialização' "$alt app(s) de inicialização ativados ou desativados." 'ok' }
}

# ============================================================
#  CAIXA DE SELECAO (usada na manutencao e na inicializacao)
# ============================================================
function Mostrar-ListaMarcavel {
    param([string]$Titulo, [string]$Aviso, $Itens, [string]$TextoOk = 'APLICAR')
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Titulo
    $dlg.Size = New-Object System.Drawing.Size(580, 620)
    $dlg.StartPosition = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = (ParaCor $script:Paleta.Fundo)
    $dlg.ForeColor = (ParaCor $script:Paleta.Texto)
    $dlg.Font = (Fonte 'Segoe UI' 9.5 'Regular')

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Aviso
    $lbl.AutoSize = $false
    $lbl.Location = New-Object System.Drawing.Point(20, 16)
    $lbl.Size = New-Object System.Drawing.Size(530, 46)
    $lbl.ForeColor = (ParaCor $script:Paleta.Mudo)
    $dlg.Controls.Add($lbl)

    $script:DlgLista = New-Object System.Windows.Forms.CheckedListBox
    $script:DlgLista.Location = New-Object System.Drawing.Point(20, 68)
    $script:DlgLista.Size = New-Object System.Drawing.Size(530, 410)
    $script:DlgLista.CheckOnClick = $true
    $script:DlgLista.BackColor = (ParaCor $script:Paleta.Painel)
    $script:DlgLista.ForeColor = (ParaCor $script:Paleta.Texto)
    $script:DlgLista.BorderStyle = 'FixedSingle'
    $script:DlgLista.HorizontalScrollbar = $true
    $script:DlgLista.Font = (Fonte 'Segoe UI' 10 'Regular')
    for ($i = 0; $i -lt $Itens.Count; $i++) {
        $idx = $script:DlgLista.Items.Add([string]$Itens[$i].Rotulo)
        $script:DlgLista.SetItemChecked($idx, [bool]$Itens[$i].Marcado)
    }
    $dlg.Controls.Add($script:DlgLista)

    $btnTodos = Novo-BotaoPequeno 'MARCAR TUDO' {
        for ($k = 0; $k -lt $script:DlgLista.Items.Count; $k++) { $script:DlgLista.SetItemChecked($k, $true) }
    } $script:Paleta.Cian 130 34
    $btnTodos.Location = New-Object System.Drawing.Point(20, 490)
    $dlg.Controls.Add($btnTodos)

    $btnNenhum = Novo-BotaoPequeno 'DESMARCAR' {
        for ($k = 0; $k -lt $script:DlgLista.Items.Count; $k++) { $script:DlgLista.SetItemChecked($k, $false) }
    } $script:Paleta.Cian 130 34
    $btnNenhum.Location = New-Object System.Drawing.Point(160, 490)
    $dlg.Controls.Add($btnNenhum)

    $ok = Novo-BotaoPequeno $TextoOk { } $script:Paleta.Neon 130 36
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(290, 536)
    $dlg.Controls.Add($ok)

    $cancelar = Novo-BotaoPequeno 'CANCELAR' { } $script:Paleta.Rosa 130 36
    $cancelar.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelar.Location = New-Object System.Drawing.Point(430, 536)
    $dlg.Controls.Add($cancelar)
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancelar

    $mapa = $null
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $mapa = @{}
        for ($i = 0; $i -lt $Itens.Count; $i++) { $mapa[[string]$Itens[$i].Id] = $script:DlgLista.GetItemChecked($i) }
    }
    $dlg.Dispose()
    return $mapa
}

# ============================================================
#  MANUTENCAO RECOMENDADA (com escolha das etapas)
# ============================================================
function Obter-Etapas {
    $nb = Tem-Bateria
    $lista = @()
    $lista += [pscustomobject]@{ Id = 'restauracao'; Rotulo = 'Criar ponto de restauração'; Marcado = $true; Acao = { Criar-PontoRestauracao } }
    $lista += [pscustomobject]@{ Id = 'temporarios'; Rotulo = 'Limpar arquivos temporários'; Marcado = $true; Acao = { Limpar-Temporarios -SemConfirmar } }
    $lista += [pscustomobject]@{ Id = 'limpezaprofunda'; Rotulo = 'Limpeza profunda do Windows (você escolhe o que apagar)'; Marcado = $false; Acao = { Limpeza-Profunda } }
    $lista += [pscustomobject]@{ Id = 'navegadores'; Rotulo = 'Limpar cache dos navegadores (fecha os navegadores)'; Marcado = $true; Acao = { Limpar-Navegadores } }
    $lista += [pscustomobject]@{ Id = 'energia'; Rotulo = 'Ativar o plano Alto desempenho (aumenta o consumo)'; Marcado = (-not $nb); Acao = { Ajustar-Energia } }
    $lista += [pscustomobject]@{ Id = 'energiamax'; Rotulo = 'Ativar o plano Desempenho máximo (maior consumo e calor)'; Marcado = $false; Acao = { Ativar-DesempenhoMaximo } }
    $lista += [pscustomobject]@{ Id = 'modojogo'; Rotulo = 'Ativar o Modo Jogo do Windows'; Marcado = $true; Acao = { Ajustar-ModoJogo } }
    $lista += [pscustomobject]@{ Id = 'nucleos'; Rotulo = 'Liberar todos os núcleos e desativar o core parking'; Marcado = $true; Acao = { Liberar-Nucleos } }
    $lista += [pscustomobject]@{ Id = 'rede'; Rotulo = 'Limpar o DNS e testar a rede'; Marcado = $true; Acao = { Otimizar-Rede } }
    $lista += [pscustomobject]@{ Id = 'saude'; Rotulo = 'Verificar a saúde dos discos'; Marcado = $true; Acao = { Saude-Disco } }
    $lista += [pscustomobject]@{ Id = 'verificar'; Rotulo = 'Verificar erros do sistema de arquivos'; Marcado = $true; Acao = { Verificar-Disco } }
    $lista += [pscustomobject]@{ Id = 'otimizar'; Rotulo = 'Otimizar discos (TRIM em SSD, desfragmentar HDD)'; Marcado = $true; Acao = { Otimizar-Disco } }
    $lista += [pscustomobject]@{ Id = 'hardware'; Rotulo = 'Diagnóstico do hardware, tempo ligado e reinício pendente'; Marcado = $true; Acao = { Diagnostico-PC; Diagnostico-Sistema } }
    $lista += [pscustomobject]@{ Id = 'eventos'; Rotulo = 'Analisar erros do Windows (últimos 7 dias)'; Marcado = $true; Acao = { Diagnostico-Eventos } }
    $lista += [pscustomobject]@{ Id = 'drivers'; Rotulo = 'Verificar os drivers de vídeo'; Marcado = $true; Acao = { Verificar-Drivers $false } }
    $lista += [pscustomobject]@{ Id = 'dispositivos'; Rotulo = 'Procurar dispositivos com problema de driver'; Marcado = $true; Acao = { Verificar-DispositivosProblema } }
    $lista += [pscustomobject]@{ Id = 'atualizardrivers'; Rotulo = 'Procurar e instalar atualizações de drivers (você escolhe quais)'; Marcado = $false; Acao = { Atualizar-Drivers } }
    $lista += [pscustomobject]@{ Id = 'seguranca'; Rotulo = 'Verificar antivírus e atualizações'; Marcado = $true; Acao = { Diagnostico-Seguranca } }
    if ($nb) {
        $lista += [pscustomobject]@{ Id = 'bateria'; Rotulo = 'Verificar a saúde da bateria'; Marcado = $true; Acao = { Saude-Bateria $false } }
    }
    return $lista
}

function Executar-Tudo {
    $etapas = @(Obter-Etapas)
    $itens = @($etapas | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Rotulo = $_.Rotulo; Marcado = $_.Marcado } })
    $escolha = Mostrar-ListaMarcavel 'Manutenção recomendada' "Revise o que será feito neste PC e desmarque o que não desejar.`nCada ajuste que altera o sistema tem backup e pode ser desfeito." $itens 'EXECUTAR'
    if ($null -eq $escolha) { Log 'Manutenção cancelada.' Yellow; return }
    $selecionadas = @($etapas | Where-Object { $escolha[[string]$_.Id] })
    if ($selecionadas.Count -eq 0) { Log 'Nenhuma etapa selecionada.' Yellow; return }

    $script:Achados.Clear()
    $script:Etapas.Clear()
    $antes = Snapshot
    $total = $selecionadas.Count
    $n = 0
    foreach ($et in $selecionadas) {
        $n++
        Passo $n $total $et.Rotulo
        try { & $et.Acao; Registrar-Etapa $et.Rotulo 'Concluída' }
        catch { Log "Falha em '$($et.Rotulo)': $($_.Exception.Message)" Yellow; Registrar-Etapa $et.Rotulo 'Falhou' }
    }
    foreach ($et in $etapas) {
        if (-not $escolha[[string]$et.Id]) { Registrar-Etapa $et.Rotulo 'Não selecionada' }
    }
    $depois = Snapshot
    $script:UltimoAntes = $antes
    $script:UltimoDepois = $depois
    Mostrar-Relatorio $antes $depois
    Definir-Progresso 100
    Log 'Manutenção finalizada. Recomenda-se reiniciar o PC.' Green
    Relatorio-HTML-Agora
}

# ============================================================
#  RELATORIO HTML
# ============================================================
function HtmlEnc {
    param($Texto)
    return [System.Net.WebUtility]::HtmlEncode([string]$Texto)
}

function Montar-HTML {
    param($D)
    $css = @'
body{font-family:"Segoe UI",Arial,sans-serif;margin:0;background:#f3f6fa;color:#1b2430}
.topo{background:#08172A;color:#fff;padding:24px 40px;border-bottom:4px solid #00E6A0;display:flex;justify-content:space-between;align-items:center;gap:24px}
.topo h1{margin:0;font-size:26px;font-weight:600}
.topo p{margin:6px 0 0;color:#91A8C2;font-size:14px}
.topo img{max-height:72px;max-width:220px;background:#fff;padding:6px;border-radius:6px}
.obs{background:#fff;border:1px solid #d5deea;padding:12px 16px;white-space:pre-wrap;font-size:14px;line-height:1.6}
.wrap{max-width:980px;margin:24px auto;padding:0 20px}
h2{font-size:14px;letter-spacing:.06em;text-transform:uppercase;color:#0b5c9e;border-bottom:1px solid #d5deea;padding-bottom:6px;margin:30px 0 12px}
.cards{display:flex;gap:12px;flex-wrap:wrap}
.card{flex:1;min-width:150px;background:#fff;border:1px solid #d5deea;border-radius:8px;padding:14px 16px}
.card b{display:block;font-size:24px}
.card span{font-size:12px;color:#5b6b7e}
table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #d5deea;font-size:14px}
th,td{padding:8px 12px;text-align:left;border-bottom:1px solid #e6edf5;vertical-align:top}
th{background:#eef3f9;font-size:12px;text-transform:uppercase;color:#5b6b7e}
.b{display:inline-block;padding:2px 9px;border-radius:10px;font-size:12px;font-weight:600;white-space:nowrap}
.ok{background:#d9f7ec;color:#0a7a52}.aviso{background:#fff0cf;color:#9a6200}.erro{background:#ffe0e5;color:#b3243e}.info{background:#e1effc;color:#165a99}
ul{background:#fff;border:1px solid #d5deea;margin:0;padding:12px 12px 12px 32px;font-size:14px;line-height:1.6}
.assin{margin-top:40px;display:flex;gap:40px}
.assin div{flex:1;border-top:1px solid #8a99ab;padding-top:6px;font-size:12px;color:#5b6b7e}
.rod{margin:36px 0 20px;color:#5b6b7e;font-size:12px;text-align:center}
@media print{body{background:#fff}.topo{-webkit-print-color-adjust:exact;print-color-adjust:exact}}
'@
    $rotulos = @{ ok = 'OK'; aviso = 'Atenção'; erro = 'Problema'; info = 'Info' }
    $ordem = @{ erro = 0; aviso = 1; ok = 2; info = 3 }
    $achados = @($D.Achados)
    $nOk = @($achados | Where-Object { $_.Nivel -eq 'ok' }).Count
    $nAv = @($achados | Where-Object { $_.Nivel -eq 'aviso' }).Count
    $nEr = @($achados | Where-Object { $_.Nivel -eq 'erro' }).Count
    if ($nEr -gt 0) { $situacao = 'Requer atenção'; $cls = 'erro' }
    elseif ($nAv -gt 0) { $situacao = 'Bom, com observações'; $cls = 'aviso' }
    else { $situacao = 'Tudo certo'; $cls = 'ok' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Relatório de otimização e manutenção</title><style>')
    [void]$sb.AppendLine($css)
    [void]$sb.AppendLine('</style></head><body>')
    $partesEmp = @()
    if ($D.Empresa) { $partesEmp += (HtmlEnc $D.Empresa) }
    if ($D.ContatoEmpresa) { $partesEmp += (HtmlEnc $D.ContatoEmpresa) }
    $linhaEmpresa = ''
    if ($partesEmp.Count -gt 0) { $linhaEmpresa = '<p>' + ($partesEmp -join ' &middot; ') + '</p>' }
    $logoHtml = ''
    if ($D.LogoUri) { $logoHtml = '<img alt="Logo" src="' + $D.LogoUri + '">' }
    [void]$sb.AppendLine('<div class="topo"><div><h1>Relatório de otimização e manutenção</h1><p>' + (HtmlEnc $D.Data) + ' &middot; ' + (HtmlEnc $D.Computador) + '</p>' + $linhaEmpresa + '</div>' + $logoHtml + '</div><div class="wrap">')

    [void]$sb.AppendLine('<h2>Resumo</h2><div class="cards">')
    [void]$sb.AppendLine('<div class="card"><span>Situação geral</span><b><span class="b ' + $cls + '">' + (HtmlEnc $situacao) + '</span></b></div>')
    [void]$sb.AppendLine('<div class="card"><span>Itens OK</span><b>' + $nOk + '</b></div>')
    [void]$sb.AppendLine('<div class="card"><span>Pontos de atenção</span><b>' + $nAv + '</b></div>')
    [void]$sb.AppendLine('<div class="card"><span>Problemas</span><b>' + $nEr + '</b></div></div>')

    [void]$sb.AppendLine('<h2>Dados do atendimento</h2><table>')
    [void]$sb.AppendLine('<tr><th>Computador</th><td>' + (HtmlEnc $D.Computador) + '</td><th>Usuário</th><td>' + (HtmlEnc $D.Usuario) + '</td></tr>')
    [void]$sb.AppendLine('<tr><th>Windows</th><td>' + (HtmlEnc $D.Windows) + '</td><th>Plano de energia</th><td>' + (HtmlEnc $D.Plano) + '</td></tr>')
    if ($D.Cliente -or $D.Equipamento) {
        [void]$sb.AppendLine('<tr><th>Cliente</th><td>' + (HtmlEnc $D.Cliente) + '</td><th>Equipamento</th><td>' + (HtmlEnc $D.Equipamento) + '</td></tr>')
    }
    if ($D.Tecnico) {
        [void]$sb.AppendLine('<tr><th>Técnico responsável</th><td colspan="3">' + (HtmlEnc $D.Tecnico) + '</td></tr>')
    }
    [void]$sb.AppendLine('</table>')

    [void]$sb.AppendLine('<h2>Hardware</h2><table>')
    [void]$sb.AppendLine('<tr><th>Processador</th><td>' + (HtmlEnc $D.Cpu) + '</td></tr>')
    [void]$sb.AppendLine('<tr><th>Memória RAM</th><td>' + (HtmlEnc $D.Ram) + '</td></tr>')
    foreach ($g in @($D.Gpus)) { [void]$sb.AppendLine('<tr><th>Placa de vídeo</th><td>' + (HtmlEnc $g) + '</td></tr>') }
    foreach ($dk in @($D.Discos)) { [void]$sb.AppendLine('<tr><th>Disco</th><td>' + (HtmlEnc $dk) + '</td></tr>') }
    [void]$sb.AppendLine('</table>')

    if ($null -ne $D.Antes -and $null -ne $D.Depois) {
        [void]$sb.AppendLine('<h2>Antes e depois</h2><table><tr><th>Indicador</th><th>Antes</th><th>Depois</th><th>Variação</th></tr>')
        $dl = [math]::Round($D.Depois.LivreGB - $D.Antes.LivreGB, 1)
        [void]$sb.AppendLine('<tr><td>Espaço livre no sistema (GB)</td><td>' + $D.Antes.LivreGB + '</td><td>' + $D.Depois.LivreGB + '</td><td>' + $dl + '</td></tr>')
        [void]$sb.AppendLine('<tr><td>RAM em uso (%)</td><td>' + $D.Antes.RamPct + '</td><td>' + $D.Depois.RamPct + '</td><td>' + ($D.Depois.RamPct - $D.Antes.RamPct) + '</td></tr>')
        [void]$sb.AppendLine('<tr><td>Processos em execução</td><td>' + $D.Antes.Processos + '</td><td>' + $D.Depois.Processos + '</td><td>' + ($D.Depois.Processos - $D.Antes.Processos) + '</td></tr>')
        if ($null -ne $D.Antes.Latencia -and $null -ne $D.Depois.Latencia) {
            [void]$sb.AppendLine('<tr><td>Latência para 1.1.1.1 (ms)</td><td>' + $D.Antes.Latencia + '</td><td>' + $D.Depois.Latencia + '</td><td>' + ($D.Depois.Latencia - $D.Antes.Latencia) + '</td></tr>')
        }
        [void]$sb.AppendLine('</table>')
    }

    $etapas = @($D.Etapas)
    if ($etapas.Count -gt 0) {
        [void]$sb.AppendLine('<h2>Etapas da manutenção</h2><table><tr><th>Etapa</th><th>Situação</th></tr>')
        foreach ($e in $etapas) {
            $c = 'info'
            if ($e.Status -eq 'Concluída') { $c = 'ok' } elseif ($e.Status -eq 'Falhou') { $c = 'erro' }
            [void]$sb.AppendLine('<tr><td>' + (HtmlEnc $e.Rotulo) + '</td><td><span class="b ' + $c + '">' + (HtmlEnc $e.Status) + '</span></td></tr>')
        }
        [void]$sb.AppendLine('</table>')
    }

    [void]$sb.AppendLine('<h2>Diagnóstico</h2>')
    if ($achados.Count -gt 0) {
        [void]$sb.AppendLine('<table><tr><th>Área</th><th>Resultado</th><th>Nível</th></tr>')
        foreach ($a in @($achados | Sort-Object { $ordem[$_.Nivel] })) {
            $rot = $rotulos[$a.Nivel]
            if (-not $rot) { $rot = $a.Nivel }
            [void]$sb.AppendLine('<tr><td>' + (HtmlEnc $a.Area) + '</td><td>' + (HtmlEnc $a.Texto) + '</td><td><span class="b ' + $a.Nivel + '">' + (HtmlEnc $rot) + '</span></td></tr>')
        }
        [void]$sb.AppendLine('</table>')
    } else {
        [void]$sb.AppendLine('<p>Nenhum diagnóstico foi executado nesta sessão.</p>')
    }

    [void]$sb.AppendLine('<h2>Pontos de atenção e recomendações</h2>')
    $atencao = @($achados | Where-Object { $_.Nivel -eq 'erro' -or $_.Nivel -eq 'aviso' } | Sort-Object { $ordem[$_.Nivel] })
    if ($atencao.Count -gt 0) {
        [void]$sb.AppendLine('<ul>')
        foreach ($a in $atencao) { [void]$sb.AppendLine('<li>' + (HtmlEnc $a.Texto) + '</li>') }
        [void]$sb.AppendLine('</ul>')
    } else {
        [void]$sb.AppendLine('<p>Nenhum ponto de atenção identificado.</p>')
    }

    if ($D.Observacoes) {
        [void]$sb.AppendLine('<h2>Observações do técnico</h2><div class="obs">' + (HtmlEnc $D.Observacoes) + '</div>')
    }
    [void]$sb.AppendLine('<h2>Ajustes aplicados</h2>')
    $ajustes = @($D.Ajustes)
    if ($ajustes.Count -gt 0) {
        [void]$sb.AppendLine('<ul>')
        foreach ($aj in $ajustes) { [void]$sb.AppendLine('<li>' + (HtmlEnc $aj) + '</li>') }
        [void]$sb.AppendLine('</ul>')
    } else {
        [void]$sb.AppendLine('<p>Nenhum ajuste de configuração registrado.</p>')
    }

    [void]$sb.AppendLine('<div class="assin"><div>Técnico responsável<br><b>' + (HtmlEnc $D.Tecnico) + '</b></div><div>Cliente<br><b>' + (HtmlEnc $D.Cliente) + '</b></div></div>')
    [void]$sb.AppendLine('<div class="rod">Gerado pela HS-Tech Central de Ferramentas ' + (HtmlEnc $D.Versao) + '</div></div></body></html>')
    return $sb.ToString()
}

function Gerar-RelatorioHTML {
    param([string]$Destino)
    $d = @{}
    $d.Data = Get-Date -Format 'dd/MM/yyyy HH:mm'
    $d.Computador = $env:COMPUTERNAME
    $d.Usuario = $env:USERNAME
    $d.Versao = 'v3.6.0'
    $d.Empresa = [string]$script:Atendimento.Empresa
    $d.Tecnico = [string]$script:Atendimento.Tecnico
    $d.ContatoEmpresa = [string]$script:Atendimento.ContatoEmpresa
    $d.Cliente = [string]$script:Atendimento.Cliente
    $d.Equipamento = [string]$script:Atendimento.Equipamento
    $d.Observacoes = [string]$script:Atendimento.Observacoes
    $d.LogoUri = ''
    $logoB64 = [string]$script:Atendimento.LogoBase64
    if ($logoB64 -and ($logoB64 -match '^[A-Za-z0-9+/=]+$')) { $d.LogoUri = 'data:image/png;base64,' + $logoB64 }
    $d.Windows = ''; $d.Cpu = ''; $d.Ram = ''; $d.Gpus = @(); $d.Discos = @()
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $ram = Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum
        $d.Windows = "$($os.Caption) (build $($os.BuildNumber))"
        $d.Cpu = [string]$cpu.Name
        $d.Ram = ("{0:N1} GB" -f ($ram.Sum / 1GB))
        $d.Gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name })
        $d.Discos = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object { "{0} | {1} | saúde: {2}" -f $_.FriendlyName, $_.MediaType, $_.HealthStatus })
    } catch { }
    $d.Plano = Nome-PlanoEnergia
    $d.Antes = $script:UltimoAntes
    $d.Depois = $script:UltimoDepois
    $d.Etapas = @($script:Etapas)
    $d.Achados = @($script:Achados)
    $aj = @()
    if (Test-Path $script:BackupFile) {
        try {
            $b = Get-Content $script:BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $b.PSObject.Properties) { $aj += (Descrever-Ajuste $p.Name $p.Value) }
        } catch { }
    }
    $d.Ajustes = $aj
    $html = Montar-HTML $d
    Set-Content -Path $Destino -Value $html -Encoding UTF8
    return $Destino
}

function Relatorio-HTML-Agora {
    if ([string]::IsNullOrWhiteSpace($script:Atendimento.Cliente)) {
        if (Confirmar ("Deseja informar o nome do cliente, o técnico e observações antes de gerar o relatório?" + [Environment]::NewLine + [Environment]::NewLine + "Essas informações aparecem no relatório.")) { Editar-DadosAtendimento }
    }

    $pastaDestino = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($pastaDestino) -or -not (Test-Path -LiteralPath $pastaDestino)) {
        $pastaDestino = [Environment]::GetFolderPath('MyDocuments')
    }
    $arq = Join-Path $pastaDestino ("Relatorio_{0}.html" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

    try {
        [void](Gerar-RelatorioHTML $arq)
        if (-not (Test-Path -LiteralPath $arq -PathType Leaf)) {
            throw "O arquivo HTML não foi encontrado após a geração."
        }
        Log "Relatório HTML salvo em: $arq" Green

        $abriu = $false
        try {
            Start-Process -FilePath $arq -ErrorAction Stop
            $abriu = $true
        } catch {
            Log "O Windows não abriu o HTML pelo aplicativo padrão. Tentando navegador alternativo..." Yellow
        }

        if (-not $abriu) {
            $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
            $navegadores = @(
                (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path $pf86 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
                (Join-Path $pf86 'Google\Chrome\Application\chrome.exe'),
                (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
                (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
                (Join-Path $pf86 'Mozilla Firefox\firefox.exe')
            )
            $navegador = $navegadores | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
            if ($navegador) {
                try {
                    Start-Process -FilePath $navegador -ArgumentList @('"' + $arq + '"') -ErrorAction Stop
                    $abriu = $true
                } catch {
                    Log "Não foi possível iniciar o navegador encontrado: $($_.Exception.Message)" Yellow
                }
            }
        }

        if (-not $abriu) {
            try { Start-Process -FilePath 'explorer.exe' -ArgumentList @('"' + $pastaDestino + '"') -ErrorAction Stop } catch { }
            [System.Windows.Forms.MessageBox]::Show(
                ("O relatório foi gerado, mas o Windows não conseguiu abrir um navegador automaticamente." + [Environment]::NewLine + [Environment]::NewLine + "Arquivo salvo em:" + [Environment]::NewLine + $arq + [Environment]::NewLine + [Environment]::NewLine + "Abra esse arquivo manualmente com Edge, Chrome ou Firefox."),
                'HS-Tech - Relatório gerado',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    } catch {
        Log "Falha ao gerar o relatório HTML: $($_.Exception.Message)" Red
        [System.Windows.Forms.MessageBox]::Show(
            ("Não foi possível gerar o relatório HTML." + [Environment]::NewLine + [Environment]::NewLine + "Detalhes: " + $_.Exception.Message),
            'HS-Tech - Erro no relatório',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

# ============================================================
#  TESTE DE ESTABILIDADE, HISTORICO E CONFIGURACOES
# ============================================================
function Add-Hist {
    param($Cpu, $GpuUso, $TempCpu, $TempGpu)
    $vals = @($Cpu, $GpuUso, $TempCpu, $TempGpu)
    for ($i = 0; $i -lt 4; $i++) {
        $v = -1.0
        if ($null -ne $vals[$i]) { $v = [double]$vals[$i] }
        [void]$script:Hist[$i].Add($v)
        if ($script:Hist[$i].Count -gt 120) { $script:Hist[$i].RemoveAt(0) }
    }
    [void]$script:HistHoras.Add((Get-Date -Format 'HH:mm:ss'))
    if ($script:HistHoras.Count -gt 120) { $script:HistHoras.RemoveAt(0) }
    if ($null -ne $script:Grafico -and $script:Paginas['monitor'].Visible) { $script:Grafico.Invalidate() }
}

function Desenhar-Grafico {
    param($G, $Painel)
    $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $G.Clear((ParaCor $script:Paleta.Painel))
    $w = $Painel.ClientSize.Width
    $h = $Painel.ClientSize.Height
    $penGrade = New-Object System.Drawing.Pen((ParaCor $script:Paleta.Borda), 1)
    foreach ($f in @(0.25, 0.5, 0.75)) {
        $yy = [single]($h * $f)
        $G.DrawLine($penGrade, [single]0, $yy, [single]$w, $yy)
    }
    $penGrade.Dispose()
    $cores = @($script:Paleta.Neon, $script:Paleta.Rosa, $script:Paleta.Amarelo, $script:Paleta.Cian)
    $nomes = @('CPU %', 'GPU %', 'Temp CPU', 'Temp GPU')
    $passo = [double]$w / 119.0
    for ($s = 0; $s -lt 4; $s++) {
        $dados = $script:Hist[$s]
        $n = $dados.Count
        $pts = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $n; $i++) {
            if ($dados[$i] -ge 0) {
                $x = [single]($w - (($n - 1 - $i) * $passo))
                $v = [math]::Min(100.0, $dados[$i])
                $y = [single]($h - ($v / 100.0 * ($h - 4)) - 2)
                [void]$pts.Add((New-Object System.Drawing.PointF($x, $y)))
            }
        }
        if ($pts.Count -ge 2) {
            $pen = New-Object System.Drawing.Pen((ParaCor $cores[$s]), 2)
            $G.DrawLines($pen, [System.Drawing.PointF[]]$pts.ToArray([System.Drawing.PointF]))
            $pen.Dispose()
        }
    }
    $fonte = Fonte 'Segoe UI' 8.5 'Regular'
    for ($s = 0; $s -lt 4; $s++) {
        $br = New-Object System.Drawing.SolidBrush((ParaCor $cores[$s]))
        $G.DrawString($nomes[$s], $fonte, $br, [single](12 + $s * 92), [single]6)
        $br.Dispose()
    }
    $fonte.Dispose()
}

function Exportar-Historico {
    if ($script:HistHoras.Count -eq 0) { Log 'Ainda não há dados no histórico.' Yellow; return }
    $nomes = @('CPU', 'GPU', 'Temp CPU', 'Temp GPU')
    for ($s = 0; $s -lt 4; $s++) {
        $validos = @($script:Hist[$s] | Where-Object { $_ -ge 0 })
        if ($validos.Count -gt 0) {
            $m = $validos | Measure-Object -Average -Maximum
            Log ("{0}: média {1} | pico {2}" -f $nomes[$s], [math]::Round($m.Average), [math]::Round($m.Maximum))
        }
    }
    $arq = Join-Path $script:Pasta ("historico_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $linhas = @('hora;cpu_pct;gpu_pct;temp_cpu;temp_gpu')
    for ($i = 0; $i -lt $script:HistHoras.Count; $i++) {
        $cols = @($script:HistHoras[$i])
        for ($s = 0; $s -lt 4; $s++) {
            $x = $script:Hist[$s][$i]
            if ($x -lt 0) { $cols += '' } else { $cols += [string]$x }
        }
        $linhas += ($cols -join ';')
    }
    $linhas | Set-Content -Path $arq -Encoding UTF8
    Log "Histórico exportado: $arq" Green
}

function Exportar-Config {
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Configurações (*.json)|*.json'
    $dlg.FileName = 'otimizador_config.json'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { Log 'Cancelado.' Yellow; return }
    $obj = @{ Jogos = @($script:Jogos); Cfg = $script:Cfg; Empresa = @{ Empresa = $script:Atendimento.Empresa; Tecnico = $script:Atendimento.Tecnico; ContatoEmpresa = $script:Atendimento.ContatoEmpresa; LogoBase64 = $script:Atendimento.LogoBase64 } }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -Path $dlg.FileName -Encoding UTF8
    Log "Configurações exportadas: $($dlg.FileName)" Green
}

function Importar-Config {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Configurações (*.json)|*.json'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { Log 'Cancelado.' Yellow; return }
    try {
        $dados = Get-Content $dlg.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $dados.Jogos -or $null -eq $dados.Cfg) { throw 'Arquivo de configuração inválido.' }
        $script:Jogos = @($dados.Jogos | ForEach-Object { [string]$_ })
        $script:ListaJogos.Items.Clear()
        foreach ($j in $script:Jogos) { [void]$script:ListaJogos.Items.Add($j) }
        $script:NumCpu.Value = [math]::Max(40, [math]::Min(120, [int]$dados.Cfg.CpuMax))
        $script:NumGpu.Value = [math]::Max(40, [math]::Min(120, [int]$dados.Cfg.GpuMax))
        $script:NumDisco.Value = [math]::Max(40, [math]::Min(120, [int]$dados.Cfg.DiscoMax))
        $script:ChkAlertas.Checked = [bool]$dados.Cfg.Alertas
        $script:ChkAuto.Checked = [bool]$dados.Cfg.Auto
        Salvar-Jogos
        Salvar-Config
        if ($null -ne $dados.Empresa) {
            foreach ($kE in @('Empresa', 'Tecnico', 'ContatoEmpresa', 'LogoBase64')) {
                if ($null -ne $dados.Empresa.$kE) { $script:Atendimento[$kE] = [string]$dados.Empresa.$kE }
            }
            Salvar-Atendimento
        }
        Log 'Configurações importadas.' Green
    } catch {
        Log "Não foi possível importar: $($_.Exception.Message)" Red
    }
}

# ============================================================
#  DRIVERS: DIAGNOSTICO, BACKUP E ATUALIZACAO
# ============================================================
$script:BackupDriversOk = $false

function Perguntar-BackupDrivers {
    param([int]$Quantidade)
    $texto = "Serão instalados $Quantidade driver(s).`n`n" +
             "Antes disso, será criado um ponto de restauração.`n" +
             "Deseja também salvar um backup dos drivers atuais? (recomendado)`n`n" +
             "Sim = fazer backup e instalar`nNão = apenas instalar`nCancelar = voltar"
    return [string][System.Windows.Forms.MessageBox]::Show($texto, 'Atualizar drivers', 'YesNoCancel', 'Question')
}

function Verificar-DispositivosProblema {
    Log '--- Dispositivos com problema de driver ---' Cyan
    $prob = @()
    try {
        $prob = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.Status -in @('Error', 'Degraded', 'Unknown') })
    } catch {
        Log "Não foi possível consultar os dispositivos: $($_.Exception.Message)" Yellow
        return
    }
    if ($prob.Count -eq 0) {
        Log 'Nenhum dispositivo com problema.' Green
        Adicionar-Achado 'Drivers' 'Nenhum dispositivo com problema de driver.' 'ok'
        return
    }
    $nomes = @()
    foreach ($d in $prob) {
        $nome = [string]$d.FriendlyName
        if (-not $nome) { $nome = "Dispositivo desconhecido ($($d.Class))" }
        $nomes += $nome
        Log ("   {0} [{1}] - situação: {2}" -f $nome, $d.Class, $d.Status) Yellow
    }
    $resumo = ($nomes | Select-Object -First 5) -join ', '
    Log "$($prob.Count) dispositivo(s) com problema. Use 'Procurar atualizações de drivers' para tentar corrigir." Yellow
    Adicionar-Achado 'Drivers' ("{0} dispositivo(s) com problema de driver: {1}." -f $prob.Count, $resumo) 'aviso'
}

function Inventario-Drivers {
    Log '--- Inventário e idade dos drivers (pode levar alguns segundos) ---' Cyan
    $bloco = {
        param($x)
        Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -and $_.DriverDate } | ForEach-Object {
            [pscustomobject]@{ Nome = [string]$_.DeviceName; Classe = [string]$_.DeviceClass; Fabricante = [string]$_.Manufacturer; Versao = [string]$_.DriverVersion; Data = [datetime]$_.DriverDate }
        }
    }
    $todos = @(Rodar-EmJob $bloco @(0))
    if ($todos.Count -eq 0) { Log 'Não foi possível listar os drivers instalados.' Yellow; return }
    $relevantes = @('DISPLAY', 'NET', 'MEDIA', 'BLUETOOTH', 'HDC', 'SCSIADAPTER', 'SYSTEM', 'BIOMETRIC')
    $limite = (Get-Date).AddYears(-3)
    $velhos = @($todos | Where-Object { ($relevantes -contains ([string]$_.Classe).ToUpper()) -and $_.Fabricante -ne 'Microsoft' -and $_.Data -lt $limite } | Sort-Object Data)
    Log ("{0} drivers instalados; {1} de componentes principais com mais de 3 anos." -f $todos.Count, $velhos.Count)
    foreach ($v in @($velhos | Select-Object -First 12)) {
        Log ("   {0} ({1}) - versão {2} de {3}" -f $v.Nome, $v.Fabricante, $v.Versao, $v.Data.ToString('dd/MM/yyyy'))
    }
    if ($velhos.Count -gt 0) {
        $ex = (@($velhos | Select-Object -First 3) | ForEach-Object { $_.Nome }) -join ', '
        Adicionar-Achado 'Drivers' ("{0} drivers de componentes principais têm mais de 3 anos (ex.: {1}). Driver antigo nem sempre é problema: atualize se houver falhas ou se o fabricante tiver versão nova." -f $velhos.Count, $ex) 'aviso'
    } else {
        Adicionar-Achado 'Drivers' 'Nenhum driver de componente principal com mais de 3 anos.' 'ok'
    }
}

function Backup-Drivers {
    param([string]$PastaBase = '')
    $script:BackupDriversOk = $false
    Log '--- Backup dos drivers instalados ---' Cyan
    if (-not $PastaBase) {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Escolha onde salvar o backup dos drivers (pode ocupar vários GB).'
        $dlg.SelectedPath = [Environment]::GetFolderPath('Desktop')
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { Log 'Backup cancelado.' Yellow; return }
        $PastaBase = $dlg.SelectedPath
    }
    $destino = Join-Path $PastaBase ("Backup_Drivers_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
    try {
        New-Item -ItemType Directory -Path $destino -Force | Out-Null
        Log 'Exportando os drivers de terceiros instalados (pode levar alguns minutos)...'
        [void](Rodar-EmJob { param($d) Export-WindowsDriver -Online -Destination $d | Out-Null } @($destino))
        $qt = @(Get-ChildItem -Path $destino -Directory -ErrorAction SilentlyContinue).Count
        if ($qt -gt 0) {
            $script:BackupDriversOk = $true
            Log "Backup concluído: $qt pacotes de driver em $destino" Green
            Adicionar-Achado 'Drivers' "Backup de $qt pacotes de driver salvo em $destino." 'ok'
        } else {
            Log 'Nenhum driver de terceiros foi exportado (o backup ficou vazio).' Yellow
        }
    } catch {
        Log "Falha no backup dos drivers: $($_.Exception.Message)" Red
    }
}

function Atualizar-Drivers {
    Log '--- Atualização de drivers (Windows Update) ---' Cyan
    Log 'Procurando drivers disponíveis no Windows Update (pode levar alguns minutos)...'
    $busca = @(Rodar-EmJob {
        param($x)
        try {
            $sessao = New-Object -ComObject Microsoft.Update.Session
            $res = $sessao.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
            foreach ($u in $res.Updates) {
                $data = ''
                if ($u.DriverVerDate) { $data = ([datetime]$u.DriverVerDate).ToString('dd/MM/yyyy') }
                [pscustomobject]@{
                    Id = [string]$u.Identity.UpdateID; Titulo = [string]$u.Title; Fabricante = [string]$u.DriverManufacturer
                    Classe = [string]$u.DriverClass; Data = $data; TamanhoMB = [math]::Round($u.MaxDownloadSize / 1MB, 1)
                }
            }
        } catch { [pscustomobject]@{ Erro = $_.Exception.Message } }
    } @(0))

    $falha = @($busca | Where-Object { $_.Erro })
    if ($falha.Count -gt 0) {
        Log "Não foi possível consultar o Windows Update: $($falha[0].Erro)" Red
        Adicionar-Achado 'Drivers' 'Não foi possível consultar o Windows Update (verifique a internet e o serviço de atualização).' 'aviso'
        return
    }
    $encontrados = @($busca | Where-Object { $_.Id })
    if ($encontrados.Count -eq 0) {
        Log 'Nenhum driver pendente no Windows Update.' Green
        Adicionar-Achado 'Drivers' 'Nenhum driver pendente no Windows Update.' 'ok'
        return
    }
    Log "$($encontrados.Count) driver(s) disponível(is)."

    $itens = @()
    foreach ($u in $encontrados) {
        $obs = ''
        $marcado = $true
        if ($u.Classe -eq 'Display') { $marcado = $false; $obs = ' [vídeo: prefira o site do fabricante]' }
        if ($u.Classe -match 'Firmware' -or $u.Titulo -match 'Firmware|BIOS') { $marcado = $false; $obs = ' [firmware: só com o carregador ligado]' }
        $classe = $u.Classe
        if (-not $classe) { $classe = 'Driver' }
        $itens += [pscustomobject]@{ Id = [string]$u.Id; Rotulo = ("[{0}] {1}{2}" -f $classe, $u.Titulo, $obs); Marcado = $marcado }
    }
    $escolha = Mostrar-ListaMarcavel 'Drivers disponíveis' "Os drivers marcados serão baixados e instalados.`nDrivers de vídeo e firmware vêm desmarcados por segurança." $itens 'INSTALAR'
    if ($null -eq $escolha) { Log 'Cancelado.' Yellow; return }
    $selecionados = @($itens | Where-Object { $escolha[[string]$_.Id] })
    if ($selecionados.Count -eq 0) { Log 'Nenhum driver selecionado.' Yellow; return }

    $resp = Perguntar-BackupDrivers $selecionados.Count
    if ($resp -eq 'Cancel') { Log 'Cancelado.' Yellow; return }
    Criar-PontoRestauracao
    if ($resp -eq 'Yes') {
        Backup-Drivers
        if (-not $script:BackupDriversOk) {
            if (-not (Confirmar 'O backup dos drivers não foi concluído. Deseja instalar mesmo assim?')) { Log 'Instalação cancelada.' Yellow; return }
        }
    }

    $ids = @($selecionados | ForEach-Object { [string]$_.Id })
    Log "Baixando e instalando $($ids.Count) driver(s). Isso pode demorar; não desligue o PC."
    $res = @(Rodar-EmJob {
        param($ids)
        try {
            $sessao = New-Object -ComObject Microsoft.Update.Session
            $busca = $sessao.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
            $col = New-Object -ComObject Microsoft.Update.UpdateColl
            $titulos = @()
            foreach ($u in $busca.Updates) {
                if ($ids -contains [string]$u.Identity.UpdateID) {
                    if (-not $u.EulaAccepted) { $u.AcceptEula() }
                    [void]$col.Add($u)
                    $titulos += [string]$u.Title
                }
            }
            if ($col.Count -eq 0) { return [pscustomobject]@{ Erro = 'Os drivers selecionados não estão mais disponíveis.' } }
            $dl = $sessao.CreateUpdateDownloader()
            $dl.Updates = $col
            [void]$dl.Download()
            $inst = $sessao.CreateUpdateInstaller()
            $inst.Updates = $col
            $r = $inst.Install()
            for ($i = 0; $i -lt $col.Count; $i++) {
                [pscustomobject]@{ Titulo = $titulos[$i]; Codigo = [int]$r.GetUpdateResult($i).ResultCode; Reiniciar = [bool]$r.RebootRequired }
            }
        } catch { [pscustomobject]@{ Erro = $_.Exception.Message } }
    } @(, $ids))

    $erroInst = @($res | Where-Object { $_.Erro })
    if ($erroInst.Count -gt 0) {
        Log "Falha na instalação: $($erroInst[0].Erro)" Red
        Adicionar-Achado 'Drivers' "Falha ao instalar drivers: $($erroInst[0].Erro)" 'erro'
        return
    }
    $ok = 0; $falhas = 0; $reiniciar = $false
    foreach ($r in @($res | Where-Object { $_.Titulo })) {
        if ($r.Codigo -eq 2 -or $r.Codigo -eq 3) { $ok++; Log "Instalado: $($r.Titulo)" Green }
        else { $falhas++; Log "Falhou: $($r.Titulo)" Yellow }
        if ($r.Reiniciar) { $reiniciar = $true }
    }
    Log "Drivers instalados: $ok | com falha: $falhas" Green
    if ($ok -gt 0) { Adicionar-Achado 'Drivers' "$ok driver(s) instalado(s) pelo Windows Update." 'ok' }
    if ($falhas -gt 0) { Adicionar-Achado 'Drivers' "$falhas driver(s) não puderam ser instalados." 'aviso' }
    if ($reiniciar) {
        Log 'Reinicie o PC para concluir a instalação dos drivers.' Yellow
        Adicionar-Achado 'Drivers' 'Reinicie o PC para concluir a instalação dos drivers.' 'aviso'
    }
}

function Abrir-DriversFabricante {
    Log '--- Drivers do fabricante do PC ---' Cyan
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $bb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
        $fab = [string]$cs.Manufacturer
        $mod = [string]$cs.Model
        if ((-not $fab) -or $fab -match 'System manufacturer|To be filled|O\.E\.M\.|Default string') {
            if ($bb) { $fab = [string]$bb.Manufacturer; $mod = [string]$bb.Product }
        }
        Log "Equipamento detectado: $fab $mod" Green
        $consulta = [System.Uri]::EscapeDataString(("{0} {1} drivers" -f $fab, $mod))
        if (Confirmar "Abrir uma pesquisa pelos drivers oficiais de '$fab $mod'?`n`nBaixe somente do site do fabricante.") {
            Start-Process ('https://www.google.com/search?q=' + $consulta)
        }
    } catch {
        Log "Não foi possível identificar o equipamento: $($_.Exception.Message)" Yellow
    }
}

function Assistente-Drivers {
    Log '=== Assistente de drivers ===' Cyan
    Passo 1 3 'Dispositivos com problema'
    Verificar-DispositivosProblema
    Passo 2 3 'Idade dos drivers instalados'
    Inventario-Drivers
    Passo 3 3 'Atualizações disponíveis no Windows Update'
    Atualizar-Drivers
    Log 'Assistente concluído. Para placa de vídeo, use também o site do fabricante (aba Drivers).' Green
}

# ============================================================
#  DADOS DO ATENDIMENTO (empresa, tecnico, logo e cliente)
# ============================================================
$script:AtendimentoFile = Join-Path $script:Pasta 'atendimento.json'
$script:Atendimento = @{ Empresa = ''; Tecnico = ''; ContatoEmpresa = ''; LogoBase64 = ''; Cliente = ''; Equipamento = ''; Observacoes = '' }
if (Test-Path $script:AtendimentoFile) {
    try {
        $lidoAtend = Get-Content $script:AtendimentoFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($kAtend in @('Empresa', 'Tecnico', 'ContatoEmpresa', 'LogoBase64')) {
            if ($null -ne $lidoAtend.$kAtend) { $script:Atendimento[$kAtend] = [string]$lidoAtend.$kAtend }
        }
    } catch { }
}
$script:LogoTemp = ''

function Salvar-Atendimento {
    $o = @{
        Empresa = $script:Atendimento.Empresa; Tecnico = $script:Atendimento.Tecnico
        ContatoEmpresa = $script:Atendimento.ContatoEmpresa; LogoBase64 = $script:Atendimento.LogoBase64
    }
    $o | ConvertTo-Json | Set-Content -Path $script:AtendimentoFile -Encoding UTF8
}

function Carregar-Logo {
    # Reduz a imagem (altura maxima 120 px) e devolve em Base64 (PNG) para embutir no relatorio
    param([string]$Caminho)
    $img = [System.Drawing.Image]::FromFile($Caminho)
    try {
        $esc = [math]::Min(1.0, 120.0 / $img.Height)
        $w = [int][math]::Max(1, [math]::Round($img.Width * $esc))
        $h = [int][math]::Max(1, [math]::Round($img.Height * $esc))
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($img, 0, 0, $w, $h)
        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $b64 = [Convert]::ToBase64String($ms.ToArray())
        $ms.Dispose()
        $bmp.Dispose()
        return $b64
    } finally {
        $img.Dispose()
    }
}

function Novo-CampoDialogo {
    param($Form, [string]$Rotulo, [int]$Y, [string]$Valor, [int]$Altura = 26, [bool]$Multilinha = $false)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Rotulo
    $l.AutoSize = $true
    $l.Font = (Fonte 'Segoe UI' 9 'Regular')
    $l.ForeColor = (ParaCor $script:Paleta.Mudo)
    $l.Location = New-Object System.Drawing.Point(20, $Y)
    $Form.Controls.Add($l)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point(20, ($Y + 20))
    $t.Width = 540
    $t.Text = $Valor
    $t.Font = (Fonte 'Segoe UI' 10 'Regular')
    $t.BackColor = (ParaCor $script:Paleta.Painel)
    $t.ForeColor = (ParaCor $script:Paleta.Texto)
    $t.BorderStyle = 'FixedSingle'
    if ($Multilinha) {
        $t.Multiline = $true
        $t.Height = $Altura
        $t.ScrollBars = 'Vertical'
    }
    $Form.Controls.Add($t)
    return $t
}

function Editar-DadosAtendimento {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Dados do atendimento'
    $dlg.Size = New-Object System.Drawing.Size(600, 700)
    $dlg.StartPosition = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = (ParaCor $script:Paleta.Fundo)
    $dlg.ForeColor = (ParaCor $script:Paleta.Texto)
    $dlg.Font = (Fonte 'Segoe UI' 9.5 'Regular')

    $s1 = New-Object System.Windows.Forms.Label
    $s1.Text = 'EMPRESA (fica salva neste PC e entra no relatório)'
    $s1.AutoSize = $true
    $s1.Font = (Fonte 'Segoe UI Semibold' 8.5 'Regular')
    $s1.ForeColor = (ParaCor $script:Paleta.Cian)
    $s1.Location = New-Object System.Drawing.Point(20, 14)
    $dlg.Controls.Add($s1)

    $script:TxtEmpresa = Novo-CampoDialogo $dlg 'Empresa' 38 $script:Atendimento.Empresa
    $script:TxtTecnico = Novo-CampoDialogo $dlg 'Técnico responsável' 100 $script:Atendimento.Tecnico
    $script:TxtContato = Novo-CampoDialogo $dlg 'Contato da empresa (telefone ou e-mail)' 162 $script:Atendimento.ContatoEmpresa

    $lblL = New-Object System.Windows.Forms.Label
    $lblL.Text = 'Logo da empresa (PNG ou JPG)'
    $lblL.AutoSize = $true
    $lblL.Font = (Fonte 'Segoe UI' 9 'Regular')
    $lblL.ForeColor = (ParaCor $script:Paleta.Mudo)
    $lblL.Location = New-Object System.Drawing.Point(20, 224)
    $dlg.Controls.Add($lblL)

    $script:LogoTemp = [string]$script:Atendimento.LogoBase64
    $script:LblLogo = New-Object System.Windows.Forms.Label
    $script:LblLogo.AutoSize = $true
    $script:LblLogo.Font = (Fonte 'Segoe UI' 9 'Regular')
    $script:LblLogo.ForeColor = (ParaCor $script:Paleta.Texto)
    $script:LblLogo.Location = New-Object System.Drawing.Point(300, 256)
    if ($script:LogoTemp) { $script:LblLogo.Text = 'Logo carregada.' } else { $script:LblLogo.Text = 'Nenhuma logo selecionada.' }
    $dlg.Controls.Add($script:LblLogo)

    $btnLogo = Novo-BotaoPequeno 'ESCOLHER IMAGEM' {
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'Imagens (*.png;*.jpg;*.jpeg;*.gif;*.bmp)|*.png;*.jpg;*.jpeg;*.gif;*.bmp'
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            try {
                $script:LogoTemp = Carregar-Logo $ofd.FileName
                $script:LblLogo.Text = 'Logo carregada.'
            } catch {
                $script:LblLogo.Text = 'Não foi possível abrir a imagem.'
            }
        }
    } $script:Paleta.Cian 150 32
    $btnLogo.Location = New-Object System.Drawing.Point(20, 248)
    $dlg.Controls.Add($btnLogo)

    $btnSemLogo = Novo-BotaoPequeno 'REMOVER' {
        $script:LogoTemp = ''
        $script:LblLogo.Text = 'Nenhuma logo selecionada.'
    } $script:Paleta.Rosa 110 32
    $btnSemLogo.Location = New-Object System.Drawing.Point(180, 248)
    $dlg.Controls.Add($btnSemLogo)

    $s2 = New-Object System.Windows.Forms.Label
    $s2.Text = 'CLIENTE (vale só para este atendimento)'
    $s2.AutoSize = $true
    $s2.Font = (Fonte 'Segoe UI Semibold' 8.5 'Regular')
    $s2.ForeColor = (ParaCor $script:Paleta.Cian)
    $s2.Location = New-Object System.Drawing.Point(20, 304)
    $dlg.Controls.Add($s2)

    $script:TxtCliente = Novo-CampoDialogo $dlg 'Nome do cliente' 328 $script:Atendimento.Cliente
    $script:TxtEquip = Novo-CampoDialogo $dlg 'Equipamento (marca e modelo)' 390 $script:Atendimento.Equipamento
    $script:TxtObs = Novo-CampoDialogo $dlg 'Observações do técnico (aparecem no relatório)' 452 $script:Atendimento.Observacoes 100 $true

    $ok = Novo-BotaoPequeno 'SALVAR' { } $script:Paleta.Neon 130 36
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(290, 612)
    $dlg.Controls.Add($ok)
    $cancelar = Novo-BotaoPequeno 'CANCELAR' { } $script:Paleta.Rosa 130 36
    $cancelar.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelar.Location = New-Object System.Drawing.Point(430, 612)
    $dlg.Controls.Add($cancelar)
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancelar

    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:Atendimento.Empresa = $script:TxtEmpresa.Text.Trim()
        $script:Atendimento.Tecnico = $script:TxtTecnico.Text.Trim()
        $script:Atendimento.ContatoEmpresa = $script:TxtContato.Text.Trim()
        $script:Atendimento.LogoBase64 = [string]$script:LogoTemp
        $script:Atendimento.Cliente = $script:TxtCliente.Text.Trim()
        $script:Atendimento.Equipamento = $script:TxtEquip.Text.Trim()
        $script:Atendimento.Observacoes = $script:TxtObs.Text.Trim()
        Salvar-Atendimento
        Log 'Dados do atendimento salvos (empresa e logo ficam neste PC; cliente só nesta sessão).' Green
    } else {
        Log 'Dados do atendimento não alterados.' Gray
    }
    $dlg.Dispose()
}

# ============================================================
#  LIMPEZA PROFUNDA DO WINDOWS
# ============================================================
function Existe-Caminho {
    param([string]$Caminho)
    return (Test-Path -LiteralPath $Caminho)
}

function Livre-Sistema {
    return [int64](Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free
}

function Medir-Pasta {
    param([string]$Caminho)
    if (-not (Existe-Caminho $Caminho)) { return [int64]0 }
    $soma = (Get-ChildItem -LiteralPath $Caminho -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($soma) { return [int64]$soma }
    return [int64]0
}

function Tamanho-Arquivo {
    param([string]$Caminho)
    if (Existe-Caminho $Caminho) { return [int64](Get-Item -LiteralPath $Caminho -Force -ErrorAction SilentlyContinue).Length }
    return [int64]0
}

function Formatar-Tamanho {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Esvaziar-Pasta {
    param([string]$Caminho)
    if (Existe-Caminho $Caminho) {
        Get-ChildItem -LiteralPath $Caminho -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Executar-Cleanmgr {
    # Usa a propria Limpeza de Disco do Windows (modo sagerun) para os itens pedidos
    param([string[]]$Chaves)
    $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $usadas = @()
    foreach ($c in $Chaves) {
        $k = $base + '\' + $c
        if (Test-Path -LiteralPath $k) {
            Set-ItemProperty -LiteralPath $k -Name 'StateFlags0098' -Value 2 -Type DWord
            $usadas += $k
        }
    }
    if ($usadas.Count -eq 0) { return $false }
    try { [void](Rodar-Processo 'cleanmgr.exe' '/sagerun:98') }
    finally { foreach ($k in $usadas) { Remove-ItemProperty -LiteralPath $k -Name 'StateFlags0098' -ErrorAction SilentlyContinue } }
    return $true
}

function Limpeza-Profunda {
    Log '--- Limpeza profunda do Windows ---' Cyan
    $sistema = $env:SystemRoot
    $unidade = $env:SystemDrive
    $pWU = Join-Path $sistema 'SoftwareDistribution\Download'
    $pEntrega = Join-Path $sistema 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
    $pWer1 = Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'
    $pWer2 = Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'
    $pMini = Join-Path $sistema 'Minidump'
    $pMem = Join-Path $sistema 'MEMORY.DMP'
    $pOld = $unidade + '\Windows.old'
    $pLix = $unidade + '\$Recycle.Bin'

    Log 'Calculando o espaço que pode ser liberado (pode levar alguns segundos)...'
    $tWU = Medir-Pasta $pWU
    $tEntrega = Medir-Pasta $pEntrega
    $tWer = (Medir-Pasta $pWer1) + (Medir-Pasta $pWer2)
    $tDump = (Medir-Pasta $pMini) + (Tamanho-Arquivo $pMem)
    $temOld = Existe-Caminho $pOld
    $tOld = [int64]0
    if ($temOld) { $tOld = Medir-Pasta $pOld }
    $tLix = Medir-Pasta $pLix

    $itens = @()
    $itens += [pscustomobject]@{ Id = 'wu'; Rotulo = ("Cache de atualizações do Windows Update ({0})" -f (Formatar-Tamanho $tWU)); Marcado = $true }
    $itens += [pscustomobject]@{ Id = 'componentes'; Rotulo = 'Limpeza do repositório de componentes do Windows (DISM; o tamanho varia)'; Marcado = $true }
    $itens += [pscustomobject]@{ Id = 'entrega'; Rotulo = ("Cache de otimização de entrega ({0})" -f (Formatar-Tamanho $tEntrega)); Marcado = $true }
    $itens += [pscustomobject]@{ Id = 'wer'; Rotulo = ("Relatórios de erro do Windows ({0})" -f (Formatar-Tamanho $tWer)); Marcado = $true }
    $itens += [pscustomobject]@{ Id = 'dumps'; Rotulo = ("Despejos de memória e minidumps ({0}) - úteis para diagnosticar telas azuis" -f (Formatar-Tamanho $tDump)); Marcado = $false }
    if ($temOld) {
        $itens += [pscustomobject]@{ Id = 'windowsold'; Rotulo = ("Instalação anterior do Windows - Windows.old ({0}) - impede voltar à versão anterior" -f (Formatar-Tamanho $tOld)); Marcado = $false }
    }
    $itens += [pscustomobject]@{ Id = 'lixeira'; Rotulo = ("Esvaziar a Lixeira ({0})" -f (Formatar-Tamanho $tLix)); Marcado = $false }

    $escolha = Mostrar-ListaMarcavel 'Limpeza profunda do Windows' "Marque o que deseja limpar. Os tamanhos são estimativas.`nItens que podem ser úteis depois (dumps, Windows.old, Lixeira) vêm desmarcados." $itens 'LIMPAR'
    if ($null -eq $escolha) { Log 'Cancelado.' Yellow; return }
    $sel = @($itens | Where-Object { $escolha[[string]$_.Id] })
    if ($sel.Count -eq 0) { Log 'Nada selecionado.' Yellow; return }
    if (@($sel | Where-Object { $_.Id -eq 'windowsold' }).Count -gt 0) {
        if (-not (Confirmar "Remover a instalação anterior do Windows impede voltar à versão antiga do sistema.`n`nTem certeza?")) {
            $sel = @($sel | Where-Object { $_.Id -ne 'windowsold' })
            Log 'Windows.old mantido.' Yellow
        }
    }
    if ($sel.Count -eq 0) { Log 'Nada a fazer.' Yellow; return }

    $livreAntes = Livre-Sistema
    $n = 0
    $total = $sel.Count
    foreach ($it in $sel) {
        $n++
        Passo $n $total $it.Rotulo
        try {
            switch ($it.Id) {
                'wu' {
                    $rodando = @(@('bits', 'wuauserv') | Where-Object { (Get-Service -Name $_ -ErrorAction SilentlyContinue).Status -eq 'Running' })
                    Stop-Service -Name wuauserv, bits -Force -ErrorAction SilentlyContinue
                    Esvaziar-Pasta $pWU
                    foreach ($sv in $rodando) { Start-Service -Name $sv -ErrorAction SilentlyContinue }
                    Log 'Cache do Windows Update limpo.' Green
                }
                'componentes' {
                    Log 'Limpando o repositório de componentes (pode levar vários minutos)...'
                    $r = Rodar-Processo 'dism.exe' '/Online /Cleanup-Image /StartComponentCleanup'
                    if ($r.Codigo -eq 0) { Log 'Repositório de componentes limpo.' Green }
                    else { Log ("O DISM terminou com o código {0}." -f $r.Codigo) Yellow }
                }
                'entrega' {
                    try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { Esvaziar-Pasta $pEntrega }
                    Log 'Cache de otimização de entrega limpo.' Green
                }
                'wer' {
                    Esvaziar-Pasta $pWer1
                    Esvaziar-Pasta $pWer2
                    Log 'Relatórios de erro do Windows limpos.' Green
                }
                'dumps' {
                    Esvaziar-Pasta $pMini
                    if (Existe-Caminho $pMem) { Remove-Item -LiteralPath $pMem -Force -ErrorAction SilentlyContinue }
                    Log 'Despejos de memória removidos.' Green
                }
                'windowsold' {
                    if (Executar-Cleanmgr @('Previous Installations')) { Log 'Windows.old removido pela Limpeza de Disco do Windows.' Green }
                    else { Log 'A Limpeza de Disco do Windows não oferece a remoção da instalação anterior neste PC.' Yellow }
                }
                'lixeira' {
                    try { Clear-RecycleBin -Force -ErrorAction Stop; Log 'Lixeira esvaziada.' Green }
                    catch { Log 'A Lixeira já estava vazia ou não pôde ser esvaziada.' Gray }
                }
            }
        } catch {
            Log "Falha em '$($it.Rotulo)': $($_.Exception.Message)" Yellow
        }
    }
    $livreDepois = Livre-Sistema
    $liberado = $livreDepois - $livreAntes
    if ($liberado -lt 0) { $liberado = 0 }
    $txt = Formatar-Tamanho ([int64]$liberado)
    Log "Limpeza profunda concluída: aproximadamente $txt liberados." Green
    Adicionar-Achado 'Limpeza' "Limpeza profunda do Windows: cerca de $txt liberados." 'ok'
}

# ============================================================
#  FINALIZAR ATENDIMENTO (relatorio final + remocao da ferramenta)
# ============================================================
function Descrever-Ajuste {
    param([string]$Nome, $Valor)
    if ($Nome -eq 'PlanoEnergia') { return "Plano de energia: alterado (plano original: $Valor)" }
    if ($Nome -eq 'DNSAlterado') { return 'DNS: servidor alterado pela ferramenta' }
    if ($Nome -like 'DNSOriginal|*') {
        $srv = (@($Valor.ServerAddresses) -join ', ')
        if (-not $srv) { $srv = 'automático (DHCP)' }
        return "DNS do adaptador '$($Valor.InterfaceAlias)': alterado (original: $srv)"
    }
    if ($Nome -like '*|*') {
        $partes = $Nome -split '\|', 2
        $orig = "$Valor"
        if ($orig -eq '__AUSENTE__') { $orig = 'não existia' }
        $rotulo = $partes[1]
        switch -Wildcard ($Nome) {
            '*GameBar*'           { $rotulo = 'Modo Jogo do Windows' }
            '*GameDVR_Enabled'    { $rotulo = 'Captura em segundo plano (Game DVR) desativada' }
            '*AppCaptureEnabled'  { $rotulo = 'Captura de jogos (Game DVR) desativada' }
            '*HwSchMode'          { $rotulo = 'Agendamento de GPU acelerado por hardware (HAGS)' }
            '*VisualFXSetting'    { $rotulo = 'Efeitos visuais ajustados para desempenho' }
            '*EnableTransparency' { $rotulo = 'Transparência do Windows desativada' }
            '*ActiveHours*'       { $rotulo = 'Horário ativo do Windows Update' }
        }
        return "Registro - ${rotulo}: $($partes[0])\$($partes[1]) (valor original: $orig)"
    }
    return $Nome
}

function Montar-RelatorioFinal {
    $l = @()
    $l += 'RELATÓRIO FINAL DE OTIMIZAÇÃO E MANUTENÇÃO'
    $l += '============================================='
    $l += ("Data: {0}" -f (Get-Date -Format 'dd/MM/yyyy HH:mm'))
    $l += "Computador: $env:COMPUTERNAME"
    $l += "Usuário do Windows: $env:USERNAME"
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $ram = Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum
        $l += "Windows: $($os.Caption) (build $($os.BuildNumber))"
        $l += ''
        $l += 'HARDWARE'
        $l += "  CPU: $($cpu.Name)"
        $l += ("  RAM instalada: {0:N1} GB" -f ($ram.Sum / 1GB))
        foreach ($g in @(Get-CimInstance Win32_VideoController)) { $l += "  GPU: $($g.Name)" }
        foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
            $l += ("  Disco: {0} | {1} | {2}" -f $d.FriendlyName, $d.MediaType, $d.HealthStatus)
        }
    } catch { $l += '  (não foi possível ler todo o hardware)' }
    $l += ''
    $l += 'AJUSTES APLICADOS PELA FERRAMENTA'
    $qt = 0
    if (Test-Path $script:BackupFile) {
        try {
            $b = Get-Content $script:BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $b.PSObject.Properties) {
                $l += ('  - ' + (Descrever-Ajuste $p.Name $p.Value))
                $qt++
            }
        } catch { $l += '  (o backup de ajustes não pôde ser lido)' }
    }
    if ($qt -eq 0) { $l += '  Nenhum ajuste de configuração registrado.' }
    $l += ''
    $l += ('PLANO DE ENERGIA ATUAL: ' + (Nome-PlanoEnergia))
    $l += ''
    $l += 'RELATÓRIOS ANTES x DEPOIS'
    if (Test-Path $script:RelatorioFile) { $l += @(Get-Content $script:RelatorioFile -Encoding UTF8) }
    else { $l += '  Nenhum relatório antes/depois foi gerado.' }
    $l += ''
    $l += 'REGISTRO DE ATIVIDADES (últimas linhas)'
    foreach ($arq in @(Get-ChildItem -Path $script:Pasta -Filter 'log_*.txt' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $l += "--- $($arq.Name) ---"
        $l += @(Get-Content $arq.FullName -Tail 250 -Encoding UTF8)
    }
    return $l
}

function Finalizar-Remover {
    Log '--- Finalizar e remover a ferramenta ---' Cyan
    $texto = "Esta ação vai:`n`n" +
             "  - gerar o relatório final na Área de Trabalho;`n" +
             "  - desligar o Modo Performance e remover as tarefas agendadas;`n" +
             "  - apagar o programa e todos os seus dados (logs, backup e configurações) deste PC.`n`n" +
             "Os ajustes já aplicados (energia, DNS, Modo Jogo etc.) continuam valendo, mas o botão Desfazer ajustes deixará de existir.`n`n" +
             "Deseja continuar?"
    $r = [System.Windows.Forms.MessageBox]::Show($texto, 'Finalizar e remover', 'YesNo', 'Warning', 'Button2')
    if ($r -ne 'Yes') { Log 'Cancelado.' Yellow; return }

    if ([string]::IsNullOrWhiteSpace($script:Atendimento.Cliente)) {
        if (Confirmar "Deseja informar o nome do cliente e observações para o relatório final?") { Editar-DadosAtendimento }
    }

    # 1) Modo Performance
    if ($script:ModoJogoAtivo -or $script:PlanoAnterior) {
        Sair-ModoPerformance
        $script:ModoJogoAtivo = $false
    }

    # 2) Tarefas agendadas
    foreach ($t in @('OtimizadorGamer-Manutencao', 'OtimizadorGamer-Iniciar')) {
        try {
            Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop
            Log "Tarefa agendada removida: $t" Green
        } catch { }
    }

    # 3) Relatorio final na Area de Trabalho
    $destinoRel = Join-Path ([Environment]::GetFolderPath('Desktop')) ("Relatorio_Final_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
    $relatorioOk = $false
    try {
        Montar-RelatorioFinal | Set-Content -Path $destinoRel -Encoding UTF8 -ErrorAction Stop
        $relatorioOk = $true
        Log "Relatório final salvo: $destinoRel" Green
    } catch {
        Log "Não foi possível salvar o relatório final: $($_.Exception.Message)" Red
        if (-not (Confirmar 'Não foi possível salvar o relatório final. Deseja remover a ferramenta mesmo assim?')) {
            Log 'Remoção cancelada.' Yellow
            return
        }
    }

    # 4) Remocao do programa e dos dados (feita por um processo separado, depois que esta janela fechar)
    $exeAlvo = $null
    if ($script:EhExe) { $exeAlvo = $script:CaminhoScript }
    elseif ($env:OTIMIZADOR_EXE) { $exeAlvo = $env:OTIMIZADOR_EXE }
    $pastaPadrao = Join-Path $env:LOCALAPPDATA 'OtimizadorGamer'
    $cmds = @('ping 127.0.0.1 -n 6 >nul')
    if ($exeAlvo -and (Test-Path $exeAlvo)) {
        $cmds += ('del /f /q "{0}"' -f $exeAlvo)
    }
    if ($script:Pasta -ieq $pastaPadrao) {
        $cmds += ('rmdir /s /q "{0}"' -f $script:Pasta)
    } else {
        # Pasta escolhida pelo usuario: apaga somente os arquivos criados pela ferramenta
        foreach ($padrao in @('log_*.txt', 'backup_ajustes.json', 'jogos.json', 'config.json', 'relatorios.txt', 'relatorio_sistema_*.txt')) {
            $cmds += ('del /f /q "{0}"' -f (Join-Path $script:Pasta $padrao))
        }
        if (-not $script:EhExe) { $cmds += ('del /f /q "{0}"' -f $script:CaminhoScript) }
    }
    if ($exeAlvo -and (Test-Path $exeAlvo)) {
        $cmds += 'ping 127.0.0.1 -n 4 >nul'
        $cmds += ('del /f /q "{0}"' -f $exeAlvo)
    }

    if ($relatorioOk) {
        $abriu = $false
        $destinoHtml = Join-Path ([Environment]::GetFolderPath('Desktop')) ("Relatorio_Final_{0}.html" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
        try {
            [void](Gerar-RelatorioHTML $destinoHtml)
            Log "Relatório HTML salvo: $destinoHtml" Green
            Start-Process $destinoHtml
            $abriu = $true
        } catch { }
        if (-not $abriu) { try { Start-Process notepad.exe -ArgumentList "`"$destinoRel`"" } catch { } }
    }
    [void][System.Windows.Forms.MessageBox]::Show("Tudo pronto.`n`nO relatório final foi salvo na Área de Trabalho. O programa será fechado e removido deste PC em instantes.", 'HS-Tech | Central de Ferramentas', 'OK', 'Information')
    # So agora inicia a remocao: o processo separado espera esta janela fechar antes de apagar
    Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c ' + ($cmds -join ' & ')) -WindowStyle Hidden
    $script:EncerrarAposAcao = $true
}

# ============================================================
#  INTERFACE GRAFICA
# ============================================================
$script:ItensLargos = New-Object System.Collections.ArrayList

function Executar-Acao {
    param([scriptblock]$Bloco)
    if ($script:Ocupado) { Log 'Aguarde: outra tarefa está em andamento.' Yellow; return }
    $script:Ocupado = $true
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    foreach ($b in $script:Botoes) { $b.Enabled = $false }
    try { & $Bloco }
    catch { Log "Erro: $($_.Exception.Message)" Red }
    finally {
        foreach ($b in $script:Botoes) { $b.Enabled = $true }
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
        Definir-Progresso 0
        $script:Ocupado = $false
        if ($script:EncerrarAposAcao) { $script:Form.Close() }
    }
}

function Ativar-DoubleBuffer {
    param($Ctl)
    try {
        $Ctl.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($Ctl, $true, $null)
    } catch { }
}

function Ajustar-Larguras {
    # Faz secoes, linhas e cartoes acompanharem a largura da janela
    foreach ($c in $script:ItensLargos) {
        if ($null -ne $c.Parent) {
            $largura = $c.Parent.ClientSize.Width - $c.Parent.Padding.Horizontal - 24
            if ($largura -gt 480) { $c.Width = [int]$largura }
        }
    }
}

function Novo-Label {
    param([string]$Texto, [double]$Tam = 10, [string]$CorHex = '#EAF4FF', [string]$NomeFonte = 'Segoe UI', [string]$Estilo = 'Regular', [int]$Largura = 780)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Texto
    $l.AutoSize = $true
    $l.MaximumSize = New-Object System.Drawing.Size($Largura, 0)
    $l.Font = (Fonte $NomeFonte $Tam $Estilo)
    $l.ForeColor = (ParaCor $CorHex)
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    return $l
}

# ---------- Tile de acao (titulo + descricao + faixa de cor) ----------
function Achar-Botao {
    param($Ctl)
    $c = $Ctl
    while ($null -ne $c -and -not ($c.Tag -is [scriptblock])) { $c = $c.Parent }
    return $c
}

function Destacar-Botao {
    param($Ctl, [bool]$Sobre)
    $b = Achar-Botao $Ctl
    if ($null -eq $b -or -not $b.Enabled) { return }
    $inner = $b.Controls[0]
    if ($Sobre) {
        $b.BackColor = (ParaCor ([string]$inner.Tag))
        $inner.BackColor = (ParaCor $script:Paleta.Hover)
    } else {
        $b.BackColor = (ParaCor $script:Paleta.Borda)
        $inner.BackColor = (ParaCor $script:Paleta.Painel)
    }
}

function Novo-Botao {
    param([string]$Texto, [scriptblock]$Acao, [string]$CorHex = '', [int]$L = 272, [int]$A = 78)
    if (-not $CorHex) { $CorHex = $script:Paleta.Neon }
    $partes = $Texto -split "`n", 2
    $titulo = $partes[0]
    $desc = ''
    if ($partes.Count -gt 1) { $desc = $partes[1] }

    $outer = New-Object System.Windows.Forms.Panel
    $outer.Size = New-Object System.Drawing.Size($L, $A)
    $outer.BackColor = (ParaCor $script:Paleta.Borda)
    $outer.Padding = New-Object System.Windows.Forms.Padding(1)
    $outer.Margin = New-Object System.Windows.Forms.Padding(0, 0, 14, 14)
    $outer.Cursor = [System.Windows.Forms.Cursors]::Hand
    $outer.Tag = $Acao

    $inner = New-Object System.Windows.Forms.Panel
    $inner.Dock = 'Fill'
    $inner.BackColor = (ParaCor $script:Paleta.Painel)
    $inner.Tag = $CorHex
    $outer.Controls.Add($inner)

    $faixa = New-Object System.Windows.Forms.Panel
    $faixa.Dock = 'Left'
    $faixa.Width = 4
    $faixa.BackColor = (ParaCor $CorHex)
    $inner.Controls.Add($faixa)

    $lt = New-Object System.Windows.Forms.Label
    $lt.Text = $titulo
    $lt.AutoSize = $false
    $lt.AutoEllipsis = $true
    $lt.Location = New-Object System.Drawing.Point(18, 12)
    $lt.Size = New-Object System.Drawing.Size(($L - 38), 22)
    $lt.Font = (Fonte 'Segoe UI Semibold' 10.5 'Regular')
    $lt.ForeColor = (ParaCor $script:Paleta.Texto)
    $lt.BackColor = [System.Drawing.Color]::Transparent
    $inner.Controls.Add($lt)

    $ld = New-Object System.Windows.Forms.Label
    $ld.Text = $desc
    $ld.AutoSize = $false
    $ld.Location = New-Object System.Drawing.Point(18, 36)
    $ld.Size = New-Object System.Drawing.Size(($L - 38), ($A - 44))
    $ld.Font = (Fonte 'Segoe UI' 8.5 'Regular')
    $ld.ForeColor = (ParaCor $script:Paleta.Mudo)
    $ld.BackColor = [System.Drawing.Color]::Transparent
    $inner.Controls.Add($ld)

    foreach ($c in @($outer, $inner, $faixa, $lt, $ld)) {
        $c.Cursor = [System.Windows.Forms.Cursors]::Hand
        $c.Add_Click({ param($s, $e) $b = Achar-Botao $s; if ($null -ne $b) { Executar-Acao $b.Tag } })
        $c.Add_MouseEnter({ param($s, $e) Destacar-Botao $s $true })
        $c.Add_MouseLeave({ param($s, $e) Destacar-Botao $s $false })
    }
    [void]$script:Botoes.Add($outer)
    return $outer
}

function Novo-BotaoPequeno {
    param([string]$Texto, [scriptblock]$Acao, [string]$CorHex = '', [int]$L = 140, [int]$A = 36)
    if (-not $CorHex) { $CorHex = $script:Paleta.Neon }
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Texto
    $b.Size = New-Object System.Drawing.Size($L, $A)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = (ParaCor $CorHex)
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.MouseOverBackColor = (ParaCor $script:Paleta.Hover)
    $b.BackColor = (ParaCor $script:Paleta.Painel)
    $b.ForeColor = (ParaCor $script:Paleta.Texto)
    $b.Font = (Fonte 'Segoe UI Semibold' 9 'Regular')
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Add_Click($Acao)
    return $b
}

# ---------- Cartao de formulario (borda + titulo) ----------
function Novo-Cartao {
    param([string]$Titulo, [int]$A = 100, [int]$L = 880)
    $outer = New-Object System.Windows.Forms.Panel
    $outer.Size = New-Object System.Drawing.Size($L, $A)
    $outer.BackColor = (ParaCor $script:Paleta.Borda)
    $outer.Padding = New-Object System.Windows.Forms.Padding(1)
    $outer.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 16)
    $inner = New-Object System.Windows.Forms.Panel
    $inner.Dock = 'Fill'
    $inner.BackColor = (ParaCor $script:Paleta.Painel)
    $outer.Controls.Add($inner)
    if ($Titulo) {
        $t = New-Object System.Windows.Forms.Label
        $t.Text = $Titulo
        $t.AutoSize = $true
        $t.Font = (Fonte 'Segoe UI Semibold' 8.5 'Regular')
        $t.ForeColor = (ParaCor $script:Paleta.Cian)
        $t.Location = New-Object System.Drawing.Point(18, 14)
        $inner.Controls.Add($t)
    }
    [void]$script:ItensLargos.Add($outer)
    return @{ Outer = $outer; Corpo = $inner }
}

function Novo-Campo {
    param($Pai, [string]$Rotulo, [int]$X)
    $r = New-Object System.Windows.Forms.Label
    $r.Text = $Rotulo
    $r.AutoSize = $true
    $r.Font = (Fonte 'Segoe UI' 8.5 'Regular')
    $r.ForeColor = (ParaCor $script:Paleta.Mudo)
    $r.Location = New-Object System.Drawing.Point($X, 40)
    $Pai.Controls.Add($r)
    $v = New-Object System.Windows.Forms.Label
    $v.Text = '--'
    $v.AutoSize = $false
    $v.AutoEllipsis = $true
    $v.Size = New-Object System.Drawing.Size(210, 24)
    $v.Font = (Fonte 'Segoe UI Semibold' 10.5 'Regular')
    $v.ForeColor = (ParaCor $script:Paleta.Texto)
    $v.Location = New-Object System.Drawing.Point($X, 58)
    $Pai.Controls.Add($v)
    return $v
}

# ---------- Card de metrica com barra ----------
function Novo-Card {
    param([string]$Titulo, [string]$CorHex)
    $outer = New-Object System.Windows.Forms.Panel
    $outer.Size = New-Object System.Drawing.Size(176, 106)
    $outer.BackColor = (ParaCor $script:Paleta.Borda)
    $outer.Padding = New-Object System.Windows.Forms.Padding(1)
    $outer.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)
    $inner = New-Object System.Windows.Forms.Panel
    $inner.Dock = 'Fill'
    $inner.BackColor = (ParaCor $script:Paleta.Painel)
    $outer.Controls.Add($inner)

    $t = New-Object System.Windows.Forms.Label
    $t.Text = $Titulo
    $t.AutoSize = $true
    $t.Font = (Fonte 'Segoe UI Semibold' 8.5 'Regular')
    $t.ForeColor = (ParaCor $script:Paleta.Mudo)
    $t.Location = New-Object System.Drawing.Point(16, 14)
    $inner.Controls.Add($t)

    $v = New-Object System.Windows.Forms.Label
    $v.Text = '--'
    $v.AutoSize = $true
    $v.Font = (Fonte 'Segoe UI Semibold' 20 'Regular')
    $v.ForeColor = (ParaCor $CorHex)
    $v.Location = New-Object System.Drawing.Point(14, 34)
    $inner.Controls.Add($v)

    $trilho = New-Object System.Windows.Forms.Panel
    $trilho.Location = New-Object System.Drawing.Point(16, 84)
    $trilho.Size = New-Object System.Drawing.Size(142, 5)
    $trilho.Anchor = 'Top,Left,Right'
    $trilho.BackColor = (ParaCor $script:Paleta.Trilho)
    $fill = New-Object System.Windows.Forms.Panel
    $fill.Dock = 'Left'
    $fill.Width = 0
    $fill.BackColor = (ParaCor $CorHex)
    $trilho.Controls.Add($fill)
    $inner.Controls.Add($trilho)

    return @{ Painel = $outer; Valor = $v; Barra = $fill; Trilho = $trilho; Cor = $CorHex }
}

function Nova-Pagina {
    param([string]$Nome, [string]$Titulo, [string]$Sub)
    $p = New-Object System.Windows.Forms.FlowLayoutPanel
    $p.Dock = 'Fill'
    $p.AutoScroll = $true
    $p.Padding = New-Object System.Windows.Forms.Padding(30, 24, 18, 18)
    $p.BackColor = (ParaCor $script:Paleta.Fundo)
    $p.Visible = $false
    Ativar-DoubleBuffer $p
    $t = Novo-Label $Titulo 20 $script:Paleta.Texto 'Segoe UI Semibold' 'Regular'
    $t.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 2)
    $p.Controls.Add($t); $p.SetFlowBreak($t, $true)
    $s = Novo-Label $Sub 9.5 $script:Paleta.Mudo 'Segoe UI' 'Regular' 900
    $s.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)
    $p.Controls.Add($s); $p.SetFlowBreak($s, $true)
    $linha = New-Object System.Windows.Forms.Panel
    $linha.Height = 1; $linha.Width = 880
    $linha.BackColor = (ParaCor $script:Paleta.Borda)
    $linha.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)
    $p.Controls.Add($linha); $p.SetFlowBreak($linha, $true)
    [void]$script:ItensLargos.Add($linha)
    $script:Paginas[$Nome] = $p
    $script:Conteudo.Controls.Add($p)
    return $p
}

function Nova-Secao {
    param($Pagina, [string]$Texto)
    $c = New-Object System.Windows.Forms.Panel
    $c.Height = 30; $c.Width = 880
    $c.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 8)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Texto
    $l.AutoSize = $true
    $l.Font = (Fonte 'Segoe UI Semibold' 8.5 'Regular')
    $l.ForeColor = (ParaCor $script:Paleta.Cian)
    $l.Location = New-Object System.Drawing.Point(0, 7)
    $c.Controls.Add($l)
    $ln = New-Object System.Windows.Forms.Panel
    $ln.Dock = 'Bottom'; $ln.Height = 1
    $ln.BackColor = (ParaCor $script:Paleta.Borda)
    $c.Controls.Add($ln)
    $Pagina.Controls.Add($c); $Pagina.SetFlowBreak($c, $true)
    [void]$script:ItensLargos.Add($c)
}

function Mostrar-Pagina {
    param([string]$Nome)
    foreach ($k in @($script:Paginas.Keys)) { $script:Paginas[$k].Visible = ($k -eq $Nome) }
    foreach ($b in $script:NavBotoes) {
        if ($b.Tag -eq $Nome) {
            $b.ForeColor = (ParaCor $script:Paleta.Neon)
            $b.BackColor = (ParaCor $script:Paleta.Hover)
            $b.Font = $script:FonteNavAtiva
            $script:NavInd.Top = $b.Top
            $script:NavInd.Visible = $true
            $script:NavInd.BringToFront()
        } else {
            $b.ForeColor = (ParaCor $script:Paleta.Texto)
            $b.BackColor = (ParaCor $script:Paleta.Lateral)
            $b.Font = $script:FonteNav
        }
    }
    Ajustar-Larguras
}

# ============================================================
#  JANELA PRINCIPAL
# ============================================================
$script:FonteNav = (Fonte 'Segoe UI' 10 'Regular')
$script:FonteNavAtiva = (Fonte 'Segoe UI Semibold' 10 'Regular')

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'HS-Tech | Central de Ferramentas'
$script:Form.Icon = [System.Drawing.SystemIcons]::Shield
$areaUtil = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$larguraJanela = [int][math]::Min(1420, $areaUtil.Width - 24)
$alturaJanela = [int][math]::Min(900, $areaUtil.Height - 24)
$larguraMin = [int][math]::Min(1180, $larguraJanela)
$alturaMin = [int][math]::Min(760, $alturaJanela)
$script:Form.MinimumSize = New-Object System.Drawing.Size($larguraMin, $alturaMin)
$script:Form.Size = New-Object System.Drawing.Size($larguraJanela, $alturaJanela)
$script:Form.StartPosition = 'CenterScreen'
$script:Form.BackColor = (ParaCor $script:Paleta.Fundo)
$script:Form.ForeColor = (ParaCor $script:Paleta.Texto)
$script:Form.Font = (Fonte 'Segoe UI' 9.5 'Regular')
Ativar-DoubleBuffer $script:Form

$script:Conteudo = New-Object System.Windows.Forms.Panel
$script:Conteudo.Dock = 'Fill'
$script:Conteudo.BackColor = (ParaCor $script:Paleta.Fundo)
$script:Form.Controls.Add($script:Conteudo)

# ---------- Barra lateral ----------
$lateral = New-Object System.Windows.Forms.Panel
$lateral.Dock = 'Left'
$lateral.Width = 224
$lateral.BackColor = (ParaCor $script:Paleta.Lateral)
$script:Form.Controls.Add($lateral)

$bordaLateral = New-Object System.Windows.Forms.Panel
$bordaLateral.Dock = 'Right'
$bordaLateral.Width = 1
$bordaLateral.BackColor = (ParaCor $script:Paleta.Borda)
$lateral.Controls.Add($bordaLateral)

# ---------- Rodape: registro de atividades ----------
$rodape = New-Object System.Windows.Forms.Panel
$rodape.Dock = 'Bottom'
$rodape.Height = 36
$rodape.Tag = 'Recolhido'
$rodape.BackColor = (ParaCor '#050C16')
$script:Form.Controls.Add($rodape)

$script:TxtLog = New-Object System.Windows.Forms.RichTextBox
$script:TxtLog.Dock = 'Fill'
$script:TxtLog.ReadOnly = $true
$script:TxtLog.BorderStyle = 'None'
$script:TxtLog.BackColor = (ParaCor '#050C16')
$script:TxtLog.ForeColor = (ParaCor '#A9BBD0')
$script:TxtLog.Font = (Fonte 'Consolas' 9 'Regular')
$script:TxtLog.Visible = $false
$rodape.Controls.Add($script:TxtLog)

$barraLog = New-Object System.Windows.Forms.Panel
$barraLog.Dock = 'Top'
$barraLog.Height = 30
$barraLog.BackColor = (ParaCor '#0A1626')
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = 'REGISTRO DE ATIVIDADES  [+]'
$lblLog.Cursor = [System.Windows.Forms.Cursors]::Hand
$lblLog.AutoSize = $true
$lblLog.Font = (Fonte 'Segoe UI Semibold' 8.5 'Regular')
$lblLog.ForeColor = (ParaCor $script:Paleta.Mudo)
$lblLog.Location = New-Object System.Drawing.Point(20, 8)
$barraLog.Controls.Add($lblLog)
$alternarLog = {
    if ($rodape.Tag -eq 'Recolhido') {
        $rodape.Height = 170
        $rodape.Tag = 'Expandido'
        $script:TxtLog.Visible = $true
        $lblLog.Text = 'REGISTRO DE ATIVIDADES  [-]'
    } else {
        $rodape.Height = 36
        $rodape.Tag = 'Recolhido'
        $script:TxtLog.Visible = $false
        $lblLog.Text = 'REGISTRO DE ATIVIDADES  [+]'
    }
}
$lblLog.Add_Click($alternarLog)
$barraLog.Add_Click($alternarLog)
$btnLimparLog = New-Object System.Windows.Forms.Button
$btnLimparLog.Text = 'LIMPAR'
$btnLimparLog.Dock = 'Right'
$btnLimparLog.Width = 90
$btnLimparLog.FlatStyle = 'Flat'
$btnLimparLog.FlatAppearance.BorderSize = 0
$btnLimparLog.FlatAppearance.MouseOverBackColor = (ParaCor $script:Paleta.Hover)
$btnLimparLog.ForeColor = (ParaCor $script:Paleta.Mudo)
$btnLimparLog.Font = (Fonte 'Segoe UI Semibold' 8.5 'Regular')
$btnLimparLog.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnLimparLog.Add_Click({ $script:TxtLog.Clear() })
$barraLog.Controls.Add($btnLimparLog)
$rodape.Controls.Add($barraLog)

$script:BarraFundo = New-Object System.Windows.Forms.Panel
$script:BarraFundo.Dock = 'Top'
$script:BarraFundo.Height = 4
$script:BarraFundo.BackColor = (ParaCor $script:Paleta.Trilho)
$script:BarraFill = New-Object System.Windows.Forms.Panel
$script:BarraFill.Dock = 'Left'
$script:BarraFill.Width = 0
$script:BarraFill.BackColor = (ParaCor $script:Paleta.Neon)
$script:BarraFundo.Controls.Add($script:BarraFill)
$rodape.Controls.Add($script:BarraFundo)

# ---------- Cabecalho ----------
$script:Cabecalho = New-Object System.Windows.Forms.Panel
$script:Cabecalho.Dock = 'Top'
$script:Cabecalho.Height = 76
$script:Cabecalho.BackColor = (ParaCor $script:Paleta.Lateral)

$linhaCab = New-Object System.Windows.Forms.Panel
$linhaCab.Dock = 'Bottom'; $linhaCab.Height = 1
$linhaCab.BackColor = (ParaCor $script:Paleta.Borda)
$script:Cabecalho.Controls.Add($linhaCab)

$marca = New-Object System.Windows.Forms.Panel
$marca.Size = New-Object System.Drawing.Size(6, 38)
$marca.Location = New-Object System.Drawing.Point(26, 17)
$marca.BackColor = (ParaCor $script:Paleta.Neon)
$script:Cabecalho.Controls.Add($marca)

$lblT1 = New-Object System.Windows.Forms.Label
$lblT1.Text = 'HS-TECH'
$lblT1.AutoSize = $true
$lblT1.Font = (Fonte 'Segoe UI Black' 17 'Regular')
$lblT1.ForeColor = (ParaCor $script:Paleta.Texto)
$lblT1.Location = New-Object System.Drawing.Point(42, 10)
$script:Cabecalho.Controls.Add($lblT1)

$lblT2 = New-Object System.Windows.Forms.Label
$lblT2.Text = 'CENTRAL'
$lblT2.AutoSize = $true
$lblT2.Font = (Fonte 'Segoe UI Black' 17 'Regular')
$lblT2.ForeColor = (ParaCor $script:Paleta.Neon)
$lblT2.Location = New-Object System.Drawing.Point((42 + $lblT1.PreferredWidth + 4), 10)
$script:Cabecalho.Controls.Add($lblT2)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = 'Desempenho • diagnóstico • manutenção inteligente do Windows'
$lblSub.AutoSize = $true
$lblSub.Font = (Fonte 'Segoe UI' 9 'Regular')
$lblSub.ForeColor = (ParaCor $script:Paleta.Mudo)
$lblSub.Location = New-Object System.Drawing.Point(44, 44)
$script:Cabecalho.Controls.Add($lblSub)

$script:ChipAdmin = New-Object System.Windows.Forms.Label
$script:ChipAdmin.Text = ([string][char]0x25CF) + '  ADMINISTRADOR'
$script:ChipAdmin.AutoSize = $true
$script:ChipAdmin.Font = (Fonte 'Segoe UI Semibold' 8.5 'Regular')
$script:ChipAdmin.ForeColor = (ParaCor $script:Paleta.Neon)
$script:ChipAdmin.Location = New-Object System.Drawing.Point(700, 20)
$script:Cabecalho.Controls.Add($script:ChipAdmin)

$script:ChipVer = New-Object System.Windows.Forms.Label
$script:ChipVer.Text = 'Versão 3.6.0'
$script:ChipVer.AutoSize = $true
$script:ChipVer.Font = (Fonte 'Segoe UI' 8.5 'Regular')
$script:ChipVer.ForeColor = (ParaCor $script:Paleta.Mudo)
$script:ChipVer.Location = New-Object System.Drawing.Point(700, 42)
$script:Cabecalho.Controls.Add($script:ChipVer)

$script:Cabecalho.Add_Resize({
    $script:ChipAdmin.Left = $script:Cabecalho.Width - $script:ChipAdmin.Width - 30
    $script:ChipVer.Left = $script:Cabecalho.Width - $script:ChipVer.Width - 30
})
$script:Form.Controls.Add($script:Cabecalho)

# ---------- Navegacao agrupada ----------
$entradasNav = @(
    @('G', 'VISÃO GERAL'),
    @('N', 'inicio', 'Painel'),
    @('G', 'OTIMIZAÇÃO'),
    @('N', 'desempenho', 'Desempenho'),
    @('N', 'disco', 'Disco'),
    @('N', 'rede', 'Rede'),
    @('N', 'drivers', 'Drivers'),
    @('N', 'diag', 'Diagnóstico'),
    @('G', 'JOGOS'),
    @('N', 'jogos', 'Perfis por jogo'),
    @('N', 'backup', 'Backup e restauração'),
    @('N', 'programas', 'Programas'),
    @('N', 'monitor', 'Monitor e alertas'),
    @('G', 'AUTOMAÇÃO'),
    @('N', 'agenda', 'Agendar e relatórios')
)
$y = 14
foreach ($en in $entradasNav) {
    if ($en[0] -eq 'G') {
        if ($y -gt 14) { $y += 6 }
        $g = New-Object System.Windows.Forms.Label
        $g.Text = $en[1]
        $g.AutoSize = $true
        $g.Font = (Fonte 'Segoe UI Semibold' 7.5 'Regular')
        $g.ForeColor = (ParaCor $script:Paleta.Mudo)
        $g.Location = New-Object System.Drawing.Point(26, $y)
        $lateral.Controls.Add($g)
        $y += 20
    } else {
        $nb = New-Object System.Windows.Forms.Button
        $nb.Text = $en[2]
        $nb.Tag = $en[1]
        $nb.Location = New-Object System.Drawing.Point(0, $y)
        $nb.Size = New-Object System.Drawing.Size(223, 32)
        $nb.FlatStyle = 'Flat'
        $nb.FlatAppearance.BorderSize = 0
        $nb.FlatAppearance.MouseOverBackColor = (ParaCor $script:Paleta.Hover)
        $nb.BackColor = (ParaCor $script:Paleta.Lateral)
        $nb.ForeColor = (ParaCor $script:Paleta.Texto)
        $nb.Font = $script:FonteNav
        $nb.TextAlign = 'MiddleLeft'
        $nb.Padding = New-Object System.Windows.Forms.Padding(26, 0, 0, 0)
        $nb.Cursor = [System.Windows.Forms.Cursors]::Hand
        $nb.Add_Click({ param($s, $e) Mostrar-Pagina $s.Tag })
        $lateral.Controls.Add($nb)
        [void]$script:NavBotoes.Add($nb)
        $y += 33
    }
}
$script:NavInd = New-Object System.Windows.Forms.Panel
$script:NavInd.Size = New-Object System.Drawing.Size(4, 32)
$script:NavInd.BackColor = (ParaCor $script:Paleta.Neon)
$script:NavInd.Visible = $false
$lateral.Controls.Add($script:NavInd)

$lblVersao = New-Object System.Windows.Forms.Label
$lblVersao.Text = 'HS-TECH  |  Central de Ferramentas v3.6.0'
$lblVersao.AutoSize = $false
$lblVersao.Dock = 'Bottom'
$lblVersao.Height = 32
$lblVersao.TextAlign = 'MiddleLeft'
$lblVersao.Padding = New-Object System.Windows.Forms.Padding(26, 0, 0, 0)
$lblVersao.Font = (Fonte 'Segoe UI' 8 'Regular')
$lblVersao.ForeColor = (ParaCor $script:Paleta.Mudo)
$lateral.Controls.Add($lblVersao)

# ============================================================
#  PAGINA: PAINEL
# ============================================================
$pgInicio = Nova-Pagina 'inicio' 'Painel' 'Acompanhe o computador em tempo real e execute as principais ações com segurança.'
Nova-Secao $pgInicio 'MONITORAMENTO EM TEMPO REAL'
$script:CardCPU   = Novo-Card 'CPU' $script:Paleta.Neon
$script:CardRAM   = Novo-Card 'MEMÓRIA RAM' $script:Paleta.Cian
$script:CardGPU   = Novo-Card 'GPU (NVIDIA)' $script:Paleta.Rosa
$script:CardTemp  = Novo-Card 'TEMPERATURA CPU / GPU' $script:Paleta.Amarelo
$script:CardDisco = Novo-Card 'ESPAÇO NO SISTEMA' $script:Paleta.Neon

$script:LinhaCards = New-Object System.Windows.Forms.TableLayoutPanel
$script:LinhaCards.ColumnCount = 5
$script:LinhaCards.RowCount = 1
$script:LinhaCards.Height = 106
$script:LinhaCards.Width = 880
$script:LinhaCards.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 16)
for ($i = 0; $i -lt 5; $i++) {
    [void]$script:LinhaCards.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 20)))
}
[void]$script:LinhaCards.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$listaCards = @($script:CardCPU, $script:CardRAM, $script:CardGPU, $script:CardTemp, $script:CardDisco)
for ($i = 0; $i -lt 5; $i++) {
    $listaCards[$i].Painel.Dock = 'Fill'
    $script:LinhaCards.Controls.Add($listaCards[$i].Painel, $i, 0)
}
$pgInicio.Controls.Add($script:LinhaCards)
$pgInicio.SetFlowBreak($script:LinhaCards, $true)
[void]$script:ItensLargos.Add($script:LinhaCards)

$estado = Novo-Cartao 'ESTADO ATUAL' 98
$script:LblPlano    = Novo-Campo $estado.Corpo 'Plano de energia' 18
$script:LblModoPerf = Novo-Campo $estado.Corpo 'Modo Performance' 250
$script:LblDeteccao = Novo-Campo $estado.Corpo 'Detecção de jogos' 482
$script:LblPerm     = Novo-Campo $estado.Corpo 'Permissões' 714
$script:LblPerm.Text = 'Administrador'
$pgInicio.Controls.Add($estado.Outer)
$pgInicio.SetFlowBreak($estado.Outer, $true)

Nova-Secao $pgInicio 'AÇÕES RÁPIDAS'
$btnTudo = Novo-Botao "Executar manutenção recomendada`nLimpeza segura, energia, Modo Jogo, rede, disco e relatório antes/depois" { Executar-Tudo } $script:Paleta.Neon 558 84
$pgInicio.Controls.Add($btnTudo)
$pgInicio.SetFlowBreak($btnTudo, $true)
$pgInicio.Controls.Add((Novo-Botao "Criar ponto de restauração`nSalva o estado do Windows antes de ajustar" { Criar-PontoRestauracao } $script:Paleta.Cian))
$pgInicio.Controls.Add((Novo-Botao "Desfazer ajustes`nVolta registro, plano de energia e DNS" { Desfazer-Ajustes } $script:Paleta.Rosa))

# ============================================================

# ============================================================
#  PAGINA: BACKUP E RESTAURACAO
# ============================================================
$pgBackup=Nova-Pagina 'backup' 'Backup e restauração' 'Salve dados antes de formatar e restaure depois.'
Nova-Secao $pgBackup 'SELECIONE O QUE DESEJA SALVAR'
$script:BackupChecks=@{}
$catsPanel=New-Object Windows.Forms.FlowLayoutPanel;$catsPanel.Width=900;$catsPanel.Height=78;$catsPanel.WrapContents=$true
foreach($cat in @('Fotos','Videos','Documentos','Musicas','Compactados','Projetos','Pastas pessoais','Jogos e saves')){$cb=New-Object Windows.Forms.CheckBox;$cb.Text=$cat;$cb.Checked=($cat -in @('Fotos','Videos','Documentos','Compactados','Projetos','Pastas pessoais','Jogos e saves'));$cb.AutoSize=$true;$cb.Margin=New-Object Windows.Forms.Padding(8,7,15,7);$cb.ForeColor=ParaCor $script:Paleta.Texto;$catsPanel.Controls.Add($cb);$script:BackupChecks[$cat]=$cb}
$pgBackup.Controls.Add($catsPanel);$pgBackup.SetFlowBreak($catsPanel,$true)
$warn=Novo-Label 'Busca nas pastas do usuário e locais comuns de saves. Jogos podem usar caminhos personalizados; confira o resultado antes de formatar.' 9 $script:Paleta.Amarelo 'Segoe UI' 'Regular' 900;$pgBackup.Controls.Add($warn);$pgBackup.SetFlowBreak($warn,$true)
$line=New-Object Windows.Forms.Panel;$line.Width=900;$line.Height=42
$b=Novo-BotaoPequeno 'ESCOLHER DESTINO' {Escolher-DestinoBackup} $script:Paleta.Cian 150 34;$b.Location=New-Object Drawing.Point(0,2);$line.Controls.Add($b)
$b=Novo-BotaoPequeno 'CRIAR PARTIÇÃO' {Criar-ParticaoBackup} $script:Paleta.Rosa 135 34;$b.Location=New-Object Drawing.Point(155,2);$line.Controls.Add($b)
$b=Novo-BotaoPequeno 'ANALISAR TAMANHO' {Analisar-Backup} $script:Paleta.Neon 155 34;$b.Location=New-Object Drawing.Point(295,2);$line.Controls.Add($b)
$b=Novo-BotaoPequeno 'FAZER BACKUP' {Analisar-Backup;Fazer-Backup} $script:Paleta.Neon 130 34;$b.Location=New-Object Drawing.Point(455,2);$line.Controls.Add($b)
$b=Novo-BotaoPequeno 'RESTAURAR BACKUP' {Restaurar-Backup} $script:Paleta.Cian 155 34;$b.Location=New-Object Drawing.Point(590,2);$line.Controls.Add($b)
$pgBackup.Controls.Add($line);$pgBackup.SetFlowBreak($line,$true)
$script:BackupDestino=$null;$script:BackupFiles=@();$script:BackupBytes=0L
$script:BackupDestinoLabel=Novo-Label 'Destino: não selecionado' 9 $script:Paleta.Mudo 'Segoe UI' 'Regular' 900;$pgBackup.Controls.Add($script:BackupDestinoLabel);$pgBackup.SetFlowBreak($script:BackupDestinoLabel,$true)
$script:BackupEstado=Novo-Label 'Escolha as categorias, destino e analise o tamanho antes de copiar.' 10 $script:Paleta.Texto 'Segoe UI' 'Regular' 900;$pgBackup.Controls.Add($script:BackupEstado);$pgBackup.SetFlowBreak($script:BackupEstado,$true)
$warn2=Novo-Label 'Importante: uma partição no mesmo disco NÃO protege contra formatação do disco inteiro ou falha física. Para clientes, prefira HD/SSD externo. A restauração procura backups nas raízes dos discos conectados.' 9 $script:Paleta.Amarelo 'Segoe UI' 'Regular' 900;$pgBackup.Controls.Add($warn2);$pgBackup.SetFlowBreak($warn2,$true)

# ============================================================
#  PAGINA: PROGRAMAS
# ============================================================
$pgProgramas=Nova-Pagina 'programas' 'Programas' 'Biblioteca local de ferramentas e instaladores da pasta programas.'
Nova-Secao $pgProgramas 'BIBLIOTECA DE PROGRAMAS'
$lblAjudaProgramas=Novo-Label 'Adicione qualquer arquivo ou programa pela pasta ou botão ADICIONAR ARQUIVOS. Itens desconhecidos e scripts exibem confirmação antes de executar.' 9 $script:Paleta.Mudo 'Segoe UI' 'Regular' 900
$pgProgramas.Controls.Add($lblAjudaProgramas);$pgProgramas.SetFlowBreak($lblAjudaProgramas,$true)
$linhaProgramas=New-Object System.Windows.Forms.Panel;$linhaProgramas.Width=900;$linhaProgramas.Height=44
$txtBuscaProgramas=New-Object System.Windows.Forms.TextBox;$txtBuscaProgramas.Location=New-Object System.Drawing.Point(0,4);$txtBuscaProgramas.Size=New-Object System.Drawing.Size(245,30);$txtBuscaProgramas.Font=(Fonte 'Segoe UI' 10 'Regular');$txtBuscaProgramas.BackColor=(ParaCor $script:Paleta.Painel);$txtBuscaProgramas.ForeColor=(ParaCor $script:Paleta.Texto);$linhaProgramas.Controls.Add($txtBuscaProgramas)
$btnPastaProgramas=Novo-BotaoPequeno 'IMPORTAR PASTA' {Adicionar-PastaProgramas} $script:Paleta.Neon 130 34;$btnPastaProgramas.Location=New-Object System.Drawing.Point(255,2);$linhaProgramas.Controls.Add($btnPastaProgramas)
$btnAdicionarArquivos=Novo-BotaoPequeno 'ADICIONAR ARQUIVOS' {Adicionar-ArquivosProgramas} $script:Paleta.Rosa 145 34;$btnAdicionarArquivos.Location=New-Object System.Drawing.Point(390,2);$linhaProgramas.Controls.Add($btnAdicionarArquivos)
$btnAutoProgramas=Novo-BotaoPequeno 'LOCALIZAR HS-TECH' {Importar-PastaProgramasLocal} $script:Paleta.Cian 145 34;$btnAutoProgramas.Location=New-Object System.Drawing.Point(540,2);$linhaProgramas.Controls.Add($btnAutoProgramas)
$btnAtualizarProgramas=Novo-BotaoPequeno 'ATUALIZAR LISTA' {Atualizar-ListaProgramas} $script:Paleta.Neon 130 34;$btnAtualizarProgramas.Location=New-Object System.Drawing.Point(690,2);$linhaProgramas.Controls.Add($btnAtualizarProgramas)
$pgProgramas.Controls.Add($linhaProgramas);$pgProgramas.SetFlowBreak($linhaProgramas,$true)
$listaProgramas=New-Object System.Windows.Forms.ListView;$listaProgramas.View='Details';$listaProgramas.FullRowSelect=$true;$listaProgramas.GridLines=$true;$listaProgramas.Size=New-Object System.Drawing.Size(900,390);$listaProgramas.BackColor=(ParaCor $script:Paleta.Painel);$listaProgramas.ForeColor=(ParaCor $script:Paleta.Texto)
[void]$listaProgramas.Columns.Add('Arquivo',220);[void]$listaProgramas.Columns.Add('Tipo',145);[void]$listaProgramas.Columns.Add('Segurança',150);[void]$listaProgramas.Columns.Add('Caminho',375)
$pgProgramas.Controls.Add($listaProgramas);$pgProgramas.SetFlowBreak($listaProgramas,$true)
$btnAbrirPrograma=Novo-Botao 'ABRIR / EXECUTAR SELECIONADO - confirmação antes de executar' {Abrir-ProgramaSelecionado} $script:Paleta.Neon 340 70
$btnRemoverPrograma=Novo-Botao 'Remover da biblioteca - preserva o arquivo original' {Remover-ProgramaSelecionado} $script:Paleta.Rosa 280 70
$pgProgramas.Controls.Add($btnAbrirPrograma);$pgProgramas.Controls.Add($btnRemoverPrograma)
$script:ListaProgramasUI=$listaProgramas;$script:BuscaProgramasUI=$txtBuscaProgramas;$script:BuscaProgramasUI.Add_TextChanged({Atualizar-ListaProgramas})
Atualizar-ListaProgramas
Importar-PastaProgramasLocal

#  PAGINA: DESEMPENHO
# ============================================================
$pgDes = Nova-Pagina 'desempenho' 'Desempenho' 'Limpeza, energia, Modo Jogo e ajustes do sistema para ganhar FPS e estabilidade.'
Nova-Secao $pgDes 'LIMPEZA E ENERGIA'
$pgDes.Controls.Add((Novo-Botao "Analisar memoria e processos`nVeja os maiores consumidores de RAM e feche apenas os selecionados" { Gerenciar-MemoriaProcessos } $script:Paleta.Cian))
$pgDes.Controls.Add((Novo-Botao "Limpar temporários`nPreserva o cache de shaders e a Lixeira" { Limpar-Temporarios }))
$pgDes.Controls.Add((Novo-Botao "Limpar cache dos navegadores`nChrome, Edge, Brave e Firefox (senhas preservadas)" { Limpar-Navegadores }))
$pgDes.Controls.Add((Novo-Botao "Plano Alto desempenho`nAtiva o plano de energia de alto desempenho" { Ajustar-Energia }))
$pgDes.Controls.Add((Novo-Botao "Plano Desempenho máximo`nPlano oculto do Windows, sem economia de energia" { Ativar-DesempenhoMaximo } $script:Paleta.Rosa))
$pgDes.Controls.Add((Novo-Botao "Modo Jogo do Windows`nAtiva o Modo Jogo e desliga a captura em segundo plano" { Ajustar-ModoJogo }))
Nova-Secao $pgDes 'PERFIS DE ENERGIA'
$pgDes.Controls.Add((Novo-Botao "Perfil Jogos`nAlto desempenho, quando disponível" { Aplicar-Perfil 'Jogos' } $script:Paleta.Rosa))
$pgDes.Controls.Add((Novo-Botao "Perfil Desempenho máximo`nMáximo possível: mais consumo e calor" { Aplicar-Perfil 'Maximo' } $script:Paleta.Rosa))
$pgDes.Controls.Add((Novo-Botao "Perfil Equilibrado`nUso diário com consumo moderado" { Aplicar-Perfil 'Equilibrado' } $script:Paleta.Cian))
$pgDes.Controls.Add((Novo-Botao "Perfil Economia`nReduz o consumo, quando disponível" { Aplicar-Perfil 'Economia' } $script:Paleta.Amarelo))
Nova-Secao $pgDes 'MODO PERFORMANCE'
$pgDes.Controls.Add((Novo-Botao "Modo Performance: ligar`nFecha apps de fundo e ativa alto desempenho" { Entrar-ModoPerformance } $script:Paleta.Rosa))
$pgDes.Controls.Add((Novo-Botao "Modo Performance: desligar`nRestaura o plano de energia anterior" { Sair-ModoPerformance } $script:Paleta.Rosa))
$pgDes.Controls.Add((Novo-Botao "Liberar RAM em espera`nLimpa a lista de espera da memória" { Liberar-RAM } $script:Paleta.Rosa))
Nova-Secao $pgDes 'AJUSTES AVANÇADOS (PEDEM CONFIRMAÇÃO)'
$pgDes.Controls.Add((Novo-Botao "GPU e efeitos visuais`nHAGS, menos animações e transparência" { Ajustar-GPUSistema } $script:Paleta.Cian))
$pgDes.Controls.Add((Novo-Botao "Horário ativo do Windows Update`nEvita reinício enquanto você joga" { Definir-HorarioAtivo } $script:Paleta.Cian))
$pgDes.Controls.Add((Novo-Botao "Remover bloatware`nEscolha os apps inúteis que deseja remover" { Remover-Bloatware } $script:Paleta.Amarelo))
Nova-Secao $pgDes 'INICIALIZAÇÃO E HARDWARE'
$pgDes.Controls.Add((Novo-Botao "Apps de inicialização`nLista o que abre junto com o Windows" { Listar-Inicializacao } $script:Paleta.Cian))
$pgDes.Controls.Add((Novo-Botao "Inicialização do Windows`nAbre as ferramentas nativas do Windows" { Abrir-GerenciadorInicializacao } $script:Paleta.Cian))
$pgDes.Controls.Add((Novo-Botao "Ativar ou desativar apps`nEscolha o que inicia com o Windows (reversível)" { Gerenciar-Inicializacao } $script:Paleta.Rosa))
$pgDes.Controls.Add((Novo-Botao "Resumo de hardware`nCPU, RAM, GPU e discos detectados" { Mostrar-ResumoHardware } $script:Paleta.Neon))
$pgDes.Controls.Add((Novo-Botao "Liberar todos os núcleos`nRemove limites de boot e desativa o core parking" { Liberar-Nucleos } $script:Paleta.Neon))

# ============================================================
#  PAGINA: DISCO
# ============================================================
$pgDisco = Nova-Pagina 'disco' 'Disco' 'Saúde, verificação, otimização e velocidade. TRIM em SSD e desfragmentação apenas em HDD.'
Nova-Secao $pgDisco 'DIAGNÓSTICO'
$pgDisco.Controls.Add((Novo-Botao "Saúde e espaço`nSMART, temperatura e desgaste" { Saude-Disco }))
$pgDisco.Controls.Add((Novo-Botao "Recomendações por unidade`nEspaço livre e tipo SSD/HDD" { Recomendar-Armazenamento } $script:Paleta.Cian))
$pgDisco.Controls.Add((Novo-Botao "Verificar erros`nVarredura somente leitura" { Verificar-Disco }))
$pgDisco.Controls.Add((Novo-Botao "Benchmark do disco`nVelocidade de leitura e escrita" { Benchmark-Disco } $script:Paleta.Cian))
Nova-Secao $pgDisco 'OTIMIZAÇÃO E REPARO'
$pgDisco.Controls.Add((Novo-Botao "Otimizar discos`nTRIM no SSD e desfragmentação no HDD" { Otimizar-Disco } $script:Paleta.Rosa))
$pgDisco.Controls.Add((Novo-Botao "Verificação com reparo`nAgenda o CHKDSK para a reinicialização" { Agendar-VerificacaoReparo } $script:Paleta.Rosa))
$pgDisco.Controls.Add((Novo-Botao "Arquivos do Windows (SFC)`nVerifica a integridade do sistema" { Verificar-ArquivosWindows } $script:Paleta.Rosa))
$pgDisco.Controls.Add((Novo-Botao "Reparar imagem do Windows (DISM)`nCorrige a base do sistema (precisa de internet)" { Reparar-Imagem } $script:Paleta.Rosa))
$pgDisco.Controls.Add((Novo-Botao "Reparo completo (DISM + SFC)`nSequência recomendada, de 20 a 40 minutos" { Reparo-Completo } $script:Paleta.Amarelo))
$pgDisco.Controls.Add((Novo-Botao "Limpeza profunda do Windows`nCache do Windows Update, componentes, relatórios de erro e mais" { Limpeza-Profunda } $script:Paleta.Rosa))

# ============================================================
#  PAGINA: REDE
# ============================================================
$pgRede = Nova-Pagina 'rede' 'Rede' 'Limpe o cache DNS, teste a latência e escolha um servidor DNS mais rápido.'
Nova-Secao $pgRede 'DIAGNÓSTICO'
$pgRede.Controls.Add((Novo-Botao "Limpar DNS e testar ping`nLatência para 1.1.1.1 e 8.8.8.8" { Otimizar-Rede }))
$pgRede.Controls.Add((Novo-Botao "Diagnóstico completo`nAdaptadores, IP, gateway, DNS e conectividade" { Diagnostico-RedeCompleto } $script:Paleta.Cian))
Nova-Secao $pgRede 'SERVIDOR DNS'
$cartaoDns = Novo-Cartao 'ESCOLHER SERVIDOR' 124
$lblDns = New-Object System.Windows.Forms.Label
$lblDns.Text = 'Altera o DNS de todos os adaptadores conectados. Para voltar ao original, use "Desfazer ajustes" no Painel.'
$lblDns.AutoSize = $true
$lblDns.Font = (Fonte 'Segoe UI' 9 'Regular')
$lblDns.ForeColor = (ParaCor $script:Paleta.Mudo)
$lblDns.Location = New-Object System.Drawing.Point(18, 40)
$cartaoDns.Corpo.Controls.Add($lblDns)
$script:ComboDns = New-Object System.Windows.Forms.ComboBox
$script:ComboDns.DropDownStyle = 'DropDownList'
$script:ComboDns.Size = New-Object System.Drawing.Size(290, 30)
$script:ComboDns.Font = (Fonte 'Segoe UI' 10 'Regular')
$script:ComboDns.FlatStyle = 'Flat'
$script:ComboDns.BackColor = (ParaCor $script:Paleta.Fundo)
$script:ComboDns.ForeColor = (ParaCor $script:Paleta.Texto)
[void]$script:ComboDns.Items.Add('Automático (padrão)')
[void]$script:ComboDns.Items.Add('Cloudflare (1.1.1.1)')
[void]$script:ComboDns.Items.Add('Google (8.8.8.8)')
$script:ComboDns.SelectedIndex = 0
$script:ComboDns.Location = New-Object System.Drawing.Point(18, 74)
$cartaoDns.Corpo.Controls.Add($script:ComboDns)
$btnAplicarDns = Novo-BotaoPequeno 'APLICAR DNS' {
    Executar-Acao {
        $i = $script:ComboDns.SelectedIndex
        if ($i -eq 1) { Aplicar-DNS 'Cloudflare' } elseif ($i -eq 2) { Aplicar-DNS 'Google' } else { Aplicar-DNS 'Automatico' }
    }
} $script:Paleta.Neon 150 34
$btnAplicarDns.Location = New-Object System.Drawing.Point(324, 72)
$cartaoDns.Corpo.Controls.Add($btnAplicarDns)
$pgRede.Controls.Add($cartaoDns.Outer)
$pgRede.SetFlowBreak($cartaoDns.Outer, $true)

# ============================================================
#  PAGINA: PERFIS POR JOGO
# ============================================================
$pgJogos = Nova-Pagina 'jogos' 'Perfis por jogo' 'Ao abrir um jogo da lista, o Modo Performance liga sozinho; ao fechar, tudo volta ao normal. Mantenha este programa aberto (ele fica na bandeja).'
$cartaoAuto = Novo-Cartao 'DETECÇÃO AUTOMÁTICA' 100
$script:ChkAuto = New-Object System.Windows.Forms.CheckBox
$script:ChkAuto.Text = 'Ativar o Modo Performance automaticamente ao abrir um jogo da lista'
$script:ChkAuto.AutoSize = $true
$script:ChkAuto.Font = (Fonte 'Segoe UI Semibold' 10 'Regular')
$script:ChkAuto.ForeColor = (ParaCor $script:Paleta.Texto)
$script:ChkAuto.Checked = [bool]$script:Cfg.Auto
$script:ChkAuto.Location = New-Object System.Drawing.Point(18, 40)
$cartaoAuto.Corpo.Controls.Add($script:ChkAuto)
$script:LblStatusJogo = New-Object System.Windows.Forms.Label
$script:LblStatusJogo.Text = 'Aguardando um jogo da lista...'
$script:LblStatusJogo.AutoSize = $true
$script:LblStatusJogo.Font = (Fonte 'Segoe UI' 9 'Regular')
$script:LblStatusJogo.ForeColor = (ParaCor $script:Paleta.Mudo)
$script:LblStatusJogo.Location = New-Object System.Drawing.Point(40, 68)
$cartaoAuto.Corpo.Controls.Add($script:LblStatusJogo)
$pgJogos.Controls.Add($cartaoAuto.Outer)
$pgJogos.SetFlowBreak($cartaoAuto.Outer, $true)

$cartaoLista = Novo-Cartao 'JOGOS MONITORADOS' 300
$script:ListaJogos = New-Object System.Windows.Forms.ListBox
$script:ListaJogos.Size = New-Object System.Drawing.Size(340, 230)
$script:ListaJogos.Location = New-Object System.Drawing.Point(18, 44)
$script:ListaJogos.BackColor = (ParaCor $script:Paleta.Fundo)
$script:ListaJogos.ForeColor = (ParaCor $script:Paleta.Texto)
$script:ListaJogos.BorderStyle = 'FixedSingle'
$script:ListaJogos.Font = (Fonte 'Consolas' 10 'Regular')
foreach ($j in $script:Jogos) { [void]$script:ListaJogos.Items.Add($j) }
$cartaoLista.Corpo.Controls.Add($script:ListaJogos)

$lblDica = New-Object System.Windows.Forms.Label
$lblDica.Text = "Digite o nome do processo do jogo, sem .exe.`nVeja o nome no Gerenciador de Tarefas.`nEx.: cs2, GTA5, VALORANT-Win64-Shipping"
$lblDica.AutoSize = $true
$lblDica.Font = (Fonte 'Segoe UI' 9 'Regular')
$lblDica.ForeColor = (ParaCor $script:Paleta.Mudo)
$lblDica.Location = New-Object System.Drawing.Point(384, 44)
$cartaoLista.Corpo.Controls.Add($lblDica)

$script:TxtJogo = New-Object System.Windows.Forms.TextBox
$script:TxtJogo.Location = New-Object System.Drawing.Point(384, 118)
$script:TxtJogo.Width = 300
$script:TxtJogo.Font = (Fonte 'Consolas' 10 'Regular')
$script:TxtJogo.BackColor = (ParaCor $script:Paleta.Fundo)
$script:TxtJogo.ForeColor = (ParaCor $script:Paleta.Texto)
$script:TxtJogo.BorderStyle = 'FixedSingle'
$cartaoLista.Corpo.Controls.Add($script:TxtJogo)

$btnAddJogo = Novo-BotaoPequeno 'ADICIONAR' {
    $nome = ("$($script:TxtJogo.Text)".Trim()) -replace '\.exe$', ''
    if ($nome -and ($script:Jogos -notcontains $nome)) {
        $script:Jogos += $nome
        [void]$script:ListaJogos.Items.Add($nome)
        Salvar-Jogos
        Log "Jogo adicionado: $nome" Green
    }
    $script:TxtJogo.Text = ''
} $script:Paleta.Neon 144 36
$btnAddJogo.Location = New-Object System.Drawing.Point(384, 158)
$cartaoLista.Corpo.Controls.Add($btnAddJogo)

$btnRemJogo = Novo-BotaoPequeno 'REMOVER' {
    $sel = $script:ListaJogos.SelectedItem
    if ($sel) {
        $script:Jogos = @($script:Jogos | Where-Object { $_ -ne $sel })
        $script:ListaJogos.Items.Remove($sel)
        Salvar-Jogos
        Log "Jogo removido: $sel" Yellow
    }
} $script:Paleta.Rosa 144 36
$btnRemJogo.Location = New-Object System.Drawing.Point(540, 158)
$cartaoLista.Corpo.Controls.Add($btnRemJogo)
$pgJogos.Controls.Add($cartaoLista.Outer)
$pgJogos.SetFlowBreak($cartaoLista.Outer, $true)

# ============================================================
#  PAGINA: MONITOR E ALERTAS
# ============================================================
$pgMon = Nova-Pagina 'monitor' 'Monitor e alertas' 'Receba um aviso na bandeja quando as temperaturas passarem do limite. A temperatura da CPU depende do suporte da placa-mãe e pode aparecer como N/D.'
$cartaoAlerta = Novo-Cartao 'ALERTAS DE TEMPERATURA' 136
$script:ChkAlertas = New-Object System.Windows.Forms.CheckBox
$script:ChkAlertas.Text = 'Ativar alertas de temperatura'
$script:ChkAlertas.AutoSize = $true
$script:ChkAlertas.Font = (Fonte 'Segoe UI Semibold' 10 'Regular')
$script:ChkAlertas.ForeColor = (ParaCor $script:Paleta.Texto)
$script:ChkAlertas.Checked = [bool]$script:Cfg.Alertas
$script:ChkAlertas.Location = New-Object System.Drawing.Point(18, 40)
$cartaoAlerta.Corpo.Controls.Add($script:ChkAlertas)

function Novo-Limite {
    param($Pai, [string]$Rotulo, [int]$Valor, [int]$X)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Rotulo
    $l.AutoSize = $true
    $l.Font = (Fonte 'Segoe UI' 9.5 'Regular')
    $l.ForeColor = (ParaCor $script:Paleta.Mudo)
    $l.Location = New-Object System.Drawing.Point($X, 84)
    $Pai.Controls.Add($l)
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Minimum = 40; $n.Maximum = 120; $n.Value = $Valor
    $n.Width = 70
    $n.BackColor = (ParaCor $script:Paleta.Fundo)
    $n.ForeColor = (ParaCor $script:Paleta.Texto)
    $n.Location = New-Object System.Drawing.Point(($X + 140), 80)
    $Pai.Controls.Add($n)
    $u = New-Object System.Windows.Forms.Label
    $u.Text = ([string][char]0x00B0) + 'C'
    $u.AutoSize = $true
    $u.ForeColor = (ParaCor $script:Paleta.Mudo)
    $u.Location = New-Object System.Drawing.Point(($X + 216), 84)
    $Pai.Controls.Add($u)
    return $n
}
$script:NumCpu   = Novo-Limite $cartaoAlerta.Corpo 'Limite da CPU' ([int]$script:Cfg.CpuMax) 18
$script:NumGpu   = Novo-Limite $cartaoAlerta.Corpo 'Limite da GPU' ([int]$script:Cfg.GpuMax) 300
$script:NumDisco = Novo-Limite $cartaoAlerta.Corpo 'Limite do disco' ([int]$script:Cfg.DiscoMax) 582
$pgMon.Controls.Add($cartaoAlerta.Outer)
$pgMon.SetFlowBreak($cartaoAlerta.Outer, $true)

Nova-Secao $pgMon 'HISTÓRICO DA SESSÃO (CPU, GPU E TEMPERATURAS)'
$script:Grafico = New-Object System.Windows.Forms.Panel
$script:Grafico.Height = 200
$script:Grafico.Width = 880
$script:Grafico.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 16)
Ativar-DoubleBuffer $script:Grafico
$script:Grafico.Add_Paint({ param($s, $e) Desenhar-Grafico $e.Graphics $s })
$pgMon.Controls.Add($script:Grafico)
$pgMon.SetFlowBreak($script:Grafico, $true)
[void]$script:ItensLargos.Add($script:Grafico)

Nova-Secao $pgMon 'FERRAMENTAS'
$pgMon.Controls.Add((Novo-Botao "Monitorar no console`n10 leituras de CPU, RAM e GPU" { Monitorar-Console }))
$pgMon.Controls.Add((Novo-Botao "Exportar histórico (CSV)`nResumo da sessão e arquivo para planilha" { Exportar-Historico } $script:Paleta.Neon))
$pgMon.Controls.Add((Novo-Botao "Testar notificação`nMostra um aviso de teste na bandeja" {
    $script:Tray.ShowBalloonTip(4000, 'HS-Tech | Central de Ferramentas', 'Notificação de teste: os alertas estão funcionando.', [System.Windows.Forms.ToolTipIcon]::Info)
    Log 'Notificação de teste enviada.' Green
} $script:Paleta.Cian))

# ============================================================
#  PAGINA: DRIVERS
# ============================================================
$pgDrv = Nova-Pagina 'drivers' 'Drivers' 'Encontre, faça backup e atualize drivers com segurança. Antes de instalar, a ferramenta cria um ponto de restauração e oferece um backup dos drivers atuais.'
Nova-Secao $pgDrv 'ASSISTENTE'
$btnAssistDrv = Novo-Botao "Assistente de drivers (recomendado)`nVerifica problemas, mostra a idade dos drivers e procura atualizações no Windows Update" { Assistente-Drivers } $script:Paleta.Neon 558 84
$pgDrv.Controls.Add($btnAssistDrv)
$pgDrv.SetFlowBreak($btnAssistDrv, $true)
Nova-Secao $pgDrv 'VERIFICAÇÃO E ATUALIZAÇÃO'
$pgDrv.Controls.Add((Novo-Botao "Procurar atualizações de drivers`nBusca no Windows Update e você escolhe o que instalar" { Atualizar-Drivers } $script:Paleta.Rosa))
$pgDrv.Controls.Add((Novo-Botao "Dispositivos com problema`nLista hardware com driver ausente ou com erro" { Verificar-DispositivosProblema } $script:Paleta.Cian))
$pgDrv.Controls.Add((Novo-Botao "Idade dos drivers`nMostra drivers de componentes principais com mais de 3 anos" { Inventario-Drivers } $script:Paleta.Cian))
Nova-Secao $pgDrv 'SEGURANÇA'
$pgDrv.Controls.Add((Novo-Botao "Backup dos drivers atuais`nExporta os drivers instalados para uma pasta à sua escolha" { Backup-Drivers } $script:Paleta.Neon))
$pgDrv.Controls.Add((Novo-Botao "Criar ponto de restauração`nPermite voltar o Windows ao estado atual" { Criar-PontoRestauracao } $script:Paleta.Cian))
Nova-Secao $pgDrv 'FABRICANTES E FERRAMENTAS DO WINDOWS'
$pgDrv.Controls.Add((Novo-Botao "Drivers de vídeo (site oficial)`nVersão atual e página do fabricante da placa de vídeo" { Verificar-Drivers } $script:Paleta.Cian))
$pgDrv.Controls.Add((Novo-Botao "Drivers do fabricante do PC`nPesquisa o modelo do equipamento ou da placa-mãe" { Abrir-DriversFabricante } $script:Paleta.Cian))
$pgDrv.Controls.Add((Novo-Botao "Gerenciador de Dispositivos`nAbre a ferramenta nativa do Windows" { Start-Process devmgmt.msc } $script:Paleta.Cian))

# ============================================================
#  PAGINA: DIAGNOSTICO
# ============================================================
$pgDiag = Nova-Pagina 'diag' 'Diagnóstico' 'Descubra o que realmente limita o PC antes de ajustar: erros do Windows, drivers, segurança, bateria e testes de estabilidade.'
Nova-Secao $pgDiag 'VISÃO GERAL'
$btnDiagCompleto = Novo-Botao "Diagnóstico completo`nHardware, erros, drivers, segurança e discos, com relatório HTML" { Diagnostico-Completo } $script:Paleta.Neon 558 78
$pgDiag.Controls.Add($btnDiagCompleto)
$pgDiag.SetFlowBreak($btnDiagCompleto, $true)
Nova-Secao $pgDiag 'ANÁLISES'
$pgDiag.Controls.Add((Novo-Botao "Erros do Windows`nFalhas de disco, energia, hardware e travamentos (7 dias)" { Diagnostico-Eventos } $script:Paleta.Cian))
$pgDiag.Controls.Add((Novo-Botao "Tempo ligado e reinício pendente`nIndica se o PC precisa reiniciar" { Diagnostico-Sistema } $script:Paleta.Cian))
$pgDiag.Controls.Add((Novo-Botao "Hardware e configuração`nNúcleos, RAM (XMP/EXPO) e taxa do monitor" { Diagnostico-PC } $script:Paleta.Cian))
$pgDiag.Controls.Add((Novo-Botao "Drivers de vídeo`nVersão, data e página oficial do fabricante" { Verificar-Drivers } $script:Paleta.Cian))
$pgDiag.Controls.Add((Novo-Botao "Antivírus e atualizações`nProteção ativa e última atualização do Windows" { Diagnostico-Seguranca } $script:Paleta.Cian))
$pgDiag.Controls.Add((Novo-Botao "Saúde da bateria`nCapacidade atual e relatório do Windows" { Saude-Bateria } $script:Paleta.Cian))
$pgDiag.Controls.Add((Novo-Botao "Abrir o Windows Update`nBusca e instala atualizações" { Start-Process 'ms-settings:windowsupdate' } $script:Paleta.Neon))
Nova-Secao $pgDiag 'TESTES'
$pgDiag.Controls.Add((Novo-Botao "Teste de estabilidade da CPU`n60 segundos com leitura de temperatura" { Teste-Estabilidade 60 } $script:Paleta.Amarelo))
$pgDiag.Controls.Add((Novo-Botao "Teste de memória do Windows`nAgenda o teste de RAM na reinicialização" { Testar-Memoria } $script:Paleta.Amarelo))
$pgDiag.Controls.Add((Novo-Botao "Verificação rápida do Defender`nProcura ameaças nas áreas principais" { Escanear-Defender } $script:Paleta.Amarelo))

# ============================================================
#  PAGINA: AGENDAR E RELATORIOS
# ============================================================
$pgAg = Nova-Pagina 'agenda' 'Agendar e relatórios' 'Manutenção automática semanal, relatórios do sistema e histórico de atividades.'
Nova-Secao $pgAg 'MANUTENÇÃO AUTOMÁTICA'
$pgAg.Controls.Add((Novo-Botao "Agendar manutenção semanal`nDomingo às 04:00 (roda ao ligar, se perdeu)" { Agendar-Manutencao }))
$pgAg.Controls.Add((Novo-Botao "Remover agendamento`nCancela a manutenção automática" { Remover-Agendamento } $script:Paleta.Rosa))
Nova-Secao $pgAg 'RELATÓRIOS E LOGS'
$pgAg.Controls.Add((Novo-Botao "Exportar relatório do PC`nGera um arquivo com hardware e uso atual" { Exportar-RelatorioSistema } $script:Paleta.Neon))
$pgAg.Controls.Add((Novo-Botao "Abrir histórico de atividades`nOperações registradas hoje" { Abrir-Historico } $script:Paleta.Cian))
$pgAg.Controls.Add((Novo-Botao "Abrir pasta de logs`nLogs e relatórios antes/depois" { Start-Process explorer.exe -ArgumentList "`"$($script:Pasta)`"" } $script:Paleta.Cian))
Nova-Secao $pgAg 'RELATÓRIO PARA O CLIENTE E CONFIGURAÇÕES'
$pgAg.Controls.Add((Novo-Botao "Dados do atendimento`nCliente, técnico, observações e logo para o relatório" { Editar-DadosAtendimento } $script:Paleta.Neon))
$pgAg.Controls.Add((Novo-Botao "Gerar relatório HTML`nDocumento visual com diagnóstico, antes/depois e ajustes" { Relatorio-HTML-Agora } $script:Paleta.Neon))
$pgAg.Controls.Add((Novo-Botao "Exportar configurações`nSalva lista de jogos e limites em um arquivo" { Exportar-Config } $script:Paleta.Cian))
$pgAg.Controls.Add((Novo-Botao "Importar configurações`nCarrega um arquivo salvo anteriormente" { Importar-Config } $script:Paleta.Cian))
Nova-Secao $pgAg 'FINALIZAR ATENDIMENTO'
$pgAg.Controls.Add((Novo-Botao "Finalizar e remover a ferramenta`nGera o relatório final, remove os agendamentos e apaga o programa deste PC" { Finalizar-Remover } '#FF5C7A' 558 78))

# ============================================================
#  EVENTOS, BANDEJA E TIMER
# ============================================================
$script:ChkAuto.Add_CheckedChanged({ Salvar-Config })
$script:ChkAlertas.Add_CheckedChanged({ Salvar-Config })
$script:NumCpu.Add_ValueChanged({ Salvar-Config })
$script:NumGpu.Add_ValueChanged({ Salvar-Config })
$script:NumDisco.Add_ValueChanged({ Salvar-Config })

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = [System.Drawing.SystemIcons]::Shield
$script:Tray.Text = 'HS-Tech'
$script:Tray.Visible = $true
$menuTray = New-Object System.Windows.Forms.ContextMenuStrip
$miAbrir = $menuTray.Items.Add('Abrir')
$miAbrir.Add_Click({ $script:Form.Show(); $script:Form.WindowState = 'Normal'; $script:Form.Activate() })
$miSair = $menuTray.Items.Add('Sair')
$miSair.Add_Click({ $script:Form.Close() })
$script:Tray.ContextMenuStrip = $menuTray
$script:Tray.Add_DoubleClick({ $script:Form.Show(); $script:Form.WindowState = 'Normal'; $script:Form.Activate() })

$script:Form.Add_Resize({
    if ($script:Form.WindowState -eq 'Minimized') {
        $script:Form.Hide()
        $script:Tray.ShowBalloonTip(2500, 'HS-Tech | Central de Ferramentas', 'Continua rodando na bandeja (detecção de jogos e alertas).', [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        Ajustar-Larguras
    }
})

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 3000
$script:Timer.Add_Tick({
    if ($script:EmTick -or $script:Ocupado) { return }
    $script:EmTick = $true
    try { Atualizar-Painel; Verificar-Jogos } catch { } finally { $script:EmTick = $false }
})

$script:Form.Add_FormClosing({
    $script:Timer.Stop()
    if ($script:ModoJogoAtivo) { Sair-ModoPerformance }
    Restaurar-Notificacoes
    $script:Tray.Visible = $false
    $script:Tray.Dispose()
})

$script:Form.Add_Shown({
    Ajustar-Larguras
    Log 'Sistema pronto. Escolha uma área no menu ou execute a manutenção recomendada.' Green
    if (-not $script:TemNvidia) { Log 'GPU: o HS-Tech tenta ler uso pelo contador nativo do Windows e temperatura via LibreHardwareMonitor/OpenHardwareMonitor. A temperatura depende do driver e do provedor de sensores instalado; valores indisponiveis aparecem como N/D.' Gray }
    try { Atualizar-Painel } catch { }
    try { $bk=@(Procurar-BackupsExistentes); if($bk.Count -gt 0){ Log ("Backup HS-Tech encontrado: {0}. Abra Backup e restauração para revisar e recuperar os dados." -f $bk.Count) Cyan; [void][Windows.Forms.MessageBox]::Show(("Foi encontrado backup HS-Tech em disco conectado:`r`n{0}`r`n`r`nAbra a página Backup e restauração para revisar e recuperar os dados." -f $bk[0]),'HS-Tech - Backup encontrado','OK','Information') } } catch { }
    $script:Timer.Start()
})

Mostrar-Pagina 'inicio'
[System.Windows.Forms.Application]::Run($script:Form)
