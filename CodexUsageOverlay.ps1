[CmdletBinding()]
param(
    [int]$RefreshSeconds = 60,
    [string]$StopMarkerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Core') {
    throw '请使用 PowerShell 7（pwsh.exe）运行。'
}

$createdNew = $false
$script:singleInstanceMutex = [Threading.Mutex]::new(
    $true,
    'Local\CodexUsageOverlay',
    [ref]$createdNew
)
if (-not $createdNew) {
    $script:singleInstanceMutex.Dispose()
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class CodexWindowFinder
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct MONITORINFO
    {
        public int Size;
        public RECT Monitor;
        public RECT Work;
        public uint Flags;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);
    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hWnd, uint command);
    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(
        IntPtr hWnd,
        int attribute,
        out RECT value,
        int valueSize);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

    public static bool GetVisibleWindowRect(IntPtr hWnd, out RECT rect)
    {
        const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
        bool found = DwmGetWindowAttribute(
            hWnd,
            DWMWA_EXTENDED_FRAME_BOUNDS,
            out rect,
            Marshal.SizeOf<RECT>()) == 0;
        if (!found)
        {
            found = GetWindowRect(hWnd, out rect);
        }
        if (!found) return false;

        // Electron 最大化窗口仍会把不可见缩放边框报告为可见边界（通常向外 8px）。
        // 最大化时以所属显示器工作区为准，避免顶部状态条被负坐标裁切。
        if (IsZoomed(hWnd))
        {
            const uint MONITOR_DEFAULTTONEAREST = 2;
            var monitor = MonitorFromWindow(hWnd, MONITOR_DEFAULTTONEAREST);
            var info = new MONITORINFO { Size = Marshal.SizeOf<MONITORINFO>() };
            if (monitor != IntPtr.Zero && GetMonitorInfo(monitor, ref info))
            {
                rect = info.Work;
            }
        }
        return true;
    }

    public static bool GetMonitorWorkArea(IntPtr hWnd, out RECT rect)
    {
        rect = new RECT();
        const uint MONITOR_DEFAULTTONEAREST = 2;
        var monitor = MonitorFromWindow(hWnd, MONITOR_DEFAULTTONEAREST);
        var info = new MONITORINFO { Size = Marshal.SizeOf<MONITORINFO>() };
        if (monitor == IntPtr.Zero || !GetMonitorInfo(monitor, ref info)) return false;
        rect = info.Work;
        return true;
    }

    private static bool IsCodexProcess(uint processId)
    {
        try
        {
            var name = Process.GetProcessById((int)processId).ProcessName;
            return name.Equals("ChatGPT", StringComparison.OrdinalIgnoreCase)
                || name.Equals("Codex", StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    public static IntPtr FindLargestVisibleWindow()
    {
        IntPtr best = IntPtr.Zero;
        long bestArea = 0;
        EnumWindows((window, _) =>
        {
            if (!IsWindowVisible(window) || IsIconic(window)) return true;
            GetWindowThreadProcessId(window, out var processId);
            if (!IsCodexProcess(processId)) return true;
            if (!GetVisibleWindowRect(window, out var rect)) return true;
            long width = Math.Max(0, rect.Right - rect.Left);
            long height = Math.Max(0, rect.Bottom - rect.Top);
            long area = width * height;
            if (area > bestArea && width > 500 && height > 300)
            {
                bestArea = area;
                best = window;
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }

    public static bool PlaceWindowAbove(IntPtr window, IntPtr codexWindow)
    {
        const uint GW_HWNDPREV = 3;
        const uint SWP_NOSIZE = 0x0001;
        const uint SWP_NOMOVE = 0x0002;
        const uint SWP_NOACTIVATE = 0x0010;

        // hWndInsertAfter 表示“排在该窗口之后（更低）”。要让浮层位于
        // Codex 上方，需找到 Codex 当前的上一层，再插入两者之间。
        var windowAboveCodex = GetWindow(codexWindow, GW_HWNDPREV);
        if (windowAboveCodex == window) return true;
        return SetWindowPos(
            window,
            windowAboveCodex,
            0,
            0,
            0,
            0,
            SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE);
    }
}
'@

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="224" Height="28" WindowStyle="None" Cursor="Arrow"
        AllowsTransparency="True" Background="Transparent" Topmost="False"
        ShowInTaskbar="False" ShowActivated="False" Focusable="True"
        ResizeMode="NoResize" Opacity="1">
  <Grid Width="224" Height="26" VerticalAlignment="Center" ClipToBounds="True">
    <Border Background="#FFE3E5E7" BorderBrush="#FFCACED2" BorderThickness="1" CornerRadius="13" />
    <Border x:Name="ProgressFill" Width="0" HorizontalAlignment="Left"
            CornerRadius="11" Margin="2">
      <Border.Background>
        <LinearGradientBrush StartPoint="1,0.5" EndPoint="0,0.5">
          <GradientStop Color="#FFB7E6C4" Offset="0" />
          <GradientStop Color="#FF6FC68A" Offset="1" />
        </LinearGradientBrush>
      </Border.Background>
    </Border>
    <TextBlock x:Name="PeriodText" Text="--" Foreground="#FF65696D" FontSize="10.5"
               FontWeight="SemiBold" HorizontalAlignment="Left" VerticalAlignment="Center"
               Margin="12,0,0,0" />
    <TextBlock x:Name="PercentText" Text="--" Foreground="#FF4F5357" FontSize="11.5"
               FontWeight="SemiBold" HorizontalAlignment="Right" VerticalAlignment="Center"
               Margin="0,0,25,0" />
    <Border x:Name="ResetCreditBadge" MinWidth="15" Height="15" Padding="4,0"
            Background="#FF62C887" BorderBrush="#FFF8F8F8" BorderThickness="1"
            CornerRadius="8" HorizontalAlignment="Right" VerticalAlignment="Top"
            Margin="0,1,2,0" Visibility="Collapsed" Panel.ZIndex="3">
      <TextBlock x:Name="ResetCreditCountText" Text="0" Foreground="#FFFFFFFF"
                 FontSize="9" FontWeight="SemiBold" TextAlignment="Center"
                 HorizontalAlignment="Center" VerticalAlignment="Center" />
    </Border>
  </Grid>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$script:overlayHandle = [Windows.Interop.WindowInteropHelper]::new($window).EnsureHandle()
$progressFill = $window.FindName('ProgressFill')
$periodText = $window.FindName('PeriodText')
$percentText = $window.FindName('PercentText')
$resetCreditBadge = $window.FindName('ResetCreditBadge')
$resetCreditCountText = $window.FindName('ResetCreditCountText')

$resetToolTip = [Windows.Controls.ToolTip]::new()
$resetToolTip.Placement = 'Bottom'
$resetToolTip.PlacementTarget = $window
$resetToolTip.VerticalOffset = 5
$resetToolTip.Background = [Windows.Media.Brushes]::Transparent
$resetToolTip.BorderThickness = [Windows.Thickness]::new(0)
$resetToolTip.Padding = [Windows.Thickness]::new(0)
$resetToolTip.HasDropShadow = $false
$tipBorder = [Windows.Controls.Border]::new()
$tipBorder.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#FAF7F7F7')
$tipBorder.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFE1E1E1')
$tipBorder.BorderThickness = [Windows.Thickness]::new(1)
$tipBorder.CornerRadius = [Windows.CornerRadius]::new(8)
$tipBorder.Padding = [Windows.Thickness]::new(10, 6, 10, 6)
$resetToolTipText = [Windows.Controls.TextBlock]::new()
$resetToolTipText.Text = '正在读取…'
$resetToolTipText.FontSize = 11
$resetToolTipText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF202124')
$tipBorder.Child = $resetToolTipText
$resetToolTip.Content = $tipBorder
$window.ToolTip = $resetToolTip
$resetToolTip.Add_Opened({
    $tipBorder.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $resetToolTip.HorizontalOffset = ($window.ActualWidth - $tipBorder.DesiredSize.Width) / 2
})
[Windows.Controls.ToolTipService]::SetInitialShowDelay($window, 180)
[Windows.Controls.ToolTipService]::SetShowDuration($window, 12000)

$resetCreditToolTip = [Windows.Controls.ToolTip]::new()
$resetCreditToolTip.Placement = 'Bottom'
$resetCreditToolTip.PlacementTarget = $resetCreditBadge
$resetCreditToolTip.VerticalOffset = 5
$resetCreditToolTip.Background = [Windows.Media.Brushes]::Transparent
$resetCreditToolTip.BorderThickness = [Windows.Thickness]::new(0)
$resetCreditToolTip.Padding = [Windows.Thickness]::new(0)
$resetCreditToolTip.HasDropShadow = $false
$resetCreditTipBorder = [Windows.Controls.Border]::new()
$resetCreditTipBorder.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#FAF7F7F7')
$resetCreditTipBorder.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFE1E1E1')
$resetCreditTipBorder.BorderThickness = [Windows.Thickness]::new(1)
$resetCreditTipBorder.CornerRadius = [Windows.CornerRadius]::new(8)
$resetCreditTipBorder.Padding = [Windows.Thickness]::new(10, 6, 10, 6)
$resetCreditToolTipText = [Windows.Controls.TextBlock]::new()
$resetCreditToolTipText.FontSize = 11
$resetCreditToolTipText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF202124')
$resetCreditTipBorder.Child = $resetCreditToolTipText
$resetCreditToolTip.Content = $resetCreditTipBorder
$resetCreditBadge.ToolTip = $resetCreditToolTip
$resetCreditToolTip.Add_Opened({
    $resetCreditTipBorder.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $resetCreditToolTip.HorizontalOffset = `
        ($resetCreditBadge.ActualWidth - $resetCreditTipBorder.DesiredSize.Width) / 2
})
[Windows.Controls.ToolTipService]::SetInitialShowDelay($resetCreditBadge, 180)
[Windows.Controls.ToolTipService]::SetShowDuration($resetCreditBadge, 12000)
$watcherScript = Join-Path $PSScriptRoot 'Watch-CodexUsage.ps1'
$script:usageCommands = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:usageJob = $null
$script:nextWatcherRestart = [DateTime]::MinValue
$script:hasData = $false
$script:lastUsageData = $null
$script:detailsWindow = $null

function Format-WindowLabel([int]$minutes, [int]$index) {
    if ($minutes -ge 10000) { return '每周' }
    if ($minutes -ge 1440) { return ('每{0}天' -f [Math]::Round($minutes / 1440)) }
    if ($minutes -ge 60) { return ('每{0}小时' -f [Math]::Round($minutes / 60)) }
    if ($minutes -gt 0) { return ('每{0}分钟' -f $minutes) }
    return ('限额 {0}' -f ($index + 1))
}

function Format-ResetTime([long]$unixSeconds) {
    if ($unixSeconds -le 0) { return '' }
    $reset = [DateTimeOffset]::FromUnixTimeSeconds($unixSeconds).ToLocalTime()
    $remaining = $reset - [DateTimeOffset]::Now
    if ($remaining.TotalSeconds -le 0) { return '即将重置' }
    if ($remaining.TotalDays -ge 1) { return ('{0}天{1}小时后' -f [Math]::Floor($remaining.TotalDays), $remaining.Hours) }
    if ($remaining.TotalHours -ge 1) { return ('{0}小时{1}分后' -f [Math]::Floor($remaining.TotalHours), $remaining.Minutes) }
    return ('{0}分钟后' -f [Math]::Max(1, [Math]::Ceiling($remaining.TotalMinutes)))
}

function Update-ResetCreditBadge([object]$data) {
    $resetProperty = if ($data) { $data.PSObject.Properties['rateLimitResetCredits'] } else { $null }
    $resetData = if ($resetProperty) { $resetProperty.Value } else { $null }
    $countProperty = if ($resetData) { $resetData.PSObject.Properties['availableCount'] } else { $null }
    $availableCount = if ($countProperty) { [Math]::Max(0, [int]$countProperty.Value) } else { 0 }

    if ($availableCount -le 0) {
        $resetCreditBadge.Visibility = [Windows.Visibility]::Collapsed
        return
    }

    $resetCreditCountText.Text = [string]$availableCount
    $creditsProperty = $resetData.PSObject.Properties['credits']
    $nowUnix = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $earliestCredit = if ($creditsProperty -and $creditsProperty.Value) {
        @($creditsProperty.Value) |
            Where-Object {
                $statusProperty = $_.PSObject.Properties['status']
                $expiryProperty = $_.PSObject.Properties['expiresAt']
                (-not $statusProperty -or [string]$statusProperty.Value -eq 'available') -and
                    $expiryProperty -and [long]$expiryProperty.Value -gt $nowUnix
            } |
            Sort-Object -Property expiresAt |
            Select-Object -First 1
    }

    if ($earliestCredit) {
        $expiryUnix = [long]$earliestCredit.expiresAt
        $expiry = [DateTimeOffset]::FromUnixTimeSeconds($expiryUnix).ToLocalTime()
        $secondsRemaining = $expiryUnix - $nowUnix
        $resetCreditBadge.Background = if ($secondsRemaining -le 24 * 60 * 60) {
            Get-UiBrush '#FFE47D76'
        }
        elseif ($secondsRemaining -le 3 * 24 * 60 * 60) {
            Get-UiBrush '#FFF0A84F'
        }
        else {
            Get-UiBrush '#FF6FC68A'
        }
        $resetCreditToolTipText.Text = '可用重置次数 {0} · 最早于 {1} 到期' -f `
            $availableCount, $expiry.ToString('M月d日 HH:mm')
    }
    else {
        $resetCreditBadge.Background = Get-UiBrush '#FFA7ADB3'
        $resetCreditToolTipText.Text = '可用重置次数 {0} · 到期时间未知' -f $availableCount
    }
    $resetCreditBadge.Visibility = [Windows.Visibility]::Visible
}

function Get-UiBrush([string]$color) {
    [Windows.Media.BrushConverter]::new().ConvertFromString($color)
}

function New-UiGradient([string]$startColor, [string]$endColor) {
    $gradient = [Windows.Media.LinearGradientBrush]::new()
    $gradient.StartPoint = [Windows.Point]::new(1, 0.5)
    $gradient.EndPoint = [Windows.Point]::new(0, 0.5)
    $gradient.GradientStops.Add([Windows.Media.GradientStop]::new(
        [Windows.Media.ColorConverter]::ConvertFromString($startColor), 0
    ))
    $gradient.GradientStops.Add([Windows.Media.GradientStop]::new(
        [Windows.Media.ColorConverter]::ConvertFromString($endColor), 1
    ))
    $gradient
}

function New-DetailText([string]$text, [double]$fontSize, [string]$color, [string]$weight = 'Normal') {
    $label = [Windows.Controls.TextBlock]::new()
    $label.Text = $text
    $label.FontSize = $fontSize
    $label.Foreground = Get-UiBrush $color
    $label.FontWeight = $weight
    $label
}

function Add-LimitDetailCard([Windows.Controls.Panel]$parent, [object]$limitWindow) {
    $remainingPercent = [Math]::Max(0, [Math]::Min(100, 100 - [double]$limitWindow.usedPercent))
    $periodLabel = Format-WindowLabel ([int]$limitWindow.windowDurationMins) 0
    $resetAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$limitWindow.resetsAt).ToLocalTime()

    $card = [Windows.Controls.Border]::new()
    $card.Background = Get-UiBrush '#FFFFFFFF'
    $card.BorderBrush = Get-UiBrush '#FFE3E3E3'
    $card.BorderThickness = [Windows.Thickness]::new(1)
    $card.CornerRadius = [Windows.CornerRadius]::new(14)
    $card.Padding = [Windows.Thickness]::new(16, 14, 16, 14)
    $card.Margin = [Windows.Thickness]::new(0, 0, 0, 14)

    $content = [Windows.Controls.StackPanel]::new()
    $header = [Windows.Controls.Grid]::new()
    $header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })
    $header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::Auto })
    $title = New-DetailText "$periodLabel 使用限额" 14 '#FF202124' 'SemiBold'
    $remaining = New-DetailText ('剩余 {0:0}%' -f $remainingPercent) 13 '#FF6F7378'
    [Windows.Controls.Grid]::SetColumn($remaining, 1)
    $header.Children.Add($title) | Out-Null
    $header.Children.Add($remaining) | Out-Null
    $content.Children.Add($header) | Out-Null

    $reset = New-DetailText ('将于 {0} 重置' -f $resetAt.ToString('M月d日 HH:mm')) 12 '#FF777B80'
    $reset.Margin = [Windows.Thickness]::new(0, 4, 0, 12)
    $content.Children.Add($reset) | Out-Null

    $track = [Windows.Controls.Grid]::new()
    $track.Width = 360
    $track.Height = 7
    $track.HorizontalAlignment = 'Left'
    $trackBackground = [Windows.Controls.Border]::new()
    $trackBackground.Background = Get-UiBrush '#FFE5E7EB'
    $trackBackground.CornerRadius = [Windows.CornerRadius]::new(4)
    $fill = [Windows.Controls.Border]::new()
    $fill.Width = 3.6 * $remainingPercent
    $fill.HorizontalAlignment = 'Left'
    $fill.Background = Get-UiBrush '#FF202124'
    $fill.CornerRadius = [Windows.CornerRadius]::new(4)
    $track.Children.Add($trackBackground) | Out-Null
    $track.Children.Add($fill) | Out-Null
    $content.Children.Add($track) | Out-Null

    $card.Child = $content
    $parent.Children.Add($card) | Out-Null
}

function Add-ResetCreditsCard([Windows.Controls.Panel]$parent, [object]$resetData) {
    if (-not $resetData -or [int]$resetData.availableCount -le 0) { return }

    $card = [Windows.Controls.Border]::new()
    $card.Background = Get-UiBrush '#FFFFFFFF'
    $card.BorderBrush = Get-UiBrush '#FFE3E3E3'
    $card.BorderThickness = [Windows.Thickness]::new(1)
    $card.CornerRadius = [Windows.CornerRadius]::new(14)
    $card.Padding = [Windows.Thickness]::new(16, 14, 16, 8)
    $card.Margin = [Windows.Thickness]::new(0, 0, 0, 14)

    $content = [Windows.Controls.StackPanel]::new()
    $header = [Windows.Controls.Grid]::new()
    $header.Margin = [Windows.Thickness]::new(0, 0, 0, 8)
    $header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })
    $header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::Auto })
    $title = New-DetailText '使用限额重置' 14 '#FF202124' 'SemiBold'
    $countBadge = [Windows.Controls.Border]::new()
    $countBadge.Background = Get-UiBrush '#FFD9F4E4'
    $countBadge.CornerRadius = [Windows.CornerRadius]::new(12)
    $countBadge.Padding = [Windows.Thickness]::new(10, 3, 10, 3)
    $countBadge.Child = New-DetailText ('可用 {0} 次' -f [int]$resetData.availableCount) 11 '#FF147A42' 'SemiBold'
    [Windows.Controls.Grid]::SetColumn($countBadge, 1)
    $header.Children.Add($title) | Out-Null
    $header.Children.Add($countBadge) | Out-Null
    $content.Children.Add($header) | Out-Null

    $credits = @($resetData.credits)
    if ($credits.Count -eq 0) {
        $summary = New-DetailText ('当前共有 {0} 次可用重置' -f [int]$resetData.availableCount) 12 '#FF6F7378'
        $summary.Margin = [Windows.Thickness]::new(0, 8, 0, 10)
        $content.Children.Add($summary) | Out-Null
    }
    else {
        $creditIndex = 0
        foreach ($credit in $credits) {
            if ($creditIndex -gt 0) {
                $separator = [Windows.Controls.Border]::new()
                $separator.Height = 1
                $separator.Background = Get-UiBrush '#FFE9E9E9'
                $separator.Margin = [Windows.Thickness]::new(0, 2, 0, 2)
                $content.Children.Add($separator) | Out-Null
            }

            $row = [Windows.Controls.Grid]::new()
            $row.Margin = [Windows.Thickness]::new(0, 9, 0, 9)
            $row.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })
            $row.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::Auto })
            $textStack = [Windows.Controls.StackPanel]::new()
            $creditTitle = if ($credit.title) { [string]$credit.title } else { 'Full reset' }
            $textStack.Children.Add((New-DetailText $creditTitle 12 '#FF202124' 'SemiBold')) | Out-Null
            $expiryText = if ($credit.expiresAt) {
                $expiry = [DateTimeOffset]::FromUnixTimeSeconds([long]$credit.expiresAt).ToLocalTime()
                '将于 {0} 到期' -f $expiry.ToString('M月d日 HH:mm')
            }
            else { '暂无到期时间' }
            $expiryLabel = New-DetailText $expiryText 11 '#FF777B80'
            $expiryLabel.Margin = [Windows.Thickness]::new(0, 4, 0, 0)
            $textStack.Children.Add($expiryLabel) | Out-Null

            $availableBadge = [Windows.Controls.Border]::new()
            $availableBadge.Background = Get-UiBrush '#FF202124'
            $availableBadge.CornerRadius = [Windows.CornerRadius]::new(10)
            $availableBadge.Padding = [Windows.Thickness]::new(11, 5, 11, 5)
            $availableBadge.VerticalAlignment = 'Center'
            $availableBadge.Child = New-DetailText '可用' 11 '#FFFFFFFF' 'SemiBold'
            [Windows.Controls.Grid]::SetColumn($availableBadge, 1)
            $row.Children.Add($textStack) | Out-Null
            $row.Children.Add($availableBadge) | Out-Null
            $content.Children.Add($row) | Out-Null
            $creditIndex++
        }
    }

    $card.Child = $content
    $parent.Children.Add($card) | Out-Null
}

function Update-UsageDetails([object]$data) {
    if (-not $script:detailsWindow) { return }
    $body = $script:detailsWindow.FindName('DetailsBody')
    $body.Children.Clear()

    $codexBucket = $null
    if ($data.rateLimitsByLimitId) {
        $codexProperty = $data.rateLimitsByLimitId.PSObject.Properties['codex']
        if ($codexProperty) { $codexBucket = $codexProperty.Value }
    }
    if (-not $codexBucket) { $codexBucket = $data.rateLimits }

    foreach ($windowName in @('primary', 'secondary')) {
        if ($codexBucket -and $codexBucket.$windowName) {
            Add-LimitDetailCard $body $codexBucket.$windowName
        }
    }
    Add-ResetCreditsCard $body $data.rateLimitResetCredits

    $note = New-DetailText '只读展示 · 数据每 60 秒自动更新' 10 '#FF9AA0A6'
    $note.HorizontalAlignment = 'Center'
    $note.Margin = [Windows.Thickness]::new(0, 2, 0, 2)
    $body.Children.Add($note) | Out-Null
}

function Show-UsageDetails {
    if (-not $script:lastUsageData) {
        [Windows.MessageBox]::Show('正在读取用量，请稍后再试。', 'Codex 用量') | Out-Null
        Request-UsageRefresh
        return
    }
    if ($script:detailsWindow -and $script:detailsWindow.IsVisible) {
        Update-DetailsWindowPosition
        $script:detailsWindow.Activate() | Out-Null
        return
    }

    [xml]$detailsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="440" Height="540" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="NoResize" Topmost="False"
        WindowStartupLocation="Manual" ShowInTaskbar="False">
  <Border Background="#FFF8F8F8" BorderBrush="#FFE1E1E1" BorderThickness="1" CornerRadius="18">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="58" />
        <RowDefinition Height="*" />
      </Grid.RowDefinitions>
      <Grid x:Name="DetailsHeader" Margin="18,0,12,0" Background="Transparent">
        <TextBlock Text="使用量" FontSize="20" FontWeight="SemiBold" Foreground="#FF202124"
                   VerticalAlignment="Center" />
        <Button x:Name="DetailsClose" Content="×" Width="32" Height="32"
                HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="20"
                Foreground="#FF4B4F52" Background="Transparent" BorderThickness="0" Cursor="Hand">
        <Button.Template>
          <ControlTemplate TargetType="{x:Type Button}">
            <Border x:Name="CloseButtonBackground" Background="{TemplateBinding Background}"
                    CornerRadius="8" SnapsToDevicePixels="True">
              <ContentPresenter x:Name="CloseButtonContent" HorizontalAlignment="Center"
                                VerticalAlignment="Center" TextElement.Foreground="{TemplateBinding Foreground}" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="CloseButtonBackground" Property="Background" Value="#FFE56F6A" />
                <Setter TargetName="CloseButtonContent" Property="TextElement.Foreground" Value="#FFFFFFFF" />
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="CloseButtonBackground" Property="Background" Value="#FFD85C57" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Button.Template>
      </Button>
      </Grid>
      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel x:Name="DetailsBody" Margin="16,4,16,16" />
      </ScrollViewer>
    </Grid>
  </Border>
</Window>
'@
    $detailsReader = [System.Xml.XmlNodeReader]::new($detailsXaml)
    $script:detailsWindow = [Windows.Markup.XamlReader]::Load($detailsReader)
    $script:detailsWindow.Owner = $window
    $detailsClose = $script:detailsWindow.FindName('DetailsClose')
    $detailsHeader = $script:detailsWindow.FindName('DetailsHeader')
    $detailsClose.Add_Click({ $script:detailsWindow.Close() })
    $detailsHeader.Add_MouseLeftButtonDown({
        param($sender, $mouseEvent)
        if ($mouseEvent.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) {
            try { $script:detailsWindow.DragMove() } catch { }
        }
    })
    $script:detailsWindow.Add_Closed({ $script:detailsWindow = $null })
    Update-UsageDetails $script:lastUsageData
    Update-DetailsWindowPosition
    $script:detailsWindow.Show()
}

function Update-DetailsWindowPosition {
    if (-not $script:detailsWindow) { return }

    $overlayWidth = if ($window.ActualWidth -gt 0) { $window.ActualWidth } else { $window.Width }
    $overlayHeight = if ($window.ActualHeight -gt 0) { $window.ActualHeight } else { $window.Height }
    $detailWidth = $script:detailsWindow.Width
    $detailHeight = $script:detailsWindow.Height
    $targetLeft = $window.Left + (($overlayWidth - $detailWidth) / 2)
    $targetTop = $window.Top + $overlayHeight + 8

    $workArea = [CodexWindowFinder+RECT]::new()
    if ([CodexWindowFinder]::GetMonitorWorkArea($script:overlayHandle, [ref]$workArea)) {
        $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($window)
        $workLeft = $workArea.Left / $dpi.DpiScaleX
        $workTop = $workArea.Top / $dpi.DpiScaleY
        $workRight = $workArea.Right / $dpi.DpiScaleX
        $workBottom = $workArea.Bottom / $dpi.DpiScaleY
        $targetLeft = [Math]::Max($workLeft, [Math]::Min($targetLeft, $workRight - $detailWidth))
        $targetTop = [Math]::Max($workTop, [Math]::Min($targetTop, $workBottom - $detailHeight))
    }

    $script:detailsWindow.Left = $targetLeft
    $script:detailsWindow.Top = $targetTop
}

function Show-Usage([object]$data) {
    $script:lastUsageData = $data
    $codexBucket = $null
    if ($data.PSObject.Properties.Name -contains 'rateLimitsByLimitId' -and $data.rateLimitsByLimitId) {
        $codexProperty = $data.rateLimitsByLimitId.PSObject.Properties['codex']
        if ($codexProperty) { $codexBucket = $codexProperty.Value }
    }
    if (-not $codexBucket -and $data.PSObject.Properties.Name -contains 'rateLimits') {
        $codexBucket = $data.rateLimits
    }
    if (-not $codexBucket) {
        throw '当前账户没有返回 Codex 主额度。'
    }

    $candidateWindows = @()
    foreach ($windowName in @('primary', 'secondary')) {
        if ($codexBucket.PSObject.Properties.Name -contains $windowName -and $codexBucket.$windowName) {
            $candidateWindows += $codexBucket.$windowName
        }
    }
    if ($candidateWindows.Count -eq 0) {
        throw '当前账户没有返回可显示的限额窗口。'
    }

    # 多个窗口时显示剩余最少的一项，避免悬浮球给出过于乐观的数字。
    $limitWindow = $candidateWindows | Sort-Object -Property usedPercent -Descending | Select-Object -First 1
    $usedPercent = [Math]::Max(0, [Math]::Min(100, [double]$limitWindow.usedPercent))
    $remainingPercent = 100 - $usedPercent
    $progressFill.Width = if ($remainingPercent -le 0) { 0 } else { [Math]::Max(4, 2.2 * $remainingPercent) }
    $progressFill.Background = if ($remainingPercent -lt 20) {
        New-UiGradient '#FFF8B6B1' '#FFE47D76'
    }
    elseif ($remainingPercent -lt 50) {
        New-UiGradient '#FFFFD9A1' '#FFF0A84F'
    }
    else {
        New-UiGradient '#FFB7E6C4' '#FF6FC68A'
    }

    $periodLabel = Format-WindowLabel ([int]$limitWindow.windowDurationMins) 0
    $resetLabel = Format-ResetTime ([long]$limitWindow.resetsAt)
    $periodText.Text = $periodLabel
    $percentText.Text = ('{0:0}%' -f $remainingPercent)
    $percentText.Foreground = Get-UiBrush '#FF4F5357'
    $resetAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$limitWindow.resetsAt).ToLocalTime()
    $resetToolTipText.Text = if ($resetLabel) {
        "$resetLabel 重置 · $($resetAt.ToString('M月d日 HH:mm'))"
    }
    else { '重置时间未知' }
    Update-ResetCreditBadge $data
    $script:hasData = $true
    if ($script:detailsWindow -and $script:detailsWindow.IsVisible) {
        Update-UsageDetails $data
    }
}

function Show-UsageError([string]$message) {
    $periodText.Text = 'Codex'
    $percentText.Text = '!'
    $percentText.Foreground = Get-UiBrush '#FFFFFFFF'
    $progressFill.Width = 220
    $progressFill.Background = New-UiGradient '#FFF8B6B1' '#FFE47D76'
    $resetToolTipText.Text = "$message · 右键可立即刷新"
}

function Start-UsageWatcher {
    if ($script:usageJob -and $script:usageJob.State -in @('NotStarted', 'Running')) { return }
    if ([DateTime]::Now -lt $script:nextWatcherRestart) { return }
    if ($script:usageJob) {
        Remove-Job -Job $script:usageJob -Force -ErrorAction SilentlyContinue
    }
    if (-not $script:hasData) { $percentText.Text = '…' }
    $script:usageJob = Start-ThreadJob -ScriptBlock {
        param($scriptPath, $commandQueue, $fallbackSeconds)
        & $scriptPath -CommandQueue $commandQueue -FallbackSeconds $fallbackSeconds
    } -ArgumentList $watcherScript, $script:usageCommands, $RefreshSeconds
}

function Request-UsageRefresh {
    Start-UsageWatcher
    $script:usageCommands.Enqueue('refresh')
}

function Receive-UsageEvents {
    if (-not $script:usageJob) {
        Start-UsageWatcher
        return
    }

    try {
        $eventLines = @(Receive-Job -Job $script:usageJob -ErrorAction Stop)
        foreach ($eventLine in $eventLines) {
            if (-not $eventLine) { continue }
            $usageEvent = ([string]$eventLine).Trim() | ConvertFrom-Json -Depth 24
            if ($usageEvent.kind -eq 'usage') {
                Show-Usage $usageEvent.data
            }
            elseif ($usageEvent.kind -eq 'error') {
                $message = [string]$usageEvent.message
                if ($message.Length -gt 180) { $message = $message.Substring(0, 177) + '…' }
                if ($script:hasData) {
                    $resetToolTipText.Text = "$message · 正在自动重连"
                }
                else {
                    Show-UsageError $message
                }
            }
        }
    }
    catch {
        $message = $_.Exception.Message
        if ($message.Length -gt 180) { $message = $message.Substring(0, 177) + '…' }
        if (-not $script:hasData) { Show-UsageError $message }
    }

    if ($script:usageJob.State -notin @('NotStarted', 'Running')) {
        Remove-Job -Job $script:usageJob -Force -ErrorAction SilentlyContinue
        $script:usageJob = $null
        $script:nextWatcherRestart = [DateTime]::Now.AddSeconds(3)
    }
}

$script:lastOverlayLeft = [double]::NaN
$script:lastOverlayTop = [double]::NaN

function Update-OverlayVisibility {
    $positionChanged = $false
    $codexWindow = [CodexWindowFinder]::FindLargestVisibleWindow()
    $shouldShow = $codexWindow -ne [IntPtr]::Zero
    if ($shouldShow) {
        $rect = [CodexWindowFinder+RECT]::new()
        if ([CodexWindowFinder]::GetVisibleWindowRect($codexWindow, [ref]$rect)) {
            $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($window)
            # Codex 原生顶部栏高度为 36 DIP；状态条按自身高度做水平、垂直几何居中。
            $titleBarHeight = 36
            $targetLeft = (($rect.Left + $rect.Right) / 2 / $dpi.DpiScaleX) - ($window.Width / 2)
            $targetTop = ($rect.Top / $dpi.DpiScaleY) + (($titleBarHeight - $window.Height) / 2)
            if ([double]::IsNaN($script:lastOverlayLeft) -or
                [Math]::Abs($targetLeft - $script:lastOverlayLeft) -gt 0.1 -or
                [Math]::Abs($targetTop - $script:lastOverlayTop) -gt 0.1) {
                $window.Left = $targetLeft
                $window.Top = $targetTop
                $script:lastOverlayLeft = $targetLeft
                $script:lastOverlayTop = $targetTop
                $positionChanged = $true
            }
        }
        if (-not $window.IsVisible) {
            $window.Show()
            $positionChanged = $true
        }
        if ($positionChanged -and $script:detailsWindow -and $script:detailsWindow.IsVisible) {
            Update-DetailsWindowPosition
        }
        # 非置顶窗口始终紧邻 Codex 上方；其他应用进入前台后会自然覆盖两者。
        [CodexWindowFinder]::PlaceWindowAbove($script:overlayHandle, $codexWindow) | Out-Null
    }
    elseif ($window.IsVisible) {
        $window.Hide()
        $positionChanged = $true
    }
    return $positionChanged
}

[xml]$contextMenuXaml = @'
<ContextMenu xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
             Width="184" Background="Transparent" HasDropShadow="False"
             FontFamily="Microsoft YaHei UI" FontSize="12">
  <ContextMenu.Resources>
    <Style TargetType="{x:Type ContextMenu}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ContextMenu}">
            <Border Background="#FAF7F7F7" BorderBrush="#FFE1E1E1" BorderThickness="1"
                    CornerRadius="12" Padding="6" SnapsToDevicePixels="True">
              <Border.Effect>
                <DropShadowEffect Color="#000000" BlurRadius="14" ShadowDepth="3" Opacity="0.34" />
              </Border.Effect>
              <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Cycle" />
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="{x:Type MenuItem}">
      <Setter Property="Foreground" Value="#FF202124" />
      <Setter Property="Background" Value="Transparent" />
      <Setter Property="Padding" Value="11,8" />
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type MenuItem}">
            <Border x:Name="ItemBorder" Background="{TemplateBinding Background}"
                    CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter ContentSource="Header" VerticalAlignment="Center" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="ItemBorder" Property="Background" Value="#FFE9E9E9" />
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="ItemBorder" Property="Background" Value="#FFDCDCDC" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="{x:Type Separator}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Separator}">
            <Border Height="1" Background="#FFE0E0E0" Margin="10,5" />
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </ContextMenu.Resources>
  <MenuItem x:Name="RefreshItem">
    <MenuItem.Header>
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="↻" Width="28" FontSize="17" TextAlignment="Center" VerticalAlignment="Center" />
        <TextBlock Text="刷新用量" VerticalAlignment="Center" />
      </StackPanel>
    </MenuItem.Header>
  </MenuItem>
  <MenuItem x:Name="UsageDetailsItem">
    <MenuItem.Header>
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="▤" Width="28" FontSize="14" TextAlignment="Center" VerticalAlignment="Center" />
        <TextBlock Text="查看用量详情" VerticalAlignment="Center" />
      </StackPanel>
    </MenuItem.Header>
  </MenuItem>
  <Separator />
  <MenuItem x:Name="ExitItem" Foreground="#FFF28B82">
    <MenuItem.Header>
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="×" Width="28" FontSize="17" TextAlignment="Center" VerticalAlignment="Center" />
        <TextBlock Text="退出" VerticalAlignment="Center" />
      </StackPanel>
    </MenuItem.Header>
  </MenuItem>
</ContextMenu>
'@
$contextMenuReader = [System.Xml.XmlNodeReader]::new($contextMenuXaml)
$contextMenu = [Windows.Markup.XamlReader]::Load($contextMenuReader)
$refreshItem = $contextMenu.FindName('RefreshItem')
$usagePageItem = $contextMenu.FindName('UsageDetailsItem')
$exitItem = $contextMenu.FindName('ExitItem')
$refreshItem.Add_Click({ Request-UsageRefresh })
$usagePageItem.Add_Click({ Show-UsageDetails })
$script:userRequestedExit = $false
$exitItem.Add_Click({
    $script:userRequestedExit = $true
    $window.Close()
})
$window.ContextMenu = $contextMenu
$window.Add_MouseDoubleClick({
    param($sender, $eventArgs)
    if ($eventArgs.ChangedButton -eq [Windows.Input.MouseButton]::Left) {
        Show-UsageDetails
        $eventArgs.Handled = $true
    }
})

$usageTimer = [Windows.Threading.DispatcherTimer]::new()
$usageTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$usageTimer.Add_Tick({
    Receive-UsageEvents
})

$positionIdleInterval = [TimeSpan]::FromMilliseconds(120)
$positionFastInterval = [TimeSpan]::FromMilliseconds(16)
$positionSettleTime = [TimeSpan]::FromMilliseconds(300)
$script:isFastPositionTracking = $false
$script:lastPositionChangeAt = [DateTime]::UtcNow
$positionTimer = [Windows.Threading.DispatcherTimer]::new()
$positionTimer.Interval = $positionIdleInterval
$positionTimer.Add_Tick({
    $positionChanged = [bool](Update-OverlayVisibility)
    $now = [DateTime]::UtcNow
    if ($positionChanged) {
        $script:lastPositionChangeAt = $now
        if (-not $script:isFastPositionTracking) {
            $script:isFastPositionTracking = $true
            $positionTimer.Interval = $positionFastInterval
        }
    }
    elseif ($script:isFastPositionTracking -and
        ($now - $script:lastPositionChangeAt) -ge $positionSettleTime) {
        $script:isFastPositionTracking = $false
        $positionTimer.Interval = $positionIdleInterval
    }
})

$window.Add_Closed({
    $usageTimer.Stop()
    $positionTimer.Stop()
    if ($script:usageJob) {
        $script:usageCommands.Enqueue('stop')
        Stop-Job -Job $script:usageJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:usageJob -Force -ErrorAction SilentlyContinue
    }
    try { $script:singleInstanceMutex.ReleaseMutex() } catch {}
    $script:singleInstanceMutex.Dispose()
    if ($script:userRequestedExit -and $StopMarkerPath) {
        try {
            $markerDirectory = Split-Path -Parent $StopMarkerPath
            if (-not (Test-Path -LiteralPath $markerDirectory)) {
                New-Item -ItemType Directory -Path $markerDirectory -Force | Out-Null
            }
            $bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks
            $sessionKey = '{0}|{1}' -f ([Diagnostics.Process]::GetCurrentProcess().SessionId), $bootTime
            Set-Content -LiteralPath $StopMarkerPath -Value $sessionKey -Encoding UTF8
        }
        catch { }
    }
})

Start-UsageWatcher
$usageTimer.Start()
$positionTimer.Start()
$null = Update-OverlayVisibility
[Windows.Threading.Dispatcher]::Run()
