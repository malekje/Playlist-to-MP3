Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$root  = $PSScriptRoot
$tools = Join-Path $root 'tools'
$ytdlp = Join-Path $tools 'yt-dlp.exe'
$deno  = Join-Path $tools 'deno.exe'
$cfg   = Join-Path $root 'last-folder.txt'

if (-not (Test-Path $ytdlp) -or -not (Test-Path $deno) -or -not (Test-Path (Join-Path $tools 'ffmpeg.exe'))) {
    [System.Windows.Forms.MessageBox]::Show('Tools are missing. Please open Start.bat instead of app.ps1.', 'Playlist to MP3') | Out-Null
    exit
}

# ---------- state ----------
$script:proc = $null; $script:outTask = $null; $script:errTask = $null
$script:done = 0; $script:failed = 0; $script:skipped = 0; $script:cancelled = $false
$script:source = $null; $script:updating = $true; $script:busy = $false
$script:rows = New-Object System.Collections.ArrayList
$script:cur = $null; $script:idx = 0; $script:total = 0; $script:spMode = $false; $script:lastError = $null
$script:upd = $null; $script:updStart = $null

# ---------- look ----------
function C($r, $g, $b) { [System.Drawing.Color]::FromArgb($r, $g, $b) }
function Mix($a, $b, $t) { [System.Drawing.Color]::FromArgb([int]($a.R + ($b.R - $a.R) * $t), [int]($a.G + ($b.G - $a.G) * $t), [int]($a.B + ($b.B - $a.B) * $t)) }
function P($x, $y) { New-Object System.Drawing.PointF([single]$x, [single]$y) }
function New-Rect($x, $y, $w, $h) { New-Object System.Drawing.Rectangle([int]$x, [int]$y, [int]$w, [int]$h) }

$bg = C 17 17 19; $surface = C 30 30 34; $surface2 = C 48 48 55
$fg = C 244 244 245; $muted = C 150 150 160; $white = [System.Drawing.Color]::White
$ytRed = C 226 61 75; $spGreen = C 29 185 84; $green = C 34 197 94; $red = C 239 68 68
$script:accent = $surface2

$fTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$fBody  = New-Object System.Drawing.Font('Segoe UI', 10)
$fSmall = New-Object System.Drawing.Font('Segoe UI', 9)
$fBtn   = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$fRow   = New-Object System.Drawing.Font('Segoe UI Semibold', 10)

$tfCenter = [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter, NoPrefix'
$tfLeft   = [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, SingleLine, EndEllipsis, NoPrefix'
$tfRight  = [System.Windows.Forms.TextFormatFlags]'Right, VerticalCenter, SingleLine, NoPrefix'

$dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic, Instance')
function Set-DB($c) { $dbProp.SetValue($c, $true, $null) }

function RoundPath($x, $y, $w, $h, $r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [single]($r * 2)
    $p.AddArc([single]$x, [single]$y, $d, $d, 180, 90)
    $p.AddArc([single]($x + $w - $d), [single]$y, $d, $d, 270, 90)
    $p.AddArc([single]($x + $w - $d), [single]($y + $h - $d), $d, $d, 0, 90)
    $p.AddArc([single]$x, [single]($y + $h - $d), $d, $d, 90, 90)
    $p.CloseFigure(); $p
}
function Fill-Round($g, $color, $x, $y, $w, $h, $r) {
    if ($w -le 0) { return }
    $r = [Math]::Min($r, [Math]::Min($w, $h) / 2)
    $b = New-Object System.Drawing.SolidBrush $color
    $p = RoundPath $x $y $w $h $r
    $g.FillPath($b, $p); $b.Dispose(); $p.Dispose()
}

function Draw-Icon($g, $kind, $x, $cy, $main, $inner) {
    $b1 = New-Object System.Drawing.SolidBrush $main
    $b2 = New-Object System.Drawing.SolidBrush $inner
    if ($kind -eq 'yt') {
        Fill-Round $g $main $x ($cy - 9) 26 18 5
        $g.FillPolygon($b2, [System.Drawing.PointF[]]@((P ($x + 10) ($cy - 5)), (P ($x + 10) ($cy + 5)), (P ($x + 18.5) $cy)))
    } else {
        $g.FillEllipse($b1, [single]$x, [single]($cy - 12), [single]24, [single]24)
        foreach ($a in @(@(4, -6, 16, 10, 2.4), @(6, -1, 12, 8, 2.0), @(8, 4, 8, 6, 1.7))) {
            $pen = New-Object System.Drawing.Pen($inner, [single]$a[4])
            $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
            $g.DrawArc($pen, [single]($x + $a[0]), [single]($cy + $a[1]), [single]$a[2], [single]$a[3], [single]205, [single]130)
            $pen.Dispose()
        }
    }
    $b1.Dispose(); $b2.Dispose()
}

function Draw-Tick($g, $x, $y) {
    $b = New-Object System.Drawing.SolidBrush $green
    $g.FillEllipse($b, [single]$x, [single]$y, [single]22, [single]22); $b.Dispose()
    $pen = New-Object System.Drawing.Pen($white, [single]2.4)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $g.DrawLines($pen, [System.Drawing.PointF[]]@((P ($x + 6) ($y + 11.5)), (P ($x + 9.5) ($y + 15)), (P ($x + 16) ($y + 7.5))))
    $pen.Dispose()
}

# ---------- form ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Playlist to MP3'
# As tall as the screen allows, so the song list has room; can be resized taller/shorter by dragging
$screenH = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height
$form.FormBorderStyle = 'Sizable'; $form.MaximizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(660, [int][Math]::Max(600, [Math]::Min(1000, $screenH - 60)))
$form.StartPosition = 'CenterScreen'
$form.BackColor = $bg; $form.ForeColor = $fg; $form.Font = $fBody
$form.MinimumSize = New-Object System.Drawing.Size($form.Width, 560)
$form.MaximumSize = New-Object System.Drawing.Size($form.Width, 10000)   # fixed width, any height (0 would mean 0px here)
Set-DB $form

function New-Label($text, $x, $y, $w, $h, $font, $color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.BackColor = $bg
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $form.Controls.Add($l); $l
}

# Rounded button drawn by hand (WinForms buttons look dated)
function Paint-Pill($s, $g) {
    $t = $s.Tag
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear($s.Parent.BackColor)
    $toggle = $t.Kind -eq 'toggle'
    # toggles: dark card, lightly tinted + colored border when picked; buttons: softened color
    $fill = if ($toggle) { if ($t.Selected) { Mix $surface $t.Color 0.16 } else { $surface } } else { Mix $t.Color $bg 0.18 }
    if (-not $s.Enabled) { $fill = Mix $fill $s.Parent.BackColor 0.55 }
    elseif ($t.Hover) { $fill = Mix $fill $white 0.08 }
    $p = RoundPath 1 1 ($s.Width - 2.5) ($s.Height - 2.5) 12
    $b = New-Object System.Drawing.SolidBrush $fill; $g.FillPath($b, $p); $b.Dispose()
    if ($toggle) {
        $border = if ($t.Selected) { $t.Color } elseif ($t.Hover -and $s.Enabled) { Mix $surface2 $t.Color 0.5 } else { $surface2 }
        $pen = New-Object System.Drawing.Pen($border, [single]$(if ($t.Selected) { 2 } else { 1.5 }))
        $g.DrawPath($pen, $p); $pen.Dispose()
    }
    $p.Dispose()
    $txt = if (-not $s.Enabled) { $muted } elseif ($toggle -and -not $t.Selected -and $t.Icon) { $muted } else { $fg }
    if ($t.Icon) {
        $tw = [System.Windows.Forms.TextRenderer]::MeasureText($t.Text, $fBtn).Width
        $x0 = [int](($s.Width - (26 + 12 + $tw)) / 2)
        $inner = if ($t.Icon -eq 'sp') { $s.Parent.BackColor } else { $white }
        Draw-Icon $g $t.Icon $x0 ($s.Height / 2) $t.Color $inner
        [System.Windows.Forms.TextRenderer]::DrawText($g, $t.Text, $fBtn, (New-Rect ($x0 + 38) 0 ($tw + 10) $s.Height), $txt, $tfLeft)
    } else {
        [System.Windows.Forms.TextRenderer]::DrawText($g, $t.Text, $fBtn, $s.ClientRectangle, $txt, $tfCenter)
    }
}
function New-Pill($text, $x, $y, $w, $h, $color) {
    $b = New-Object System.Windows.Forms.Panel
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    Set-DB $b
    $b.Tag = @{ Text = $text; Color = $color; Hover = $false; Kind = 'btn'; Selected = $false; Icon = $null }
    $b.Add_Paint({ param($s, $e) Paint-Pill $s $e.Graphics })
    $b.Add_MouseEnter({ param($s, $e) $s.Tag.Hover = $true; $s.Invalidate() })
    $b.Add_MouseLeave({ param($s, $e) $s.Tag.Hover = $false; $s.Invalidate() })
    $b.Add_EnabledChanged({ param($s, $e) $s.Invalidate() })
    $form.Controls.Add($b); $b
}

# Rounded text box
function New-Input($x, $y, $w) {
    $c = New-Object System.Windows.Forms.Panel
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, 44)
    Set-DB $c
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.BorderStyle = 'None'; $tb.BackColor = $surface; $tb.ForeColor = $fg; $tb.Font = $fBody
    $tb.Location = New-Object System.Drawing.Point(14, 13); $tb.Width = $w - 28
    $c.Controls.Add($tb); $c.Tag = $tb
    $c.Add_Paint({ param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.Clear($bg)
        $p = RoundPath 0.5 0.5 ($s.Width - 1.5) ($s.Height - 1.5) 12
        $b = New-Object System.Drawing.SolidBrush $surface; $g.FillPath($b, $p); $b.Dispose()
        $pen = New-Object System.Drawing.Pen($(if ($s.Tag.Focused -and -not $s.Tag.ReadOnly) { $script:accent } else { $surface2 }), [single]1.5)
        $g.DrawPath($pen, $p); $pen.Dispose(); $p.Dispose()
    })
    $tb.Add_GotFocus({ param($s, $e) $s.Parent.Invalidate() })
    $tb.Add_LostFocus({ param($s, $e) $s.Parent.Invalidate() })
    $c.Add_Click({ param($s, $e) $s.Tag.Focus() })
    $form.Controls.Add($c); $tb
}

# ---------- layout ----------
New-Label 'Playlist to MP3' 26 18 400 40 $fTitle $fg | Out-Null
New-Label 'Download a whole playlist as MP3 in one click' 28 58 600 22 $fBody $muted | Out-Null

New-Label '1   Where is the playlist from?' 28 100 600 20 $fSmall $muted | Out-Null
$btnYT = New-Pill 'YouTube' 28 124 296 58 $ytRed
$btnSP = New-Pill 'Spotify' 336 124 296 58 $spGreen
$btnYT.Tag.Kind = 'toggle'; $btnYT.Tag.Icon = 'yt'
$btnSP.Tag.Kind = 'toggle'; $btnSP.Tag.Icon = 'sp'

$hint = New-Label '2   Paste the link' 28 200 600 20 $fSmall $muted
$urlBox = New-Input 28 224 604
$urlBox.ReadOnly = $true; $urlBox.BackColor = $surface
$urlBox.Text = ''

New-Label '3   Save to' 28 284 600 20 $fSmall $muted | Out-Null
$folderBox = New-Input 28 308 476
$folderBox.ReadOnly = $true; $folderBox.BackColor = $surface
$browse = New-Pill 'Browse' 516 308 116 44 $surface2

$dl     = New-Pill 'Download' 28 374 604 54 $surface2
$cancel = New-Pill 'Cancel' 28 374 604 54 $surface2
$cancel.Visible = $false

$status = New-Label 'Updating downloader...' 28 446 480 22 $fBody $fg
$open = New-Pill 'Open folder' 522 442 110 30 $surface
$open.Tag.Kind = 'toggle'; $open.Tag.Color = $muted

$overall = New-Object System.Windows.Forms.Panel
$overall.Location = New-Object System.Drawing.Point(28, 480); $overall.Size = New-Object System.Drawing.Size(604, 6)
$overall.Tag = @{ Pct = 0.0 }
Set-DB $overall
$overall.Add_Paint({ param($s, $e)
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.Clear($bg)
    Fill-Round $g $surface2 0 0 ($s.Width - 1) ($s.Height - 1) 3
    Fill-Round $g $script:accent 0 0 (($s.Width - 1) * $s.Tag.Pct) ($s.Height - 1) 3
})
$form.Controls.Add($overall)

$list = New-Object System.Windows.Forms.FlowLayoutPanel
$list.Location = New-Object System.Drawing.Point(28, 500); $list.Size = New-Object System.Drawing.Size(616, ($form.ClientSize.Height - 516))
$list.Anchor = 'Top, Bottom, Left'   # grows when the window is made taller
$list.FlowDirection = 'TopDown'; $list.WrapContents = $false; $list.AutoScroll = $true
$list.BackColor = $bg
Set-DB $list
$form.Controls.Add($list)

# ---------- song rows ----------
function Paint-Row($s, $g) {
    $t = $s.Tag; $w = $s.Width
    $g.SmoothingMode = 'AntiAlias'; $g.Clear($bg)
    $ok = $t.State -eq 'done' -or $t.State -eq 'skip'
    $rowBg = if ($ok) { Mix $surface $green 0.14 } elseif ($t.State -eq 'fail') { Mix $surface $red 0.12 } else { $surface }
    Fill-Round $g $rowBg 0 0 ($w - 1) ($s.Height - 1) 12

    [System.Windows.Forms.TextRenderer]::DrawText($g, ('{0:00}' -f $t.Index), $fSmall, (New-Rect 14 4 28 24), $muted, $tfLeft)
    [System.Windows.Forms.TextRenderer]::DrawText($g, $t.Name, $fRow, (New-Rect 46 4 ($w - 46 - 140) 24), $fg, $tfLeft)

    switch ($t.State) {
        'wait'   { $txt = 'Waiting';     $col = $muted }
        'dl'     { $txt = "$($t.Pct)%";  $col = $fg }
        'conv'   { $txt = 'Converting';  $col = $muted }
        'done'   { $txt = '100%';        $col = $green }
        'skip'   { $txt = 'Already had'; $col = $green }
        'cancel' { $txt = 'Cancelled';   $col = $muted }
        default  { $txt = $t.Note;       $col = $red }
    }
    if ($ok) {
        [System.Windows.Forms.TextRenderer]::DrawText($g, $txt, $fRow, (New-Rect ($w - 140) 4 96 24), $col, $tfRight)
        Draw-Tick $g ($w - 36) 5
    } else {
        [System.Windows.Forms.TextRenderer]::DrawText($g, $txt, $fRow, (New-Rect ($w - 140) 4 124 24), $col, $tfRight)
    }

    $bx = 46; $bw = $w - 46 - 16; $by = 33
    Fill-Round $g $surface2 $bx $by $bw 4 2
    $fillCol = if ($ok) { $green } elseif ($t.State -eq 'fail') { $red } else { $script:accent }
    $pct = if ($ok -or $t.State -eq 'fail') { 100 } else { $t.Pct }
    Fill-Round $g $fillCol $bx $by ($bw * $pct / 100) 4 2
}
function Add-Row($name) {
    $r = New-Object System.Windows.Forms.Panel
    $r.Size = New-Object System.Drawing.Size(594, 46)
    $r.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    Set-DB $r
    $r.Tag = @{ Index = $script:rows.Count + 1; Name = $name; Pct = 0; State = 'wait'; Note = '' }
    $r.Add_Paint({ param($s, $e) Paint-Row $s $e.Graphics })
    $list.Controls.Add($r); [void]$script:rows.Add($r); $r
}
function Set-Row($r, $state, $pct) {
    if (-not $r) { return }
    $r.Tag.State = $state
    if ($null -ne $pct) { $r.Tag.Pct = $pct }
    $r.Invalidate()
}
function Set-Name($path) {
    if ($script:spMode -or -not $script:cur) { return }
    $script:cur.Tag.Name = [IO.Path]::GetFileNameWithoutExtension($path) -replace '^\d+ - ', ''
    $script:cur.Invalidate()
}
function Clear-Rows {
    foreach ($r in @($script:rows)) { $list.Controls.Remove($r); $r.Dispose() }
    $script:rows.Clear()
}
function Ensure-Row { if (-not $script:cur) { if ($script:total -lt 1) { $script:total = 1; $script:idx = 1 }; $script:cur = Add-Row 'Song' } }
function Complete-Current {
    if (-not $script:cur) { return }
    if ($script:cur.Tag.State -eq 'conv') { Set-Row $script:cur 'done' 100; $script:done++ }
    elseif ($script:cur.Tag.State -eq 'dl') {
        # never reached conversion and no error: the search found nothing
        $script:cur.Tag.Note = 'Not found'; Set-Row $script:cur 'fail' $null; $script:failed++
    }
}
function Update-Overall {
    $n = $script:total
    $finished = $script:done + $script:skipped + $script:failed
    if ($n) {
        $overall.Tag.Pct = [Math]::Min(1.0, $finished / $n)
        $txt = "Song $([Math]::Min([Math]::Max($script:idx, 1), $n)) of $n"
        if ($script:done) { $txt += "     $($script:done) done" }
        $status.Text = $txt
    }
    $overall.Invalidate()
}

# ---------- Spotify ----------
# shortcut: relies on Spotify's public embed page and its guest token (unofficial, may break if Spotify changes them)
function Get-SpotifyTracks($kind, $id) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $html = (Invoke-WebRequest "https://open.spotify.com/embed/$kind/$id" -UseBasicParsing).Content
    if ($html -notmatch '(?s)<script id="__NEXT_DATA__" type="application/json">(.+?)</script>') { throw 'no data' }
    $state = ($Matches[1] | ConvertFrom-Json).props.pageProps.state
    $e = $state.data.entity
    $tracks = @($e.trackList | Where-Object { $_.title } | ForEach-Object { "$($_.subtitle) - $($_.title)" })
    if (-not $tracks.Count) { throw 'no tracks' }
    $limited = $false

    # The embed page stops at 100 songs: page through the rest via the web player's endpoint with the page's guest token.
    # shortcut: the query hash is pinned to Spotify's current web player; if it stops working, refresh the hash.
    if ($kind -eq 'playlist' -and $tracks.Count -ge 100) {
        $limited = $true
        $token = $state.settings.session.accessToken
        if ($token) {
            try {
                $all = New-Object System.Collections.ArrayList
                $offset = 0; $totalCount = 1
                while ($offset -lt $totalCount -and $offset -lt 10000) {
                    $body = @{
                        operationName = 'fetchPlaylist'
                        variables = @{ uri = "spotify:playlist:$id"; offset = $offset; limit = 100; enableWatchFeedEntrypoint = $true }
                        extensions = @{ persistedQuery = @{ version = 1; sha256Hash = '8964e8eafb21aa992a7d951d256d83285c04be2105d209262901de70cb97584a' } }
                    } | ConvertTo-Json -Depth 6 -Compress
                    $resp = Invoke-WebRequest 'https://api-partner.spotify.com/pathfinder/v1/query' -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -UseBasicParsing `
                        -ContentType 'application/json' -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36' `
                        -Headers @{ Authorization = "Bearer $token"; Accept = 'application/json' }
                    # decode as UTF-8 ourselves: PowerShell 5 guesses wrong and garbles accented artist names
                    $r = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
                    $content = $r.data.playlistV2.content
                    if (-not $content.items) { break }
                    $totalCount = [int]$content.totalCount
                    foreach ($it in $content.items) {
                        $t = $it.itemV2.data
                        if (-not $t.name) { continue }
                        $artists = if ($t.artists.items) { $t.artists.items } else { $t.albumOfTrack.artists.items }
                        [void]$all.Add("$(($artists | ForEach-Object { $_.profile.name }) -join ', ') - $($t.name)")
                    }
                    $offset += @($content.items).Count
                }
                if ($all.Count -gt $tracks.Count) { $tracks = @($all) }
                if ($offset -ge $totalCount) { $limited = $false }   # local/unavailable tracks have no name, so compare pages read, not songs kept
            } catch { }
        }
    }
    @{ Name = [string]$e.name; Tracks = $tracks; Limited = $limited }
}

# ---------- yt-dlp output ----------
function Handle-Line($l) {
    if ($l -match '^\[download\]\s+([\d\.]+)%') {
        Ensure-Row
        if ($script:cur.Tag.State -ne 'conv') { Set-Row $script:cur 'dl' ([Math]::Min(99, [int][double]$Matches[1])) }
        return
    }
    if ($script:spMode -and $l -match '^\[youtube:music:search_url\] Extracting URL:') {
        Complete-Current
        $script:idx++
        if ($script:idx -le $script:rows.Count) { $script:cur = $script:rows[$script:idx - 1]; Set-Row $script:cur 'dl' 0; $list.ScrollControlIntoView($script:cur) }
        Update-Overall; return
    }
    if (-not $script:spMode -and $l -match '^\[download\] Downloading item (\d+) of (\d+)') {
        Complete-Current
        $script:idx = [int]$Matches[1]; $script:total = [int]$Matches[2]
        $script:cur = Add-Row "Song $($script:idx)"; Set-Row $script:cur 'dl' 0
        $list.ScrollControlIntoView($script:cur)
        Update-Overall; return
    }
    if ($l -match '^\[info\] Writing video thumbnail .+? to: (.+)$') { Ensure-Row; Set-Name $Matches[1]; return }
    if ($l -match '^\[download\] Destination: (.+)$') { Ensure-Row; Set-Name $Matches[1]; return }
    if ($l -match '^\[ExtractAudio\]') { Set-Row $script:cur 'conv' 100; return }
    if ($l -match '^\[download\] (.+) has already been recorded in the archive') {
        Ensure-Row
        if (-not $script:spMode) { $script:cur.Tag.Name = $Matches[1] }
        Set-Row $script:cur 'skip' 100; $script:skipped++; Update-Overall; return
    }
    if ($l -match '^ERROR: (.+)$') {
        $msg = $Matches[1]
        if ($script:cur -and @('done', 'skip', 'fail') -notcontains $script:cur.Tag.State) {
            $script:cur.Tag.Note = if ($msg -match 'unavailable|private|removed|terminated') { 'Unavailable' } else { 'Failed' }
            Set-Row $script:cur 'fail' $null; $script:failed++; Update-Overall
        }
        $script:lastError = $msg
    }
}

function Pump {
    while ($script:outTask -and $script:outTask.IsCompleted) {
        $l = $script:outTask.Result
        if ($null -eq $l) { $script:outTask = $null } else { Handle-Line $l; $script:outTask = $script:proc.StandardOutput.ReadLineAsync() }
    }
    while ($script:errTask -and $script:errTask.IsCompleted) {
        $l = $script:errTask.Result
        if ($null -eq $l) { $script:errTask = $null } else { Handle-Line $l; $script:errTask = $script:proc.StandardError.ReadLineAsync() }
    }
    if ($script:proc -and $script:proc.HasExited -and -not $script:outTask -and -not $script:errTask) { Finish }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({ Pump })

# ---------- actions ----------
function Show-Msg($m) { [System.Windows.Forms.MessageBox]::Show($m, 'Playlist to MP3') | Out-Null }

function Update-Buttons {
    $dl.Enabled = [bool]$script:source -and -not $script:updating
    $dl.Visible = -not $script:busy; $cancel.Visible = $script:busy
    $btnYT.Enabled = -not $script:busy; $btnSP.Enabled = -not $script:busy; $browse.Enabled = -not $script:busy
    $urlBox.ReadOnly = $script:busy -or -not $script:source
    $urlBox.BackColor = $surface
}

function Select-Source($src) {
    $script:source = $src
    $script:accent = if ($src -eq 'yt') { $ytRed } else { $spGreen }
    $btnYT.Tag.Selected = $src -eq 'yt'; $btnSP.Tag.Selected = $src -eq 'sp'
    $dl.Tag.Color = $script:accent
    $hint.Text = if ($src -eq 'yt') { '2   Paste the YouTube playlist (or video) link' } else { '2   Paste the Spotify playlist (or album) link' }
    Update-Buttons
    foreach ($c in @($btnYT, $btnSP, $dl, $overall, $urlBox.Parent)) { $c.Invalidate() }
    if (-not $script:updating) { $status.Text = 'Ready' }
    $urlBox.Focus() | Out-Null
}

function Quote($v) {
    $v = [string]$v -replace '"', '\"'
    if ($v.EndsWith('\')) { $v += '\' }
    '"' + $v + '"'
}

function Start-Download {
    if (-not $dl.Enabled -or $script:busy) { return }
    $url = $urlBox.Text.Trim()
    if (-not $url) { Show-Msg 'Paste a link first.'; return }
    if ($script:source -eq 'yt' -and $url -notmatch 'youtube\.com|youtu\.be') { Show-Msg "That doesn't look like a YouTube link. If it's from Spotify, pick Spotify above."; return }
    if ($script:source -eq 'sp' -and $url -notmatch 'open\.spotify\.com/') { Show-Msg "That doesn't look like a Spotify link. If it's from YouTube, pick YouTube above."; return }

    $out = $folderBox.Text
    Clear-Rows
    $script:done = 0; $script:failed = 0; $script:skipped = 0; $script:cancelled = $false
    $script:cur = $null; $script:idx = 0; $script:total = 0; $script:spMode = $false; $script:lastError = $null
    $overall.Tag.Pct = 0; $overall.Invalidate()

    if ($script:source -eq 'sp') {
        if (-not ($url -match 'open\.spotify\.com/(?:intl-[\w-]+/)?(playlist|album|track)/(\w+)')) { Show-Msg 'Paste a Spotify playlist, album or song link.'; return }
        $status.Text = 'Reading Spotify playlist...'; $form.Refresh()
        try { $sp = Get-SpotifyTracks $Matches[1] $Matches[2] }
        catch { $status.Text = 'Ready'; Show-Msg "Couldn't read that Spotify link. Make sure the playlist is public."; return }
        if ($sp.Limited) { Show-Msg 'Spotify only let the app see the first 100 songs of this playlist, so those 100 will be downloaded.' }
        $script:spMode = $true; $script:total = $sp.Tracks.Count
        $list.SuspendLayout(); foreach ($t in $sp.Tracks) { [void](Add-Row $t) }; $list.ResumeLayout()
        # YouTube Music "Songs" results are the official album audio (same length as Spotify), not music videos with intros
        $targets = @($sp.Tracks | ForEach-Object { 'https://music.youtube.com/search?q=' + [uri]::EscapeDataString($_) + '#songs' })
        # folder named after the Spotify playlist; % escaped for the yt-dlp template
        $folder = (($sp.Name -replace '[\\/:*?"<>|]', '_').Trim() -replace '%', '%%')
        if (-not $folder) { $folder = 'Spotify' }
        $tpl = "$folder/%(autonumber)02d - %(artist,uploader)s - %(title)s.%(ext)s"
    }
    elseif ($url -match '[?&]list=([\w-]+)') {
        $targets = @("https://www.youtube.com/playlist?list=$($Matches[1])")
        $tpl = '%(playlist_title)s/%(playlist_index)02d - %(title)s.%(ext)s'
    }
    else { $targets = @($url); $tpl = '%(title)s.%(ext)s' }

    if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
    Set-Content -Path $cfg -Value $out

    $a = @('--js-runtimes', "deno:$deno", '--ffmpeg-location', $tools,
           '-x', '--audio-format', 'mp3', '--audio-quality', '0',
           '--yes-playlist', '--ignore-errors', '--embed-thumbnail', '--add-metadata',
           '--download-archive', (Join-Path $out 'done.txt'),
           '-P', $out, '-o', $tpl,
           '--newline', '--progress', '--no-update', '--encoding', 'utf-8')
    if ($script:spMode) {
        # long song lists go in a file: Windows caps a command line at ~32k characters
        $batch = Join-Path $env:TEMP 'playlist-to-mp3-songs.txt'
        [IO.File]::WriteAllLines($batch, [string[]]$targets, (New-Object Text.UTF8Encoding $false))
        $a += @('--batch-file', $batch, '--playlist-items', '1')   # top song result only
    } else { $a += $targets }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ytdlp
    $psi.Arguments = ($a | ForEach-Object { Quote $_ }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'

    $status.Text = 'Starting...'
    $script:busy = $true; Update-Buttons
    $script:proc = [System.Diagnostics.Process]::Start($psi)
    $script:outTask = $script:proc.StandardOutput.ReadLineAsync()
    $script:errTask = $script:proc.StandardError.ReadLineAsync()
    $timer.Start()
}

function Finish {
    $timer.Stop()
    if ($script:proc) { $script:proc.Dispose(); $script:proc = $null }
    if ($script:cancelled) {
        if ($script:cur -and ($script:cur.Tag.State -eq 'dl' -or $script:cur.Tag.State -eq 'conv')) { Set-Row $script:cur 'cancel' $null }
        $status.Text = 'Cancelled.'
    } else {
        Complete-Current
        $overall.Tag.Pct = 1.0; $overall.Invalidate()
        if (-not $script:rows.Count -and $script:lastError) {
            $e = $script:lastError; if ($e.Length -gt 70) { $e = $e.Substring(0, 70) + '...' }
            $status.Text = "Error: $e"
        } else {
            $msg = "Finished: $($script:done) downloaded"
            if ($script:skipped) { $msg += ", $($script:skipped) already had" }
            if ($script:failed)  { $msg += ", $($script:failed) unavailable" }
            $status.Text = $msg
        }
    }
    $script:busy = $false; Update-Buttons
}

function Stop-Download {
    if ($script:proc -and -not $script:proc.HasExited) {
        $script:cancelled = $true
        Start-Process taskkill -ArgumentList "/PID $($script:proc.Id) /T /F" -WindowStyle Hidden -Wait
    }
}

$btnYT.Add_Click({ Select-Source 'yt' })
$btnSP.Add_Click({ Select-Source 'sp' })
$dl.Add_Click({ Start-Download })
$cancel.Add_Click({ Stop-Download })
$urlBox.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Start-Download } })
$browse.Add_Click({
    # The old folder picker is tiny; this file dialog trick gives the normal Explorer window
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title = 'Open the folder where you want the music, then click Open'
    $d.ValidateNames = $false; $d.CheckFileExists = $false; $d.CheckPathExists = $true
    $d.FileName = 'Save here'
    if (Test-Path $folderBox.Text) { $d.InitialDirectory = $folderBox.Text }
    if ($d.ShowDialog($form) -eq 'OK') { $folderBox.Text = Split-Path $d.FileName -Parent }
})
$open.Add_Click({ if (Test-Path $folderBox.Text) { Start-Process explorer.exe $folderBox.Text } })
$form.Add_FormClosing({ Stop-Download })

$last = $null
if (Test-Path $cfg) { $last = (Get-Content $cfg -Raw).Trim() }
if (-not $last) { $last = [Environment]::GetFolderPath('MyMusic') }
$folderBox.Text = $last

# Keep yt-dlp up to date (old versions get blocked by YouTube with 403)
$updTimer = New-Object System.Windows.Forms.Timer
$updTimer.Interval = 300
$updTimer.Add_Tick({
    if ($script:upd.HasExited -or ((Get-Date) - $script:updStart).TotalSeconds -gt 60) {
        $updTimer.Stop(); $script:updating = $false; Update-Buttons
        $status.Text = if ($script:source) { 'Ready' } else { 'Choose YouTube or Spotify to start' }
    }
})
$form.Add_Shown({
    Update-Buttons
    $script:updStart = Get-Date
    $script:upd = Start-Process $ytdlp -ArgumentList '-U' -WindowStyle Hidden -PassThru
    $updTimer.Start()
})

$form.ShowDialog() | Out-Null
