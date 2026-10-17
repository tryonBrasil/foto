#Requires -Version 5.1
# ============================================================
#  OTIMIZADOR GAMER v2 - interface grafica estilo gamer
#  Modulos: painel ao vivo, limpeza, desempenho, perfis por jogo,
#  disco (saude/verificacao/otimizacao/benchmark), rede + DNS,
#  GPU/visuais, bloatware, alertas de temperatura, agendamento,
#  relatorio antes/depois e desfazer.
# ============================================================
param([switch]$Manutencao)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------- Auto-elevacao (precisa de administrador) ----------
$ehAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $ehAdmin) {
    $argsElev = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Manutencao) { $argsElev += ' -Manutencao' }
    Start-Process powershell -Verb RunAs -ArgumentList $argsElev
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
$script:Pasta         = Split-Path -Parent $PSCommandPath
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
    Fundo = '#0B0B12'; Lateral = '#0F0F1A'; Painel = '#14141F'; Hover = '#1E1E2E'
    Neon = '#00FFA3'; Rosa = '#FF2E88'; Cian = '#00D9FF'; Amarelo = '#FFD60A'
    Texto = '#E6E6F0'; Mudo = '#8A8AA0'
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
        $mapa = @{ Gray = '#B4B4C8'; Green = '#00FFA3'; Red = '#FF4D6D'; Yellow = '#FFD60A'; Cyan = '#00D9FF'; Magenta = '#FF2E88' }
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
    $r = [System.Windows.Forms.MessageBox]::Show($Pergunta, 'Otimizador Gamer', 'YesNo', 'Question')
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
    $r = @{ Uso = $null; Temp = $null }
    if ($script:TemNvidia) {
        try {
            $l = (& nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
            if ($l) {
                $p = $l -split ','
                $r.Uso = [int]$p[0].Trim()
                $r.Temp = [int]$p[1].Trim()
            }
        } catch { }
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
    foreach ($p in $b.PSObject.Properties) {
        if ($p.Name -eq 'PlanoEnergia') {
            powercfg /setactive $p.Value 2>$null
            Log 'Plano de energia restaurado.'
        } elseif ($p.Name -eq 'DNSAlterado') {
            Aplicar-DNS 'Automatico'
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
    Remove-Item $script:BackupFile -Force
    Log 'Ajustes revertidos. Reinicie o PC para concluir.' Green
}

# ============================================================
#  LIMPEZA E DESEMPENHO
# ============================================================
function Limpar-Temporarios {
    Log '--- Limpeza de temporarios ---' Cyan
    $alvos = @(
        $env:TEMP, "$env:SystemRoot\Temp",
        "$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\NVIDIA\DXCache",
        "$env:LOCALAPPDATA\NVIDIA\GLCache", "$env:LOCALAPPDATA\AMD\DxCache"
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
    try { Clear-RecycleBin -Force -ErrorAction Stop; Log 'Lixeira esvaziada.' } catch { }
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
    Log 'Plano Alto desempenho ativado.' Green
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

function Executar-Tudo {
    $total = 8
    $antes = Snapshot
    Passo 1 $total 'Ponto de restauracao';       Criar-PontoRestauracao
    Passo 2 $total 'Limpeza de temporarios';     Limpar-Temporarios
    Passo 3 $total 'Plano de energia';           Ajustar-Energia
    Passo 4 $total 'Modo Jogo do Windows';       Ajustar-ModoJogo
    Passo 5 $total 'Rede';                       Otimizar-Rede
    Passo 6 $total 'Saude dos discos';           Saude-Disco
    Passo 7 $total 'Verificacao dos discos';     Verificar-Disco
    Passo 8 $total 'Otimizacao dos discos';      Otimizar-Disco
    $depois = Snapshot
    Mostrar-Relatorio $antes $depois
    Log 'Otimizacao completa finalizada. Recomenda-se reiniciar o PC.' Green
}

# ============================================================
#  AGENDAMENTO
# ============================================================
function Agendar-Manutencao {
    Log '--- Agendando manutencao semanal ---' Cyan
    try {
        $acao = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Manutencao"
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
        $script:Tray.ShowBalloonTip(3000, 'Otimizador Gamer', "Modo Performance ativado para $rodando", [System.Windows.Forms.ToolTipIcon]::Info)
    } elseif (-not $rodando -and $script:ModoJogoAtivo) {
        $script:ModoJogoAtivo = $false
        Log "Jogo encerrado: $($script:JogoAtual)" Magenta
        $script:JogoAtual = $null
        Sair-ModoPerformance
        $script:LblStatusJogo.Text = 'Aguardando um jogo da lista...'
        $script:LblStatusJogo.ForeColor = (ParaCor $script:Paleta.Mudo)
    }
}

function Atualizar-Painel {
    $cpu = Uso-CPU
    $ram = Uso-RAM
    $gpu = Info-GPU
    $tc = Temp-CPU
    $script:TickN++
    if ($script:TickN % 20 -eq 1) { $script:TempDisco = Temp-Disco }

    $script:CardCPU.Valor.Text = if ($null -ne $cpu) { "$cpu%" } else { 'N/D' }
    $script:CardRAM.Valor.Text = if ($null -ne $ram) { "$ram%" } else { 'N/D' }
    $script:CardGPU.Valor.Text = if ($null -ne $gpu.Uso) { "$($gpu.Uso)%" } else { 'N/D' }
    $tcTxt = if ($null -ne $tc) { "$tc" } else { '--' }
    $tgTxt = if ($null -ne $gpu.Temp) { "$($gpu.Temp)" } else { '--' }
    $script:CardTemp.Valor.Text = "$tcTxt / $tgTxt" + [char]0x00B0
    try {
        $v = Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':'))
        $script:CardDisco.Valor.Text = "{0} GB" -f [math]::Round($v.SizeRemaining / 1GB)
    } catch { }

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
#  INTERFACE GRAFICA (tema gamer neon)
# ============================================================
function Executar-Acao {
    param([scriptblock]$Bloco)
    if ($script:Ocupado) { Log 'Aguarde: outra tarefa esta em andamento.' Yellow; return }
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
    }
}

function Novo-Label {
    param([string]$Texto, [double]$Tam = 10, [string]$CorHex = '#E6E6F0', [string]$NomeFonte = 'Segoe UI', [string]$Estilo = 'Regular', [int]$Largura = 780)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Texto
    $l.AutoSize = $true
    $l.MaximumSize = New-Object System.Drawing.Size($Largura, 0)
    $l.Font = (Fonte $NomeFonte $Tam $Estilo)
    $l.ForeColor = (ParaCor $CorHex)
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    return $l
}

function Novo-Botao {
    param([string]$Texto, [scriptblock]$Acao, [string]$CorHex = '#00FFA3', [int]$L = 262, [int]$A = 62)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Texto
    $b.Width = $L; $b.Height = $A
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = (ParaCor $CorHex)
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.MouseOverBackColor = (ParaCor $script:Paleta.Hover)
    $b.FlatAppearance.MouseDownBackColor = (ParaCor $CorHex)
    $b.BackColor = (ParaCor $script:Paleta.Painel)
    $b.ForeColor = (ParaCor $script:Paleta.Texto)
    $b.Font = (Fonte 'Segoe UI' 9.5 'Bold')
    $b.TextAlign = 'MiddleLeft'
    $b.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 14, 14)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Tag = $Acao
    $b.Add_Click({ param($s, $e) Executar-Acao $s.Tag })
    [void]$script:Botoes.Add($b)
    return $b
}

function Novo-Card {
    param([string]$Titulo, [string]$CorHex)
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size(152, 88)
    $p.BackColor = (ParaCor $script:Paleta.Painel)
    $p.Margin = New-Object System.Windows.Forms.Padding(0, 0, 14, 14)

    $linha = New-Object System.Windows.Forms.Panel
    $linha.Dock = 'Bottom'; $linha.Height = 3
    $linha.BackColor = (ParaCor $CorHex)
    $p.Controls.Add($linha)

    $t = New-Object System.Windows.Forms.Label
    $t.Text = $Titulo; $t.AutoSize = $true
    $t.Font = (Fonte 'Segoe UI' 8.5 'Bold')
    $t.ForeColor = (ParaCor $script:Paleta.Mudo)
    $t.Location = New-Object System.Drawing.Point(12, 10)
    $p.Controls.Add($t)

    $v = New-Object System.Windows.Forms.Label
    $v.Text = '--'; $v.AutoSize = $true
    $v.Font = (Fonte 'Segoe UI Black' 17 'Regular')
    $v.ForeColor = (ParaCor $CorHex)
    $v.Location = New-Object System.Drawing.Point(10, 36)
    $p.Controls.Add($v)

    return @{ Painel = $p; Valor = $v }
}

function Nova-Pagina {
    param([string]$Nome, [string]$Titulo, [string]$Sub)
    $p = New-Object System.Windows.Forms.FlowLayoutPanel
    $p.Dock = 'Fill'
    $p.AutoScroll = $true
    $p.Padding = New-Object System.Windows.Forms.Padding(24, 18, 12, 12)
    $p.BackColor = (ParaCor $script:Paleta.Fundo)
    $p.Visible = $false
    $t = Novo-Label $Titulo 22 $script:Paleta.Neon 'Segoe UI Black' 'Regular'
    $p.Controls.Add($t); $p.SetFlowBreak($t, $true)
    $s = Novo-Label $Sub 9.5 $script:Paleta.Mudo
    $s.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 18)
    $p.Controls.Add($s); $p.SetFlowBreak($s, $true)
    $script:Paginas[$Nome] = $p
    $script:Conteudo.Controls.Add($p)
    return $p
}

function Nova-Secao {
    param($Pagina, [string]$Texto)
    $l = Novo-Label $Texto 10 $script:Paleta.Rosa 'Segoe UI' 'Bold'
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 10)
    $Pagina.Controls.Add($l)
    $Pagina.SetFlowBreak($l, $true)
}

function Mostrar-Pagina {
    param([string]$Nome)
    foreach ($k in @($script:Paginas.Keys)) { $script:Paginas[$k].Visible = ($k -eq $Nome) }
    foreach ($b in $script:NavBotoes) {
        if ($b.Tag -eq $Nome) {
            $b.ForeColor = (ParaCor $script:Paleta.Neon); $b.BackColor = (ParaCor $script:Paleta.Hover)
        } else {
            $b.ForeColor = (ParaCor $script:Paleta.Texto); $b.BackColor = (ParaCor $script:Paleta.Lateral)
        }
    }
}

# ---------- Janela principal ----------
$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'Otimizador Gamer'
$script:Form.Size = New-Object System.Drawing.Size(1120, 780)
$script:Form.MinimumSize = New-Object System.Drawing.Size(1000, 700)
$script:Form.StartPosition = 'CenterScreen'
$script:Form.BackColor = (ParaCor $script:Paleta.Fundo)
$script:Form.ForeColor = (ParaCor $script:Paleta.Texto)
$script:Form.Font = (Fonte 'Segoe UI' 10 'Regular')

$script:Conteudo = New-Object System.Windows.Forms.Panel
$script:Conteudo.Dock = 'Fill'
$script:Conteudo.BackColor = (ParaCor $script:Paleta.Fundo)
$script:Form.Controls.Add($script:Conteudo)

# Barra lateral
$lateral = New-Object System.Windows.Forms.Panel
$lateral.Dock = 'Left'; $lateral.Width = 214
$lateral.BackColor = (ParaCor $script:Paleta.Lateral)
$script:Form.Controls.Add($lateral)

# Console (parte de baixo)
$rodape = New-Object System.Windows.Forms.Panel
$rodape.Dock = 'Bottom'; $rodape.Height = 230
$rodape.BackColor = (ParaCor '#07070C')
$script:Form.Controls.Add($rodape)

$script:TxtLog = New-Object System.Windows.Forms.RichTextBox
$script:TxtLog.Dock = 'Fill'
$script:TxtLog.ReadOnly = $true
$script:TxtLog.BorderStyle = 'None'
$script:TxtLog.BackColor = (ParaCor '#07070C')
$script:TxtLog.ForeColor = (ParaCor '#B4B4C8')
$script:TxtLog.Font = (Fonte 'Consolas' 9.5 'Regular')
$rodape.Controls.Add($script:TxtLog)

$script:BarraFundo = New-Object System.Windows.Forms.Panel
$script:BarraFundo.Dock = 'Top'; $script:BarraFundo.Height = 6
$script:BarraFundo.BackColor = (ParaCor '#1A1A28')
$script:BarraFill = New-Object System.Windows.Forms.Panel
$script:BarraFill.Dock = 'Left'; $script:BarraFill.Width = 0
$script:BarraFill.BackColor = (ParaCor $script:Paleta.Neon)
$script:BarraFundo.Controls.Add($script:BarraFill)
$rodape.Controls.Add($script:BarraFundo)

# Cabecalho
$cabecalho = New-Object System.Windows.Forms.Panel
$cabecalho.Dock = 'Top'; $cabecalho.Height = 78
$cabecalho.BackColor = (ParaCor $script:Paleta.Lateral)
$neonLinha = New-Object System.Windows.Forms.Panel
$neonLinha.Dock = 'Bottom'; $neonLinha.Height = 2
$neonLinha.BackColor = (ParaCor $script:Paleta.Neon)
$cabecalho.Controls.Add($neonLinha)

$lblTitulo = New-Object System.Windows.Forms.Label
$lblTitulo.Text = [string][char]0x26A1 + ' OTIMIZADOR GAMER'
$lblTitulo.AutoSize = $true
$lblTitulo.Font = (Fonte 'Segoe UI Black' 24 'Regular')
$lblTitulo.ForeColor = (ParaCor $script:Paleta.Neon)
$lblTitulo.Location = New-Object System.Drawing.Point(18, 6)
$cabecalho.Controls.Add($lblTitulo)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = 'PERFORMANCE MAXIMA  ' + [char]0x2022 + '  DISCO  ' + [char]0x2022 + '  REDE  ' + [char]0x2022 + '  JOGOS'
$lblSub.AutoSize = $true
$lblSub.Font = (Fonte 'Segoe UI' 8.5 'Bold')
$lblSub.ForeColor = (ParaCor $script:Paleta.Cian)
$lblSub.Location = New-Object System.Drawing.Point(24, 54)
$cabecalho.Controls.Add($lblSub)
$script:Form.Controls.Add($cabecalho)

# ---------- Navegacao ----------
$itensNav = @(
    @('inicio', 'PAINEL'), @('desempenho', 'DESEMPENHO'), @('disco', 'DISCO'),
    @('rede', 'REDE'), @('jogos', 'JOGOS'), @('monitor', 'MONITOR'), @('agenda', 'AGENDAR')
)
$y = 18
foreach ($it in $itensNav) {
    $nb = New-Object System.Windows.Forms.Button
    $nb.Text = $it[1]
    $nb.Tag = $it[0]
    $nb.Location = New-Object System.Drawing.Point(0, $y)
    $nb.Size = New-Object System.Drawing.Size(214, 50)
    $nb.FlatStyle = 'Flat'
    $nb.FlatAppearance.BorderSize = 0
    $nb.FlatAppearance.MouseOverBackColor = (ParaCor $script:Paleta.Hover)
    $nb.BackColor = (ParaCor $script:Paleta.Lateral)
    $nb.ForeColor = (ParaCor $script:Paleta.Texto)
    $nb.Font = (Fonte 'Segoe UI' 10.5 'Bold')
    $nb.TextAlign = 'MiddleLeft'
    $nb.Padding = New-Object System.Windows.Forms.Padding(24, 0, 0, 0)
    $nb.Cursor = [System.Windows.Forms.Cursors]::Hand
    $nb.Add_Click({ param($s, $e) Mostrar-Pagina $s.Tag })
    $lateral.Controls.Add($nb)
    [void]$script:NavBotoes.Add($nb)
    $y += 54
}
$lblVersao = New-Object System.Windows.Forms.Label
$lblVersao.Text = 'v2.0  |  modo administrador'
$lblVersao.AutoSize = $true
$lblVersao.Font = (Fonte 'Segoe UI' 8 'Regular')
$lblVersao.ForeColor = (ParaCor $script:Paleta.Mudo)
$lblVersao.Location = New-Object System.Drawing.Point(24, 420)
$lateral.Controls.Add($lblVersao)

# ---------- Pagina: PAINEL ----------
$pgInicio = Nova-Pagina 'inicio' 'PAINEL' 'Visao geral do seu PC em tempo real. Tudo que altera o sistema tem backup e pode ser desfeito.'
$script:CardCPU   = Novo-Card 'CPU' $script:Paleta.Neon
$script:CardRAM   = Novo-Card 'MEMORIA RAM' $script:Paleta.Cian
$script:CardGPU   = Novo-Card 'GPU (NVIDIA)' $script:Paleta.Rosa
$script:CardTemp  = Novo-Card 'TEMP CPU / GPU' $script:Paleta.Amarelo
$script:CardDisco = Novo-Card 'LIVRE NO SISTEMA' $script:Paleta.Neon
foreach ($c in @($script:CardCPU, $script:CardRAM, $script:CardGPU, $script:CardTemp, $script:CardDisco)) {
    $pgInicio.Controls.Add($c.Painel)
}
$pgInicio.SetFlowBreak($script:CardDisco.Painel, $true)

$btnTudo = Novo-Botao "EXECUTAR TUDO (RECOMENDADO)`nLimpeza, energia, modo jogo, rede, disco e relatorio antes/depois" { Executar-Tudo } $script:Paleta.Neon 538 74
$pgInicio.Controls.Add($btnTudo)
$pgInicio.SetFlowBreak($btnTudo, $true)
$pgInicio.Controls.Add((Novo-Botao "PONTO DE RESTAURACAO`nCria um ponto antes de ajustar" { Criar-PontoRestauracao } $script:Paleta.Cian))
$pgInicio.Controls.Add((Novo-Botao "DESFAZER AJUSTES`nVolta registro, energia e DNS" { Desfazer-Ajustes } $script:Paleta.Rosa))

# ---------- Pagina: DESEMPENHO ----------
$pgDes = Nova-Pagina 'desempenho' 'DESEMPENHO' 'Limpeza, energia, modo jogo e ajustes do sistema para ganhar FPS e estabilidade.'
Nova-Secao $pgDes 'LIMPEZA E ENERGIA'
$pgDes.Controls.Add((Novo-Botao "LIMPAR TEMPORARIOS`nTemp, cache de shaders, lixeira" { Limpar-Temporarios }))
$pgDes.Controls.Add((Novo-Botao "PLANO ALTO DESEMPENHO`nAtiva o plano de energia maximo" { Ajustar-Energia }))
$pgDes.Controls.Add((Novo-Botao "MODO JOGO DO WINDOWS`nAtiva e desliga captura de fundo" { Ajustar-ModoJogo }))
Nova-Secao $pgDes 'MODO PERFORMANCE'
$pgDes.Controls.Add((Novo-Botao "MODO PERFORMANCE: LIGAR`nFecha apps de fundo + alto desempenho" { Entrar-ModoPerformance } $script:Paleta.Rosa))
$pgDes.Controls.Add((Novo-Botao "MODO PERFORMANCE: DESLIGAR`nRestaura o plano de energia anterior" { Sair-ModoPerformance } $script:Paleta.Rosa))
$pgDes.Controls.Add((Novo-Botao "LIBERAR RAM EM ESPERA`nLimpa a lista de espera da memoria" { Liberar-RAM } $script:Paleta.Rosa))
$pgDes.SetFlowBreak($pgDes.Controls[$pgDes.Controls.Count - 1], $true)
Nova-Secao $pgDes 'AJUSTES AVANCADOS (pedem confirmacao)'
$pgDes.Controls.Add((Novo-Botao "GPU E EFEITOS VISUAIS`nHAGS, menos animacoes e transparencia" { Ajustar-GPUSistema } $script:Paleta.Cian))
$pgDes.Controls.Add((Novo-Botao "HORARIO ATIVO DO UPDATE`nEvita reinicio enquanto voce joga" { Definir-HorarioAtivo } $script:Paleta.Cian))
$pgDes.Controls.Add((Novo-Botao "APPS DE INICIALIZACAO`nLista o que abre com o Windows" { Listar-Inicializacao } $script:Paleta.Cian))
$pgDes.Controls.Add((Novo-Botao "REMOVER BLOATWARE`nEscolha apps inuteis para remover" { Remover-Bloatware } $script:Paleta.Amarelo))

# ---------- Pagina: DISCO ----------
$pgDisco = Nova-Pagina 'disco' 'DISCO' 'Saude, verificacao, otimizacao e velocidade. TRIM em SSD e desfragmentacao apenas em HDD.'
Nova-Secao $pgDisco 'DIAGNOSTICO'
$pgDisco.Controls.Add((Novo-Botao "SAUDE E ESPACO`nSMART, temperatura, desgaste" { Saude-Disco }))
$pgDisco.Controls.Add((Novo-Botao "VERIFICAR ERROS`nVarredura somente leitura" { Verificar-Disco }))
$pgDisco.Controls.Add((Novo-Botao "BENCHMARK DO DISCO`nVelocidade de leitura e escrita" { Benchmark-Disco }))
Nova-Secao $pgDisco 'OTIMIZACAO E REPARO'
$pgDisco.Controls.Add((Novo-Botao "OTIMIZAR DISCOS`nTRIM no SSD, defrag no HDD" { Otimizar-Disco } $script:Paleta.Rosa))
$pgDisco.Controls.Add((Novo-Botao "VERIFICACAO COM REPARO`nAgenda CHKDSK na reinicializacao" { Agendar-VerificacaoReparo } $script:Paleta.Rosa))
$pgDisco.Controls.Add((Novo-Botao "ARQUIVOS DO WINDOWS (SFC)`nVerifica a integridade do sistema" { Verificar-ArquivosWindows } $script:Paleta.Rosa))

# ---------- Pagina: REDE ----------
$pgRede = Nova-Pagina 'rede' 'REDE' 'Limpe o cache DNS, teste a latencia e escolha um DNS mais rapido.'
$pgRede.Controls.Add((Novo-Botao "LIMPAR DNS E TESTAR PING`nLatencia para 1.1.1.1 e 8.8.8.8" { Otimizar-Rede }))
$pgRede.SetFlowBreak($pgRede.Controls[$pgRede.Controls.Count - 1], $true)
Nova-Secao $pgRede 'SERVIDOR DNS'
$script:ComboDns = New-Object System.Windows.Forms.ComboBox
$script:ComboDns.DropDownStyle = 'DropDownList'
$script:ComboDns.Width = 262
$script:ComboDns.Font = (Fonte 'Segoe UI' 10 'Regular')
$script:ComboDns.BackColor = (ParaCor $script:Paleta.Painel)
$script:ComboDns.ForeColor = (ParaCor $script:Paleta.Texto)
$script:ComboDns.FlatStyle = 'Flat'
[void]$script:ComboDns.Items.Add('Automatico (padrao)')
[void]$script:ComboDns.Items.Add('Cloudflare (1.1.1.1)')
[void]$script:ComboDns.Items.Add('Google (8.8.8.8)')
$script:ComboDns.SelectedIndex = 0
$script:ComboDns.Margin = New-Object System.Windows.Forms.Padding(0, 14, 14, 14)
$pgRede.Controls.Add($script:ComboDns)
$pgRede.Controls.Add((Novo-Botao "APLICAR DNS`nAplica nos adaptadores conectados" {
    $i = $script:ComboDns.SelectedIndex
    if ($i -eq 1) { Aplicar-DNS 'Cloudflare' } elseif ($i -eq 2) { Aplicar-DNS 'Google' } else { Aplicar-DNS 'Automatico' }
} $script:Paleta.Rosa))

# ---------- Pagina: JOGOS ----------
$pgJogos = Nova-Pagina 'jogos' 'PERFIS POR JOGO' 'Ao abrir um jogo da lista, o Modo Performance liga sozinho; ao fechar, tudo volta ao normal. Mantenha este programa aberto (ele fica na bandeja).'
$script:ChkAuto = New-Object System.Windows.Forms.CheckBox
$script:ChkAuto.Text = 'Deteccao automatica de jogos'
$script:ChkAuto.AutoSize = $true
$script:ChkAuto.Font = (Fonte 'Segoe UI' 10 'Bold')
$script:ChkAuto.ForeColor = (ParaCor $script:Paleta.Neon)
$script:ChkAuto.Checked = [bool]$script:Cfg.Auto
$script:ChkAuto.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$pgJogos.Controls.Add($script:ChkAuto)
$pgJogos.SetFlowBreak($script:ChkAuto, $true)

$script:LblStatusJogo = Novo-Label 'Aguardando um jogo da lista...' 10 $script:Paleta.Mudo
$pgJogos.Controls.Add($script:LblStatusJogo)
$pgJogos.SetFlowBreak($script:LblStatusJogo, $true)

$script:ListaJogos = New-Object System.Windows.Forms.ListBox
$script:ListaJogos.Size = New-Object System.Drawing.Size(330, 230)
$script:ListaJogos.BackColor = (ParaCor $script:Paleta.Painel)
$script:ListaJogos.ForeColor = (ParaCor $script:Paleta.Texto)
$script:ListaJogos.BorderStyle = 'FixedSingle'
$script:ListaJogos.Font = (Fonte 'Consolas' 10 'Regular')
$script:ListaJogos.Margin = New-Object System.Windows.Forms.Padding(0, 0, 18, 0)
foreach ($j in $script:Jogos) { [void]$script:ListaJogos.Items.Add($j) }
$pgJogos.Controls.Add($script:ListaJogos)

$painelJogo = New-Object System.Windows.Forms.Panel
$painelJogo.Size = New-Object System.Drawing.Size(300, 230)
$lblDica = Novo-Label "Nome do processo do jogo, sem .exe.`nVeja no Gerenciador de Tarefas." 9 $script:Paleta.Mudo 'Segoe UI' 'Regular' 290
$lblDica.Location = New-Object System.Drawing.Point(0, 0)
$painelJogo.Controls.Add($lblDica)

$script:TxtJogo = New-Object System.Windows.Forms.TextBox
$script:TxtJogo.Location = New-Object System.Drawing.Point(0, 50)
$script:TxtJogo.Width = 290
$script:TxtJogo.Font = (Fonte 'Consolas' 10 'Regular')
$script:TxtJogo.BackColor = (ParaCor $script:Paleta.Painel)
$script:TxtJogo.ForeColor = (ParaCor $script:Paleta.Texto)
$script:TxtJogo.BorderStyle = 'FixedSingle'
$painelJogo.Controls.Add($script:TxtJogo)

$btnAddJogo = New-Object System.Windows.Forms.Button
$btnAddJogo.Text = 'ADICIONAR'
$btnAddJogo.Location = New-Object System.Drawing.Point(0, 90)
$btnAddJogo.Size = New-Object System.Drawing.Size(140, 40)
$btnAddJogo.FlatStyle = 'Flat'
$btnAddJogo.FlatAppearance.BorderColor = (ParaCor $script:Paleta.Neon)
$btnAddJogo.ForeColor = (ParaCor $script:Paleta.Neon)
$btnAddJogo.BackColor = (ParaCor $script:Paleta.Painel)
$btnAddJogo.Font = (Fonte 'Segoe UI' 9.5 'Bold')
$btnAddJogo.Add_Click({
    $nome = ("$($script:TxtJogo.Text)".Trim()) -replace '\.exe$', ''
    if ($nome -and ($script:Jogos -notcontains $nome)) {
        $script:Jogos += $nome
        [void]$script:ListaJogos.Items.Add($nome)
        Salvar-Jogos
        Log "Jogo adicionado: $nome" Green
    }
    $script:TxtJogo.Text = ''
})
$painelJogo.Controls.Add($btnAddJogo)

$btnRemJogo = New-Object System.Windows.Forms.Button
$btnRemJogo.Text = 'REMOVER'
$btnRemJogo.Location = New-Object System.Drawing.Point(150, 90)
$btnRemJogo.Size = New-Object System.Drawing.Size(140, 40)
$btnRemJogo.FlatStyle = 'Flat'
$btnRemJogo.FlatAppearance.BorderColor = (ParaCor $script:Paleta.Rosa)
$btnRemJogo.ForeColor = (ParaCor $script:Paleta.Rosa)
$btnRemJogo.BackColor = (ParaCor $script:Paleta.Painel)
$btnRemJogo.Font = (Fonte 'Segoe UI' 9.5 'Bold')
$btnRemJogo.Add_Click({
    $sel = $script:ListaJogos.SelectedItem
    if ($sel) {
        $script:Jogos = @($script:Jogos | Where-Object { $_ -ne $sel })
        $script:ListaJogos.Items.Remove($sel)
        Salvar-Jogos
        Log "Jogo removido: $sel" Yellow
    }
})
$painelJogo.Controls.Add($btnRemJogo)
$pgJogos.Controls.Add($painelJogo)

# ---------- Pagina: MONITOR ----------
$pgMon = Nova-Pagina 'monitor' 'MONITOR E ALERTAS' 'Receba um aviso na bandeja quando as temperaturas passarem do limite. A temperatura da CPU depende do suporte da placa-mae (pode aparecer N/D).'
$script:ChkAlertas = New-Object System.Windows.Forms.CheckBox
$script:ChkAlertas.Text = 'Ativar alertas de temperatura'
$script:ChkAlertas.AutoSize = $true
$script:ChkAlertas.Font = (Fonte 'Segoe UI' 10 'Bold')
$script:ChkAlertas.ForeColor = (ParaCor $script:Paleta.Neon)
$script:ChkAlertas.Checked = [bool]$script:Cfg.Alertas
$script:ChkAlertas.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
$pgMon.Controls.Add($script:ChkAlertas)
$pgMon.SetFlowBreak($script:ChkAlertas, $true)

function Novo-Limite {
    param([string]$Rotulo, [int]$Valor)
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size(250, 40)
    $p.Margin = New-Object System.Windows.Forms.Padding(0, 0, 14, 6)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Rotulo; $l.AutoSize = $true
    $l.Font = (Fonte 'Segoe UI' 10 'Bold')
    $l.Location = New-Object System.Drawing.Point(0, 8)
    $p.Controls.Add($l)
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Minimum = 40; $n.Maximum = 120; $n.Value = $Valor
    $n.Width = 70
    $n.Location = New-Object System.Drawing.Point(150, 5)
    $n.BackColor = (ParaCor $script:Paleta.Painel)
    $n.ForeColor = (ParaCor $script:Paleta.Texto)
    $p.Controls.Add($n)
    return @{ Painel = $p; Num = $n }
}
$limCpu = Novo-Limite 'CPU maxima (C):' ([int]$script:Cfg.CpuMax)
$limGpu = Novo-Limite 'GPU maxima (C):' ([int]$script:Cfg.GpuMax)
$limDisco = Novo-Limite 'Disco maximo (C):' ([int]$script:Cfg.DiscoMax)
$script:NumCpu = $limCpu.Num; $script:NumGpu = $limGpu.Num; $script:NumDisco = $limDisco.Num
$pgMon.Controls.Add($limCpu.Painel)
$pgMon.Controls.Add($limGpu.Painel)
$pgMon.Controls.Add($limDisco.Painel)
$pgMon.SetFlowBreak($limDisco.Painel, $true)
Nova-Secao $pgMon 'FERRAMENTAS'
$pgMon.Controls.Add((Novo-Botao "MONITORAR NO CONSOLE`n10 leituras de CPU, RAM e GPU" { Monitorar-Console }))
$pgMon.Controls.Add((Novo-Botao "TESTAR NOTIFICACAO`nMostra um aviso na bandeja" {
    $script:Tray.ShowBalloonTip(4000, 'Otimizador Gamer', 'Notificacao de teste: os alertas estao funcionando.', [System.Windows.Forms.ToolTipIcon]::Info)
    Log 'Notificacao de teste enviada.' Green
} $script:Paleta.Cian))

# ---------- Pagina: AGENDAR ----------
$pgAg = Nova-Pagina 'agenda' 'AGENDAR E RELATORIOS' 'Manutencao automatica semanal: limpeza e verificacao/otimizacao de disco, sem abrir o programa.'
$pgAg.Controls.Add((Novo-Botao "AGENDAR MANUTENCAO SEMANAL`nDomingo as 04:00 (roda ao ligar se perdeu)" { Agendar-Manutencao }))
$pgAg.Controls.Add((Novo-Botao "REMOVER AGENDAMENTO`nCancela a manutencao automatica" { Remover-Agendamento } $script:Paleta.Rosa))
$pgAg.Controls.Add((Novo-Botao "ABRIR PASTA DE LOGS`nLogs e relatorios antes/depois" { Start-Process explorer.exe -ArgumentList "`"$($script:Pasta)`"" } $script:Paleta.Cian))

# ---------- Eventos de opcoes ----------
$script:ChkAuto.Add_CheckedChanged({ Salvar-Config })
$script:ChkAlertas.Add_CheckedChanged({ Salvar-Config })
$script:NumCpu.Add_ValueChanged({ Salvar-Config })
$script:NumGpu.Add_ValueChanged({ Salvar-Config })
$script:NumDisco.Add_ValueChanged({ Salvar-Config })

# ---------- Bandeja do sistema ----------
$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = [System.Drawing.SystemIcons]::Shield
$script:Tray.Text = 'Otimizador Gamer'
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
        $script:Tray.ShowBalloonTip(2500, 'Otimizador Gamer', 'Continua rodando na bandeja (deteccao de jogos e alertas).', [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

# ---------- Timer ao vivo ----------
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
    $script:Tray.Visible = $false
    $script:Tray.Dispose()
})

$script:Form.Add_Shown({
    Log 'Sistema pronto. Escolha uma opcao no menu ou use EXECUTAR TUDO.' Green
    if (-not $script:TemNvidia) { Log 'GPU NVIDIA nao detectada: uso e temperatura da GPU aparecem como N/D.' Gray }
    try { Atualizar-Painel } catch { }
    $script:Timer.Start()
})

Mostrar-Pagina 'inicio'
[System.Windows.Forms.Application]::Run($script:Form)
