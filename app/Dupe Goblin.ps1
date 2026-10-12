# Dupe Goblin v1.0.18
# Read-only duplicate file scanner for Windows.
# It never deletes, moves, renames, or modifies scanned files.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'SilentlyContinue'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$script:CancelRequested = $false
$script:IsScanning = $false
$script:LastReportPath = $null
$script:SourceUi = @{}
$script:SkippedFolders = 0
$script:SkippedFiles = 0
$script:IgnoreHidden = $false

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return "$Bytes bytes"
}

function Format-Eta([double]$Seconds) {
    if ([double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds) -or $Seconds -lt 0) { return 'Estimating...' }
    $Seconds = [math]::Ceiling($Seconds)
    if ($Seconds -lt 60) { return ('~{0}s' -f $Seconds) }
    if ($Seconds -lt 3600) {
        $m = [math]::Floor($Seconds / 60)
        $s = $Seconds % 60
        return ('~{0}m {1}s' -f $m, $s)
    }
    $h = [math]::Floor($Seconds / 3600)
    $m = [math]::Floor(($Seconds % 3600) / 60)
    return ('~{0}h {1}m' -f $h, $m)
}

# Keeps the WPF window responsive while the scan runs on the UI thread.
$script:DispatcherCallback = [System.Windows.Threading.DispatcherOperationCallback]{
    param($Frame)
    $Frame.Continue = $false
    return $null
}

function Do-Events {
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        $script:DispatcherCallback,
        $frame
    ) | Out-Null
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Get-SafeFiles {
    param([Parameter(Mandatory=$true)][string]$Root)

    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)

    while ($stack.Count -gt 0) {
        if ($script:CancelRequested) { return }
        $dir = $stack.Pop()

        try {
            foreach ($filePath in [System.IO.Directory]::EnumerateFiles($dir)) {
                if ($script:CancelRequested) { return }
                try {
                    $fi = [System.IO.FileInfo]::new($filePath)
                    if ($fi.Exists) {
                        if ($script:IgnoreHidden -and (($fi.Attributes -band [System.IO.FileAttributes]::Hidden) -ne 0)) {
                            continue
                        }
                        $fi
                    }
                } catch {
                    $script:SkippedFiles++
                }
            }
        } catch {
            $script:SkippedFolders++
        }

        try {
            foreach ($subDir in [System.IO.Directory]::EnumerateDirectories($dir)) {
                if ($script:CancelRequested) { return }
                try {
                    $attrs = [System.IO.File]::GetAttributes($subDir)
                    # Skip junctions/symlinks so the scanner cannot loop forever.
                    if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        continue
                    }
                    # Optional: skip folders marked Hidden, including everything inside them.
                    if ($script:IgnoreHidden -and (($attrs -band [System.IO.FileAttributes]::Hidden) -ne 0)) {
                        continue
                    }
                    $stack.Push($subDir)
                } catch {
                    $script:SkippedFolders++
                }
            }
        } catch {
            $script:SkippedFolders++
        }
    }
}

function Get-ExactHash {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][long]$FileLength,
        [Parameter(Mandatory=$true)][scriptblock]$ProgressCallback
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        # A larger sequential buffer cuts PowerShell/.NET call overhead on big media files.
        $bufferSize = 16777216  # 16 MiB
        $stream = New-Object System.IO.FileStream -ArgumentList @(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite,
            $bufferSize,
            [System.IO.FileOptions]::SequentialScan
        )
        $buffer = New-Object byte[] $bufferSize
        [long]$done = 0
        $uiTimer = [System.Diagnostics.Stopwatch]::StartNew()

        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($script:CancelRequested) { throw (New-Object System.OperationCanceledException) }

            # HashAlgorithm permits a null output buffer; this avoids copying each block
            # back into the same 16 MiB array after it has already been hashed.
            [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
            $done += $read

            # WPF refreshes are expensive. ~6 refreshes/sec still looks smooth while
            # avoiding thousands of dispatcher passes for large files.
            if ($uiTimer.ElapsedMilliseconds -ge 160 -or $done -ge $FileLength) {
                & $ProgressCallback $done $FileLength
                Do-Events
                $uiTimer.Restart()
            }
        }

        $empty = New-Object byte[] 0
        [void]$sha.TransformFinalBlock($empty, 0, 0)

        # Make sure tiny files also advance the UI at least once.
        if ($done -eq 0 -or $uiTimer.ElapsedMilliseconds -lt 160) {
            & $ProgressCallback $done $FileLength
            Do-Events
        }

        return ([System.BitConverter]::ToString($sha.Hash)).Replace('-', '')
    }
    finally {
        if ($stream) { $stream.Dispose() }
        if ($sha) { $sha.Dispose() }
    }
}

function Normalize-Path([string]$Path) {
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $Path
    }
    if ($full.Length -gt 3) { return $full.TrimEnd('\') }
    return $full
}

function Remove-OverlappingSources {
    param([string[]]$Sources)

    $accepted = New-Object 'System.Collections.Generic.List[string]'
    $normalized = @($Sources | ForEach-Object { Normalize-Path $_ } | Sort-Object @{Expression={$_.Length}}, @{Expression={$_}} -Unique)

    foreach ($candidate in $normalized) {
        $covered = $false
        foreach ($parent in $accepted) {
            $prefix = if ($parent.EndsWith('\')) { $parent } else { $parent + '\' }
            if ($candidate.Equals($parent, [System.StringComparison]::OrdinalIgnoreCase) -or
                $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $covered = $true
                break
            }
        }
        if (-not $covered) { $accepted.Add($candidate) }
    }
    return $accepted.ToArray()
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Dupe Goblin"
        Width="1180" Height="820"
        MinWidth="320" MinHeight="240"
        WindowStartupLocation="CenterScreen"
        Background="#111318"
        Foreground="#F2F4F8" FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True">
    <Window.Resources>
        <SolidColorBrush x:Key="BgBrush" Color="#111318"/>
        <SolidColorBrush x:Key="PanelBrush" Color="#1A1E24"/>
        <SolidColorBrush x:Key="Panel2Brush" Color="#222831"/>
        <SolidColorBrush x:Key="TextBrush" Color="#F2F4F8"/>
        <SolidColorBrush x:Key="MutedBrush" Color="#A9B1BC"/>
        <SolidColorBrush x:Key="AccentBrush" Color="#9DDA32"/>
        <SolidColorBrush x:Key="BorderBrush" Color="#343B46"/>

        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="Margin" Value="0,3,14,3"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="Background" Value="#252D38"/>
            <Setter Property="BorderBrush" Value="#3C4856"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,7"/>
            <Setter Property="Margin" Value="0,0,8,8"/>
            <Setter Property="MinHeight" Value="34"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Chrome" Property="BorderBrush" Value="#B2ED57"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="Chrome" Property="BorderBrush" Value="#B2ED57"/>
                                <Setter TargetName="Chrome" Property="BorderThickness" Value="2"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Chrome" Property="Opacity" Value="0.75"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Chrome" Property="Opacity" Value="0.4"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="GroupBox">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="Margin" Value="0,0,0,12"/>
            <Setter Property="Padding" Value="12"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="GroupBox">
                        <Border Background="#1A2029" BorderBrush="#303B48" BorderThickness="1" CornerRadius="12" Padding="{TemplateBinding Padding}">
                            <Grid>
                                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                                <DockPanel Margin="0,0,0,10">
                                    <Border Width="3" Background="#9DDA32" CornerRadius="1" Margin="0,0,10,0"/>
                                    <ContentPresenter ContentSource="Header" TextElement.FontSize="15" TextElement.FontWeight="SemiBold"/>
                                </DockPanel>
                                <ContentPresenter Grid.Row="1"/>
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ListBoxItem">
            <Setter Property="Padding" Value="10,7"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#344626"/>
                    <Setter Property="Foreground" Value="#F2F4F8"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="ContextMenu">
            <Setter Property="Background" Value="#252D38"/>
            <Setter Property="Foreground" Value="#F2F4F8"/>
            <Setter Property="BorderBrush" Value="#3C4856"/>
        </Style>
        <Style TargetType="ListBox">
            <Setter Property="Background" Value="#14181E"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
        </Style>
        <Style TargetType="ProgressBar">
            <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Background" Value="#303741"/>
            <Setter Property="Height" Value="12"/>
        </Style>
        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="#14181E"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="RowHeight" Value="36"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="RowBackground" Value="#171B21"/>
            <Setter Property="AlternatingRowBackground" Value="#1D222A"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#2D343E"/>
            <Setter Property="VerticalGridLinesBrush" Value="#2D343E"/>
        </Style>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#2B323D"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="#46505E"/>
            <Setter Property="Padding" Value="10,12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style TargetType="DataGridCell">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="#2D343E"/>
            <Setter Property="Padding" Value="10,7"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#344626"/>
                    <Setter Property="BorderBrush" Value="#739C35"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

<Grid x:Name="DashboardViewport">
<Viewbox Stretch="Uniform" StretchDirection="DownOnly" HorizontalAlignment="Center" VerticalAlignment="Center">
<Grid x:Name="MainScrollViewer" Width="1000" Height="720" Margin="0">
<Grid Margin="12"><Grid.RowDefinitions><RowDefinition Height="232"/><RowDefinition Height="172"/><RowDefinition Height="*"/></Grid.RowDefinitions>
<Grid Grid.Row="0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<Grid Margin="0,0,6,12"><Grid.RowDefinitions><RowDefinition Height="82"/><RowDefinition Height="*"/></Grid.RowDefinitions>
<Border Grid.Row="0" Background="#202C23" BorderBrush="#4D6535" BorderThickness="1" CornerRadius="12" Padding="10" Margin="0,0,0,8">
<Grid><Grid.ColumnDefinitions><ColumnDefinition Width="70"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<Image x:Name="HeaderImage" Width="60" Height="56" Stretch="Uniform" RenderOptions.BitmapScalingMode="Fant"/>
<StackPanel Grid.Column="1" VerticalAlignment="Center">
<Image x:Name="WordmarkImage" Height="42" MaxWidth="300" Stretch="Uniform" HorizontalAlignment="Left" RenderOptions.BitmapScalingMode="Fant"/>
<TextBlock Text="READ-ONLY / SHA-256 VERIFIED" FontSize="10" Foreground="#B6DA81"/>
</StackPanel></Grid></Border><Border Grid.Row="1" Background="#181D23" BorderBrush="#343B46" BorderThickness="1" CornerRadius="12" Padding="10">
<Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
<DockPanel Margin="0,0,0,5"><TextBlock Text="Scan options" FontWeight="SemiBold" FontSize="14" Margin="0,0,16,0"/><CheckBox x:Name="IgnoreHiddenCheckBox" Content="Ignore hidden files and folders" ToolTip="Skip Windows Hidden files and folders, including their contents." IsChecked="False"/></DockPanel>
<WrapPanel Grid.Row="1"><Button x:Name="ScanButton" Content="Scan for duplicates" Background="#9DDA32" Foreground="#17210D" BorderBrush="#B2ED57" FontWeight="Bold"/><Button x:Name="CancelButton" Content="Cancel scan" IsEnabled="False"/></WrapPanel>
<TextBlock Grid.Row="2" x:Name="StatusText" Text="Choose at least one drive or folder." TextWrapping="Wrap" TextTrimming="CharacterEllipsis" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}" Foreground="#C5CBD4"/>
</Grid></Border></Grid><GroupBox x:Name="ProgressGroup" Grid.Column="1" Margin="6,0,0,12" Header="Scan progress" Visibility="Visible">
                <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><StackPanel>
                    <Grid Margin="0,0,0,5">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="TOTAL" FontWeight="Bold" />
                        <TextBlock x:Name="TotalProgressText" Grid.Column="1" Text="0%" Foreground="#9DDA32" FontWeight="Bold" />
                    </Grid>
                    <ProgressBar x:Name="TotalProgressBar" Minimum="0" Maximum="100" Value="0" Height="12" />
                    <TextBlock x:Name="TotalEtaText" Text="Ready when you are." Foreground="#A9B1BC" Margin="0,5,0,4" />
                    <TextBlock x:Name="PhaseNoteText" Text="" MaxHeight="40" TextTrimming="CharacterEllipsis" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}" Foreground="#D6B45E" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,4" Visibility="Collapsed" />
                    </StackPanel><ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><StackPanel x:Name="SourceProgressPanel" /></ScrollViewer>
                </Grid>
            </GroupBox>

            </Grid>
<Grid Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<GroupBox Grid.Row="0" Header="01 / Choose drives" Margin="0,0,6,12">
                <Grid>
<Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /></Grid.RowDefinitions>
                    <WrapPanel Margin="0">
                        <Button x:Name="SelectAllButton" Content="Select all drives" />
                        <Button x:Name="ClearDrivesButton" Content="Clear drives" />
                    </WrapPanel>
                    <Border Grid.Row="1" Background="#14181E" BorderBrush="#343B46" BorderThickness="1" CornerRadius="6" Padding="8">
                        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><StackPanel x:Name="DriveList" /></ScrollViewer>
                    </Border>
                </Grid>
            </GroupBox>

            <GroupBox Grid.Row="0" Grid.Column="1" Margin="6,0,0,12" Header="02 / Add folders">
                <Grid>
<Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /></Grid.RowDefinitions>
<WrapPanel><Button x:Name="AddFolderButton" Content="Add folders..." /><Button x:Name="RemoveFolderButton" Content="Remove" ToolTip="Remove selected folders from the scan sources" /><Button x:Name="ClearFoldersButton" Content="Clear" ToolTip="Clear all added folders" /></WrapPanel>
<ListBox Grid.Row="1" x:Name="CustomFolderList" MinHeight="32" SelectionMode="Extended" HorizontalContentAlignment="Stretch" ScrollViewer.HorizontalScrollBarVisibility="Auto" />
</Grid>
            </GroupBox>

            </Grid><GroupBox Grid.Row="2" Margin="0" Header="Duplicate files">
                <Grid><Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                    <TextBlock x:Name="ResultsSummary" Text="Duplicate groups will appear here after a scan." Foreground="#A9B1BC" Margin="0,0,0,8" TextWrapping="Wrap" />
                    <DataGrid x:Name="ResultsGrid" Grid.Row="1" MinHeight="80" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" SelectionMode="Single" AlternatingRowBackground="#1D222A" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto" ToolTip="Double-click a duplicate to open its folder and select the file.">
                        <DataGrid.ContextMenu>
                            <ContextMenu>
                                <MenuItem x:Name="OpenSelectedContextMenu" Header="Open file location" />
                            </ContextMenu>
                        </DataGrid.ContextMenu>
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Group" Binding="{Binding Group}" Width="70" />
                            <DataGridTextColumn Header="Size" Binding="{Binding Size}" Width="100" />
                            <DataGridTextColumn Header="File location" Binding="{Binding Path}" Width="*" MinWidth="120" />
                        </DataGrid.Columns>
                    </DataGrid>
                    <WrapPanel Grid.Row="2" Margin="0,10,0,0">
                        <Button x:Name="OpenReportButton" Content="Open text report" IsEnabled="False" />
                        <Button x:Name="OpenSelectedButton" Content="Open selected file location" IsEnabled="False" />
                    </WrapPanel>
                </Grid>
            </GroupBox>
        

</Grid></Grid></Viewbox></Grid></Window>
'@

[xml]$xamlXml = $xaml
$reader = New-Object System.Xml.XmlNodeReader $xamlXml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Controls
$DriveList = $window.FindName('DriveList')
$MainScrollViewer = $window.FindName('MainScrollViewer')
$SelectAllButton = $window.FindName('SelectAllButton')
$ClearDrivesButton = $window.FindName('ClearDrivesButton')
$AddFolderButton = $window.FindName('AddFolderButton')
$RemoveFolderButton = $window.FindName('RemoveFolderButton')
$ClearFoldersButton = $window.FindName('ClearFoldersButton')
$CustomFolderList = $window.FindName('CustomFolderList')
$ScanButton = $window.FindName('ScanButton')
$CancelButton = $window.FindName('CancelButton')
$StatusText = $window.FindName('StatusText')
$IgnoreHiddenCheckBox = $window.FindName('IgnoreHiddenCheckBox')
$ProgressGroup = $window.FindName('ProgressGroup')
$TotalProgressBar = $window.FindName('TotalProgressBar')
$TotalProgressText = $window.FindName('TotalProgressText')
$TotalEtaText = $window.FindName('TotalEtaText')
$PhaseNoteText = $window.FindName('PhaseNoteText')
$SourceProgressPanel = $window.FindName('SourceProgressPanel')
$ResultsGrid = $window.FindName('ResultsGrid')
$ResultsSummary = $window.FindName('ResultsSummary')
$OpenReportButton = $window.FindName('OpenReportButton')
$OpenSelectedButton = $window.FindName('OpenSelectedButton')
$OpenSelectedContextMenu = $window.FindName('OpenSelectedContextMenu')
$HeaderImage = $window.FindName('HeaderImage')
$WordmarkImage = $window.FindName('WordmarkImage')

# Branding image + window icon
try {
    $mascotPath = Join-Path $PSScriptRoot 'Dupe Goblin Mascot.png'
    if (Test-Path -LiteralPath $mascotPath) {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
        $bitmap.UriSource = New-Object System.Uri -ArgumentList $mascotPath
        $bitmap.EndInit()
        $bitmap.Freeze()
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($HeaderImage, [System.Windows.Media.BitmapScalingMode]::Fant)
        $HeaderImage.Source = $bitmap
    }

    $wordmarkPath = Join-Path $PSScriptRoot 'Dupe Goblin Wordmark.png'
    if (Test-Path -LiteralPath $wordmarkPath) {
        $wordmarkBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $wordmarkBitmap.BeginInit()
        $wordmarkBitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $wordmarkBitmap.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
        $wordmarkBitmap.UriSource = New-Object System.Uri -ArgumentList $wordmarkPath
        $wordmarkBitmap.EndInit()
        $wordmarkBitmap.Freeze()
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($WordmarkImage, [System.Windows.Media.BitmapScalingMode]::Fant)
        $WordmarkImage.Source = $wordmarkBitmap
    }
    $icoPath = Join-Path $PSScriptRoot 'Dupe Goblin.ico'
    if (Test-Path -LiteralPath $icoPath) {
        $iconUri = New-Object System.Uri -ArgumentList $icoPath
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($iconUri)
    }
} catch {}

# Populate currently available Windows drives.
$script:DriveCheckboxes = New-Object 'System.Collections.Generic.List[object]'
foreach ($drive in [System.IO.DriveInfo]::GetDrives() | Sort-Object Name) {
    if (-not $drive.IsReady) { continue }
    $size = Format-Size $drive.TotalSize
    $label = if ([string]::IsNullOrWhiteSpace($drive.VolumeLabel)) { 'No label' } else { $drive.VolumeLabel }
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Tag = $drive.RootDirectory.FullName
    $cb.HorizontalAlignment = 'Stretch'
    $cb.Margin = '0,4,0,4'

    $driveText = New-Object System.Windows.Controls.TextBlock
    $driveText.Text = ('{0}  {1}  ({2})' -f $drive.Name, $label, $size)
    $driveText.TextWrapping = 'Wrap'
    $driveText.Margin = '4,0,0,0'
    $cb.Content = $driveText

    $cb.ToolTip = ('{0} | {1} | Free {2}' -f $drive.DriveType, $label, (Format-Size $drive.AvailableFreeSpace))
    [void]$DriveList.Children.Add($cb)
    [void]$script:DriveCheckboxes.Add($cb)
}

if ($script:DriveCheckboxes.Count -eq 0) {
    $none = New-Object System.Windows.Controls.TextBlock
    $none.Text = 'No ready drives were found.'
    $none.Foreground = '#A9B1BC'
    [void]$DriveList.Children.Add($none)
}

function Set-InputsEnabled([bool]$Enabled) {
    foreach ($cb in $script:DriveCheckboxes) { $cb.IsEnabled = $Enabled }
    $SelectAllButton.IsEnabled = $Enabled
    $ClearDrivesButton.IsEnabled = $Enabled
    $AddFolderButton.IsEnabled = $Enabled
    $RemoveFolderButton.IsEnabled = $Enabled
    $ClearFoldersButton.IsEnabled = $Enabled
    $CustomFolderList.IsEnabled = $Enabled
    $IgnoreHiddenCheckBox.IsEnabled = $Enabled
    $ScanButton.IsEnabled = $Enabled
    $CancelButton.IsEnabled = -not $Enabled
}

function Get-SelectedSources {
    $raw = New-Object 'System.Collections.Generic.List[string]'
    foreach ($cb in $script:DriveCheckboxes) {
        if ($cb.IsChecked -eq $true) { [void]$raw.Add([string]$cb.Tag) }
    }
    foreach ($item in $CustomFolderList.Items) {
        [void]$raw.Add([string]$item)
    }
    return @(Remove-OverlappingSources -Sources $raw.ToArray())
}

function Clear-ProgressRows {
    $SourceProgressPanel.Children.Clear()
    $script:SourceUi = @{}
}

function Add-ProgressRow([string]$Source) {
    $border = New-Object System.Windows.Controls.Border
    $border.Background = '#222831'
    $border.BorderBrush = '#343B46'
    $border.BorderThickness = 1
    $border.CornerRadius = 7
    $border.Padding = 9
    $border.Margin = '0,0,0,7'

    $stack = New-Object System.Windows.Controls.StackPanel
    $top = New-Object System.Windows.Controls.DockPanel

    $info = New-Object System.Windows.Controls.TextBlock
    $info.Text = 'Preparing...'
    $info.Foreground = '#9DDA32'
    $info.FontWeight = 'Bold'
    [System.Windows.Controls.DockPanel]::SetDock($info, 'Right')

    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = $Source
    $name.TextTrimming = 'CharacterEllipsis'
    $name.ToolTip = $Source
    $name.Margin = '0,0,12,0'

    [void]$top.Children.Add($info)
    [void]$top.Children.Add($name)

    $bar = New-Object System.Windows.Controls.ProgressBar
    $bar.Minimum = 0
    $bar.Maximum = 100
    $bar.Value = 0
    $bar.Height = 17
    $bar.Margin = '0,6,0,0'
    $bar.Foreground = '#9DDA32'
    $bar.Background = '#303741'

    [void]$stack.Children.Add($top)
    [void]$stack.Children.Add($bar)
    $border.Child = $stack
    [void]$SourceProgressPanel.Children.Add($border)

    $script:SourceUi[$Source] = @{ Bar = $bar; Info = $info; Border = $border }
}

function Set-SourceProgress([string]$Source, [double]$Percent, [string]$Text, [bool]$Indeterminate=$false) {
    if (-not $script:SourceUi.ContainsKey($Source)) { return }
    $ui = $script:SourceUi[$Source]
    $ui.Bar.IsIndeterminate = $Indeterminate
    if (-not $Indeterminate) { $ui.Bar.Value = [math]::Max(0, [math]::Min(100, $Percent)) }
    $ui.Info.Text = $Text
}

function Set-TotalProgress([double]$Percent, [string]$EtaText) {
    $Percent = [math]::Max(0, [math]::Min(100, $Percent))
    $TotalProgressBar.Value = $Percent
    $TotalProgressText.Text = ('{0:N1}%' -f $Percent)
    $TotalEtaText.Text = $EtaText
}

function Reset-Results {
    $ResultsGrid.ItemsSource = $null
    $ResultsSummary.Text = 'Scanning...'
    $OpenReportButton.IsEnabled = $false
    $OpenSelectedButton.IsEnabled = $false
    $script:LastReportPath = $null
}

$SelectAllButton.Add_Click({ foreach ($cb in $script:DriveCheckboxes) { $cb.IsChecked = $true } })
$ClearDrivesButton.Add_Click({ foreach ($cb in $script:DriveCheckboxes) { $cb.IsChecked = $false } })

$AddFolderButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose a folder for Dupe Goblin to scan'
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $p = Normalize-Path $dialog.SelectedPath
        $exists = $false
        foreach ($item in $CustomFolderList.Items) {
            if ([string]$item -ieq $p) { $exists = $true; break }
        }
        if (-not $exists) { [void]$CustomFolderList.Items.Add($p) }
    }
})

$RemoveFolderButton.Add_Click({
    $toRemove = @($CustomFolderList.SelectedItems)
    foreach ($item in $toRemove) { [void]$CustomFolderList.Items.Remove($item) }
})

$ClearFoldersButton.Add_Click({ $CustomFolderList.Items.Clear() })

$CancelButton.Add_Click({
    $script:CancelRequested = $true
    $CancelButton.IsEnabled = $false
    $StatusText.Text = 'Cancelling safely...'
})

$ResultsGrid.Add_SelectionChanged({
    $OpenSelectedButton.IsEnabled = ($ResultsGrid.SelectedItem -ne $null)
})

$OpenReportButton.Add_Click({
    if ($script:LastReportPath -and (Test-Path -LiteralPath $script:LastReportPath)) {
        Start-Process notepad.exe -ArgumentList ('"' + $script:LastReportPath + '"')
    }
})

function Open-SelectedDuplicateLocation {
    $item = $ResultsGrid.SelectedItem
    if (-not $item -or -not $item.Path) { return }

    $selectedPath = [string]$item.Path
    if (Test-Path -LiteralPath $selectedPath) {
        # Open Explorer to the containing folder and highlight the exact duplicate file.
        Start-Process explorer.exe -ArgumentList ('/select,"' + $selectedPath + '"')
    } else {
        [System.Windows.MessageBox]::Show(
            "That file no longer exists at the scanned location.`r`n`r`n$selectedPath",
            'Dupe Goblin',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
    }
}

$OpenSelectedButton.Add_Click({ Open-SelectedDuplicateLocation })
$OpenSelectedContextMenu.Add_Click({ Open-SelectedDuplicateLocation })
$ResultsGrid.Add_MouseDoubleClick({
    if ($ResultsGrid.SelectedItem -ne $null) { Open-SelectedDuplicateLocation }
})

$ScanButton.Add_Click({
    if ($script:IsScanning) { return }

    $sources = @(Get-SelectedSources)
    if ($sources.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            'Select at least one drive or add a folder first.',
            'Dupe Goblin',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
        return
    }

    $script:IsScanning = $true
    $script:CancelRequested = $false
    $script:SkippedFolders = 0
    $script:SkippedFiles = 0
    $script:IgnoreHidden = ($IgnoreHiddenCheckBox.IsChecked -eq $true)
    Set-InputsEnabled $false
    Reset-Results
    Clear-ProgressRows
    $ProgressGroup.Visibility = 'Visible'
    $PhaseNoteText.Text = ''
    $PhaseNoteText.Visibility = 'Collapsed'
    Set-TotalProgress 0 'ETA: Estimating...'
    foreach ($source in $sources) { Add-ProgressRow $source }
    Do-Events

    try {
        # ----------------------------------------------------------
        # Stage 1: ONE-PASS indexing. 0% -> 45%.
        #
        # Older builds walked every source twice: once to count files,
        # then again to index them. This pass builds size buckets the first
        # time we see each file, cutting the directory-enumeration work
        # roughly in half. Since the total count is not known in advance,
        # active source bars are honestly indeterminate during this stage.
        # ----------------------------------------------------------
        $StatusText.Text = 'Indexing files in one pass...'
        $sizeBuckets = @{}
        [long]$totalFileCount = 0
        $indexWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $sourceNumber = 0

        # Total count is unknowable until the one-pass index finishes.
        $TotalProgressBar.IsIndeterminate = $true
        $TotalProgressText.Text = 'Indexing'
        $TotalEtaText.Text = 'Discovering files...'
        Do-Events

        foreach ($source in $sources) {
            if ($script:CancelRequested) { throw (New-Object System.OperationCanceledException) }
            $sourceNumber++
            [long]$sourceDone = 0
            $sourceWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $uiWatch = [System.Diagnostics.Stopwatch]::StartNew()

            Set-SourceProgress $source 0 'Indexing...' $true
            $StatusText.Text = ('Indexing {0} ({1} of {2})...' -f $source, $sourceNumber, $sources.Count)
            Do-Events

            foreach ($fi in Get-SafeFiles -Root $source) {
                if ($script:CancelRequested) { throw (New-Object System.OperationCanceledException) }
                $sourceDone++
                $totalFileCount++

                $record = [pscustomobject]@{
                    Path = $fi.FullName
                    Size = [long]$fi.Length
                    Source = $source
                }

                $sizeKey = ([long]$fi.Length).ToString([System.Globalization.CultureInfo]::InvariantCulture)
                if (-not $sizeBuckets.ContainsKey($sizeKey)) {
                    $sizeBuckets[$sizeKey] = New-Object 'System.Collections.Generic.List[object]'
                }
                [void]$sizeBuckets[$sizeKey].Add($record)

                # Time-based UI throttling is much cheaper than repainting every N files,
                # especially on SSDs that can enumerate thousands of entries per second.
                if ($uiWatch.ElapsedMilliseconds -ge 160) {
                    $elapsed = [math]::Max(0.001, $indexWatch.Elapsed.TotalSeconds)
                    $rate = $totalFileCount / $elapsed
                    $StatusText.Text = ('Indexing {0}: {1:N0} files found ({2:N0} total)' -f $source, $sourceDone, $totalFileCount)
                    $script:SourceUi[$source].Info.Text = ('{0:N0} files found' -f $sourceDone)
                    $TotalEtaText.Text = ('{0:N0} files indexed - {1:N0} files/sec' -f $totalFileCount, $rate)
                    Do-Events
                    $uiWatch.Restart()
                }
            }

            Set-SourceProgress $source 45 ('Indexed {0:N0} files' -f $sourceDone) $false
            Do-Events
        }

        $TotalProgressBar.IsIndeterminate = $false
        Set-TotalProgress 45 ('Indexed {0:N0} files in {1}' -f $totalFileCount, (Format-Eta $indexWatch.Elapsed.TotalSeconds))

        if ($script:CancelRequested) { throw (New-Object System.OperationCanceledException) }

        # ----------------------------------------------------------
        # Stage 2: Pull only multi-file size buckets into the
        # candidate list. 45% -> 50%.
        # ----------------------------------------------------------
        $StatusText.Text = 'Preparing possible duplicate candidates...'
        foreach ($source in $sources) {
            Set-SourceProgress $source 45 '45.0% - Preparing candidates...'
        }
        Do-Events

        $possibleList = New-Object 'System.Collections.Generic.List[object]'
        [long]$bucketTotal = $sizeBuckets.Count
        [long]$bucketDone = 0
        $prepUiWatch = [System.Diagnostics.Stopwatch]::StartNew()

        foreach ($entry in $sizeBuckets.GetEnumerator()) {
            if ($script:CancelRequested) { throw (New-Object System.OperationCanceledException) }
            $bucketDone++

            if ($entry.Value.Count -gt 1) {
                foreach ($record in $entry.Value) {
                    [void]$possibleList.Add($record)
                }
            }

            if ($prepUiWatch.ElapsedMilliseconds -ge 160 -or $bucketDone -eq $bucketTotal) {
                $prepFrac = if ($bucketTotal -gt 0) { $bucketDone / [double]$bucketTotal } else { 1 }
                $prepPct = 45 + (5 * $prepFrac)
                Set-TotalProgress $prepPct ('Preparing candidates: {0:N0} of {1:N0} size groups' -f $bucketDone, $bucketTotal)
                $StatusText.Text = ('Preparing duplicate candidates: {0:N0} of {1:N0} size groups' -f $bucketDone, $bucketTotal)
                Do-Events
                $prepUiWatch.Restart()
            }
        }

        $possible = $possibleList.ToArray()
        foreach ($source in $sources) {
            Set-SourceProgress $source 50 '50.0% - Waiting for SHA-256 verification'
        }
        Set-TotalProgress 50 ('{0:N0} possible duplicate files found. Starting SHA-256 verification...' -f $possible.Count)
        $PhaseNoteText.Text = '50% is the handoff point: duplicate candidates are ready. Dupe Goblin is calculating the SHA-256 workload and opening the first candidate file. A sleeping, busy, or slow drive can make this sit here briefly; the scan is still active.'
        $PhaseNoteText.Visibility = 'Visible'
        $StatusText.Text = 'Starting SHA-256 verification...'
        Do-Events

        # We no longer need the size buckets. Release them before hashing.
        $sizeBuckets = $null

        # ----------------------------------------------------------
        # Stage 3: SHA-256 verification. 50% -> 100%.
        # Progress remains byte-based, but UI updates are throttled so
        # the interface no longer steals a significant share of hashing time.
        # ----------------------------------------------------------
        [long]$totalCandidateBytes = 0
        $bytesBySource = @{}
        foreach ($source in $sources) { $bytesBySource[$source] = [long]0 }
        foreach ($item in $possible) {
            $totalCandidateBytes += [long]$item.Size
            $bytesBySource[$item.Source] += [long]$item.Size
        }

        $hashBuckets = @{}

        if ($possible.Count -gt 0) {
            $PhaseNoteText.Text = ('50% is the verification handoff. Dupe Goblin will read {0:N0} candidate files ({1}) and compare their SHA-256 hashes. The first file can take a moment to open if its drive is asleep or busy.' -f $possible.Count, (Format-Size $totalCandidateBytes))
            Do-Events
        }

        if ($possible.Count -eq 0) {
            foreach ($source in $sources) { Set-SourceProgress $source 100 '100% - No duplicate candidates' }
            Set-TotalProgress 100 'ETA: Done'
            $PhaseNoteText.Visibility = 'Collapsed'
        } else {
            $StatusText.Text = ('Verifying {0:N0} possible duplicate files with SHA-256...' -f $possible.Count)
            $hashedBytesBySource = @{}
            foreach ($source in $sources) { $hashedBytesBySource[$source] = [long]0 }
            [long]$hashedOverallBytes = 0
            $hashWatch = [System.Diagnostics.Stopwatch]::StartNew()

            foreach ($source in $sources) {
                if ($bytesBySource[$source] -eq 0) {
                    Set-SourceProgress $source 100 '100% - No duplicate candidates'
                }
            }

            [long]$candidateIndex = 0
            foreach ($item in $possible) {
                if ($script:CancelRequested) { throw (New-Object System.OperationCanceledException) }
                $candidateIndex++
                $baseSourceBytes = [long]$hashedBytesBySource[$item.Source]
                $baseOverallBytes = $hashedOverallBytes

                # Update before FileStream.Open. If a drive is waking up or a file is slow
                # to open, the user can see exactly what Dupe Goblin is waiting on.
                $preSourceFrac = if ($bytesBySource[$item.Source] -gt 0) { $baseSourceBytes / [double]$bytesBySource[$item.Source] } else { 0 }
                $preSourcePct = 50 + (50 * $preSourceFrac)
                Set-SourceProgress $item.Source $preSourcePct ('{0:N1}% - Opening candidate {1:N0}' -f $preSourcePct, $candidateIndex)
                $StatusText.Text = ('Opening candidate {0:N0} of {1:N0}: {2}' -f $candidateIndex, $possible.Count, $item.Path)
                $PhaseNoteText.Text = ('SHA-256 verification is active. Opening/reading candidate {0:N0} of {1:N0}. If this message sits for a while, the current drive or file is taking time to respond.' -f $candidateIndex, $possible.Count)
                Do-Events

                $progressCallback = {
                    param([long]$FileDone, [long]$FileLength)

                    $sourceDoneBytes = $baseSourceBytes + $FileDone
                    $sourceTotalBytes = [long]$bytesBySource[$item.Source]
                    $sourceFrac = if ($sourceTotalBytes -gt 0) { $sourceDoneBytes / [double]$sourceTotalBytes } else { 1 }
                    $srcPct = 50 + (50 * $sourceFrac)

                    $overallDoneBytesNow = $baseOverallBytes + $FileDone
                    $overallFrac = if ($totalCandidateBytes -gt 0) { $overallDoneBytesNow / [double]$totalCandidateBytes } else { 1 }
                    $overallPct = 50 + (50 * $overallFrac)

                    $elapsed = [math]::Max(0.001, $hashWatch.Elapsed.TotalSeconds)
                    $eta = if ($overallDoneBytesNow -gt 0) { ($elapsed / $overallDoneBytesNow) * ($totalCandidateBytes - $overallDoneBytesNow) } else { [double]::NaN }
                    $rate = $overallDoneBytesNow / $elapsed
                    $srcRemainingBytes = [math]::Max(0, $sourceTotalBytes - $sourceDoneBytes)
                    $srcEta = if ($rate -gt 0) { $srcRemainingBytes / $rate } else { [double]::NaN }

                    Set-SourceProgress $item.Source $srcPct ('{0:N1}% - ETA {1}' -f $srcPct, (Format-Eta $srcEta))
                    Set-TotalProgress $overallPct ('ETA: {0} - {1}/s' -f (Format-Eta $eta), (Format-Size ([long]$rate)))
                    $StatusText.Text = ('Verifying: {0}  ({1})' -f $item.Path, (Format-Size $item.Size))
                    $PhaseNoteText.Text = ('SHA-256 verification is running. Candidate {0:N0} of {1:N0}; progress is now based on bytes read.' -f $candidateIndex, $possible.Count)
                }

                try {
                    $hash = Get-ExactHash -Path $item.Path -FileLength $item.Size -ProgressCallback $progressCallback
                    if ($hash) {
                        $hashKey = [string]$hash
                        if (-not $hashBuckets.ContainsKey($hashKey)) {
                            $hashBuckets[$hashKey] = New-Object 'System.Collections.Generic.List[object]'
                        }
                        [void]$hashBuckets[$hashKey].Add([pscustomobject]@{
                            Path = $item.Path
                            Size = $item.Size
                            Hash = $hash
                            Source = $item.Source
                        })
                    }
                } catch [System.OperationCanceledException] {
                    throw
                } catch {
                    $script:SkippedFiles++
                }

                $hashedBytesBySource[$item.Source] += [long]$item.Size
                $hashedOverallBytes += [long]$item.Size
            }

            foreach ($source in $sources) { Set-SourceProgress $source 100 '100% - Done' }
            Set-TotalProgress 100 'Finalizing duplicate groups...'
            $PhaseNoteText.Text = 'SHA-256 verification is complete. Dupe Goblin is assembling the final duplicate groups.'
            $PhaseNoteText.Visibility = 'Visible'
        }

        if ($script:CancelRequested) { throw (New-Object System.OperationCanceledException) }

        # ----------------------------------------------------------
        # Finalize exact duplicate groups without Group-Object.
        # Keep the UI alive even if there are many candidate hashes.
        # ----------------------------------------------------------
        $StatusText.Text = 'Building final duplicate groups and report...'
        Do-Events

        $groupsList = New-Object 'System.Collections.Generic.List[object]'
        [long]$hashBucketTotal = $hashBuckets.Count
        [long]$hashBucketDone = 0

        foreach ($entry in $hashBuckets.GetEnumerator()) {
            if ($script:CancelRequested) { throw (New-Object System.OperationCanceledException) }
            $hashBucketDone++
            if ($entry.Value.Count -gt 1) {
                $groupFiles = $entry.Value.ToArray()
                [void]$groupsList.Add([pscustomobject]@{
                    Count = $groupFiles.Count
                    Group = $groupFiles
                })
            }

            if (($hashBucketDone % 250) -eq 0 -or $hashBucketDone -eq $hashBucketTotal) {
                $StatusText.Text = ('Finalizing duplicate groups: {0:N0} of {1:N0}' -f $hashBucketDone, $hashBucketTotal)
                Do-Events
            }
        }

        $groups = @($groupsList.ToArray() | Sort-Object { [long]$_.Group[0].Size } -Descending)
        Set-TotalProgress 100 'ETA: Done'
        foreach ($source in $sources) { Set-SourceProgress $source 100 '100% - Done' }

        $resultRows = New-Object 'System.Collections.Generic.List[object]'
        $report = New-Object 'System.Collections.Generic.List[string]'
        $report.Add('DUPE GOBLIN - DUPLICATE FILE REPORT')
        $report.Add('Exact byte-for-byte duplicates only. No files were changed.')
        $report.Add(('Created: {0}' -f (Get-Date)))
        $report.Add(('Files scanned: {0:N0}' -f $totalFileCount))
        $report.Add(('Duplicate groups: {0:N0}' -f $groups.Count))
        $report.Add(('Ignore hidden files and folders: {0}' -f $(if ($script:IgnoreHidden) { 'Yes' } else { 'No' })))
        $report.Add('')
        $report.Add('Scanned locations:')
        foreach ($source in $sources) { $report.Add(('  {0}' -f $source)) }
        $report.Add('')

        [long]$wastedBytes = 0
        $groupNumber = 0
        foreach ($group in $groups) {
            $groupNumber++
            $groupSize = [long]$group.Group[0].Size
            $wastedBytes += $groupSize * ($group.Count - 1)
            $report.Add('============================================================')
            $report.Add(('DUPLICATE GROUP {0} - {1}' -f $groupNumber, (Format-Size $groupSize)))
            $report.Add('============================================================')
            foreach ($file in ($group.Group | Sort-Object Path)) {
                [void]$resultRows.Add([pscustomobject]@{
                    Group = $groupNumber
                    Size = Format-Size $file.Size
                    Path = $file.Path
                })
                $report.Add(('{0}    [{1}]' -f $file.Path, (Format-Size $file.Size)))
            }
            $report.Add('')
        }

        if ($groups.Count -eq 0) {
            $report.Add('No exact duplicate files were found.')
        }

        if ($script:SkippedFolders -gt 0 -or $script:SkippedFiles -gt 0) {
            $report.Add('')
            $report.Add(('Skipped inaccessible folders: {0:N0}' -f $script:SkippedFolders))
            $report.Add(('Skipped unreadable files: {0:N0}' -f $script:SkippedFiles))
        }

        $logsFolder = Join-Path $PSScriptRoot 'Logs'
        if (-not (Test-Path -LiteralPath $logsFolder)) {
            [void](New-Item -ItemType Directory -Path $logsFolder -Force)
        }

        $reportPath = Join-Path $logsFolder 'Dupe Goblin - Duplicate Report.txt'
        $report | Set-Content -LiteralPath $reportPath -Encoding UTF8
        $script:LastReportPath = $reportPath

        $ResultsGrid.ItemsSource = $resultRows.ToArray()
        $ResultsSummary.Text = ('Found {0:N0} duplicate groups containing {1:N0} files. Extra duplicate copies occupy about {2}. Report saved to the Logs folder.' -f $groups.Count, $resultRows.Count, (Format-Size $wastedBytes))
        $OpenReportButton.IsEnabled = $true
        $OpenSelectedButton.IsEnabled = $false
        $StatusText.Text = ('Complete. Found {0:N0} exact duplicate groups.' -f $groups.Count)
    }
    catch [System.OperationCanceledException] {
        $StatusText.Text = 'Scan cancelled. No files were changed.'
        $ResultsSummary.Text = 'Scan cancelled. No report was written.'
        $TotalEtaText.Text = 'Cancelled'
    }
    catch {
        $StatusText.Text = ('The scan stopped because of an unexpected error: {0}' -f $_.Exception.Message)
        $ResultsSummary.Text = 'No files were changed.'
        $errorLine = if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) { $_.InvocationInfo.ScriptLineNumber } else { '?' }
        $nl = [Environment]::NewLine
        $errorText = 'Dupe Goblin hit an error:' + $nl + $nl + $_.Exception.Message + $nl + 'Line: ' + $errorLine + $nl + $nl + 'No scanned files were changed.'
        [System.Windows.MessageBox]::Show(
            $errorText,
            'Dupe Goblin',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
    finally {
        $script:IsScanning = $false
        Set-InputsEnabled $true
        $CancelButton.IsEnabled = $false
        Do-Events
    }
})

$window.Add_Closing({
    param($sender, $e)
    if ($script:IsScanning) {
        $script:CancelRequested = $true
        $e.Cancel = $true
        $StatusText.Text = 'Cancelling safely before closing...'
    }
})

# Retain every dashboard section at smaller sizes. At larger sizes the logical
# canvas grows with the viewport; below its baseline Viewbox scales it uniformly.
$DashboardViewport = $window.FindName('DashboardViewport')
$fitDashboard = {
    $MainScrollViewer.Width = [math]::Max(1000, $DashboardViewport.ActualWidth)
    $MainScrollViewer.Height = [math]::Max(720, $DashboardViewport.ActualHeight)
}
$DashboardViewport.Add_SizeChanged({ & $fitDashboard })
$window.Add_Loaded({
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $window.Width = [math]::Min($window.Width, $workArea.Width)
    $window.Height = [math]::Min($window.Height, $workArea.Height)
    & $fitDashboard
})

[void]$window.ShowDialog()
