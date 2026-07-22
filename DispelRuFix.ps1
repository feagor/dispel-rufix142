# ============================================================
#  Dispel (Чернокнижник) — фикс-пак: перенос корейского патча 1.42
#  Кнопка «Применить» ставит фиксы (с бэкапом), «Откатить» — возвращает всё.
#  Запуск без параметров — окно с кнопками. -Apply / -Rollback — без окна.
# ============================================================
param(
  [switch]$Apply,
  [switch]$Rollback
)
$ErrorActionPreference = 'Stop'
[System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) 2>$null

$root = Split-Path -Parent $MyInvocation.MyCommand.Path      # ...\Dispel\RuFix142
$game = Split-Path -Parent $root                              # ...\Dispel
$dataDir = Join-Path $root 'data'
$movieDir = Join-Path $root 'movies'
$backupDir = Join-Path $root 'backup'
$saveBackupDir = Join-Path $backupDir 'saves'
$changesPath = Join-Path $root 'changes.json'
$latin1 = [System.Text.Encoding]::GetEncoding(28591)

$script:LogSink = $null
function Log([string]$msg) {
  if ($script:LogSink) { $script:LogSink.AppendText($msg + "`r`n") } else { Write-Host $msg }
}

function Get-TargetFiles {
  Get-ChildItem $dataDir -Recurse -File | ForEach-Object {
    $_.FullName.Substring($dataDir.Length + 1)
  }
}

function Test-GameRunning {
  $p = Get-Process -Name 'Dispel' -ErrorAction SilentlyContinue
  return ($null -ne $p)
}

function Invoke-Backup {
  if (Test-Path (Join-Path $backupDir 'ExtraInGame')) {
    Log 'Бэкап уже существует — использую его (оригиналы не перезаписываю).'
    return
  }
  Log 'Создаю бэкап оригинальных файлов...'
  foreach ($rel in Get-TargetFiles) {
    $src = Join-Path $game $rel
    $dst = Join-Path $backupDir $rel
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item $src $dst
    Log ('  бэкап: {0}' -f $rel)
  }
  New-Item -ItemType Directory -Force $saveBackupDir | Out-Null
  foreach ($sv in (Get-ChildItem $game -File | Where-Object { $_.Name -match '^\d+\.sav$|^Save\.ifo$|^game\.tmp$' })) {
    Copy-Item $sv.FullName (Join-Path $saveBackupDir $sv.Name)
    Log ('  бэкап сейва: {0}' -f $sv.Name)
  }
  if (Test-Path $movieDir) {
    foreach ($mv in Get-ChildItem $movieDir -File) {
      $orig = Join-Path $game ('Movie\' + $mv.Name)
      if (Test-Path $orig) {
        New-Item -ItemType Directory -Force (Join-Path $backupDir 'Movie') | Out-Null
        Copy-Item $orig (Join-Path $backupDir ('Movie\' + $mv.Name))
        Log ('  бэкап ролика: Movie\{0}' -f $mv.Name)
      }
    }
  }
}

function Invoke-PatchSaves {
  if (-not (Test-Path $changesPath)) { Log 'changes.json не найден — сейвы пропущены.'; return }
  $changes = Get-Content $changesPath -Raw | ConvertFrom-Json
  $byFile = $changes | Group-Object file
  $saves = Get-ChildItem $game -File | Where-Object { $_.Name -match '^\d+\.sav$|^game\.tmp$' }
  foreach ($sv in $saves) {
    $bytes = [System.IO.File]::ReadAllBytes($sv.FullName)
    $hay = $latin1.GetString($bytes)
    $applied = 0; $skipped = 0; $absent = 0
    $modified = $false
    foreach ($grp in $byFile) {
      $origRef = Join-Path $backupDir ('ExtraInGame\' + $grp.Name)
      if (-not (Test-Path $origRef)) { continue }   # не Ext-файл (npcmap3/EditItem в сейвах не хранятся)
      $orig = [System.IO.File]::ReadAllBytes($origRef)
      foreach ($recGrp in ($grp.Group | Group-Object rec)) {
        $rec = [int]$recGrp.Name
        $base = 4 + $rec * 184
        $sig = $latin1.GetString($orig, $base, 0x2C)   # id+тип+имя+X+Y
        $idx = $hay.IndexOf($sig, [System.StringComparison]::Ordinal)
        if ($idx -lt 0) { $absent += $recGrp.Group.Count; continue }
        while ($idx -ge 0) {
          foreach ($ch in $recGrp.Group) {
            $pos = $idx + $ch.off
            $cur = [BitConverter]::ToInt32($bytes, $pos)
            if ($cur -eq $ch.old) {
              $nb = [BitConverter]::GetBytes([int]$ch.new)
              for ($k = 0; $k -lt 4; $k++) { $bytes[$pos + $k] = $nb[$k] }
              $applied++; $modified = $true
            } else {
              $skipped++   # запись уже изменена игрой (открытый сундук и т.п.) — не трогаем
            }
          }
          $idx = $hay.IndexOf($sig, $idx + 1, [System.StringComparison]::Ordinal)
        }
      }
    }
    if ($modified) { [System.IO.File]::WriteAllBytes($sv.FullName, $bytes) }
    Log ('Сейв {0}: применено {1}, пропущено (изменённые записи) {2}, локации не в кэше: {3} правок' -f $sv.Name, $applied, $skipped, $absent)
  }
  if (-not $saves) { Log 'Файлы сохранений не найдены.' }
}

function Invoke-Apply([bool]$patchSaves, [bool]$patchMovies) {
  if (Test-GameRunning) { Log 'ОШИБКА: закройте игру (Dispel.exe) и повторите.'; return }
  Invoke-Backup
  Log 'Копирую исправленные файлы...'
  foreach ($rel in Get-TargetFiles) {
    Copy-Item (Join-Path $dataDir $rel) (Join-Path $game $rel) -Force
    Log ('  установлен: {0}' -f $rel)
  }
  if ($patchMovies -and (Test-Path $movieDir)) {
    Log 'Ставлю перекодированные видеоролики (MS Video 1 вместо Indeo)...'
    foreach ($mv in Get-ChildItem $movieDir -File) {
      Copy-Item $mv.FullName (Join-Path $game ('Movie\' + $mv.Name)) -Force
      Log ('  установлен: Movie\{0}' -f $mv.Name)
    }
  }
  if ($patchSaves) { Log 'Правлю сохранения...'; Invoke-PatchSaves }
  Log ''
  Log 'ГОТОВО. Патч применён. Подробности фиксов — в ОПИСАНИЕ_ФИКСОВ.txt'
}

function Invoke-Rollback([bool]$restoreSaves) {
  if (Test-GameRunning) { Log 'ОШИБКА: закройте игру (Dispel.exe) и повторите.'; return }
  if (-not (Test-Path (Join-Path $backupDir 'ExtraInGame'))) { Log 'Бэкап не найден — откатывать нечего.'; return }
  Log 'Восстанавливаю оригинальные файлы...'
  foreach ($rel in Get-TargetFiles) {
    $b = Join-Path $backupDir $rel
    if (Test-Path $b) { Copy-Item $b (Join-Path $game $rel) -Force; Log ('  восстановлен: {0}' -f $rel) }
  }
  if ($restoreSaves -and (Test-Path $saveBackupDir)) {
    foreach ($sv in Get-ChildItem $saveBackupDir -File) {
      Copy-Item $sv.FullName (Join-Path $game $sv.Name) -Force
      Log ('  восстановлен сейв: {0} (прогресс на момент бэкапа!)' -f $sv.Name)
    }
  }
  if (Test-Path (Join-Path $backupDir 'Movie')) {
    foreach ($mv in Get-ChildItem (Join-Path $backupDir 'Movie') -File) {
      Copy-Item $mv.FullName (Join-Path $game ('Movie\' + $mv.Name)) -Force
      Log ('  восстановлен ролик: Movie\{0}' -f $mv.Name)
    }
  }
  Log 'ОТКАТ ЗАВЕРШЁН.'
}

# ---------- режим командной строки ----------
if ($Apply) { Invoke-Apply $true $true; exit }
if ($Rollback) { Invoke-Rollback $true; exit }

# ---------- GUI ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Dispel (Чернокнижник) — фикс-пак 1.42'
$form.Size = New-Object System.Drawing.Size(640, 480)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$lbl = New-Object System.Windows.Forms.Label
$lbl.Text = 'Перенос исправлений официального корейского патча 1.42 в русскую версию:' + [Environment]::NewLine + 'камень Света №5, алтари Неба/Земли, лут в сундуках, квест Пуру и др.'
$lbl.Location = New-Object System.Drawing.Point(12, 10)
$lbl.Size = New-Object System.Drawing.Size(600, 36)
$form.Controls.Add($lbl)

$chk = New-Object System.Windows.Forms.CheckBox
$chk.Text = 'Исправить и сохранения (для текущего прохождения; открытые сундуки не трогаются)'
$chk.Checked = $true
$chk.Location = New-Object System.Drawing.Point(15, 50)
$chk.Size = New-Object System.Drawing.Size(600, 22)
$form.Controls.Add($chk)

$chkMov = New-Object System.Windows.Forms.CheckBox
$chkMov.Text = 'Заменить видеоролики на совместимые (Windows 10/11 без кодеков Indeo)'
$chkMov.Checked = $true
$chkMov.Location = New-Object System.Drawing.Point(15, 74)
$chkMov.Size = New-Object System.Drawing.Size(600, 22)
$form.Controls.Add($chkMov)

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = 'ПРИМЕНИТЬ ПАТЧ'
$btnApply.Location = New-Object System.Drawing.Point(15, 104)
$btnApply.Size = New-Object System.Drawing.Size(290, 36)
$form.Controls.Add($btnApply)

$btnBack = New-Object System.Windows.Forms.Button
$btnBack.Text = 'Откатить (вернуть оригинал)'
$btnBack.Location = New-Object System.Drawing.Point(320, 104)
$btnBack.Size = New-Object System.Drawing.Size(290, 36)
$form.Controls.Add($btnBack)

$txt = New-Object System.Windows.Forms.TextBox
$txt.Multiline = $true
$txt.ReadOnly = $true
$txt.ScrollBars = 'Vertical'
$txt.Location = New-Object System.Drawing.Point(15, 152)
$txt.Size = New-Object System.Drawing.Size(595, 276)
$form.Controls.Add($txt)
$script:LogSink = $txt

$btnApply.Add_Click({
  $txt.Clear()
  try { Invoke-Apply $chk.Checked $chkMov.Checked } catch { Log ('ОШИБКА: ' + $_.Exception.Message) }
})
$btnBack.Add_Click({
  $r = [System.Windows.Forms.MessageBox]::Show(
    'Восстановить и сохранения из бэкапа? (вернётся прогресс на момент установки патча)' ,
    'Откат', [System.Windows.Forms.MessageBoxButtons]::YesNoCancel)
  if ($r -eq 'Cancel') { return }
  $txt.Clear()
  try { Invoke-Rollback ($r -eq 'Yes') } catch { Log ('ОШИБКА: ' + $_.Exception.Message) }
})

[void]$form.ShowDialog()
