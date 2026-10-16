param(
    [int]$IntervalMs = 100
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Native {
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
}
"@

$LEFTDOWN = 0x0002
$LEFTUP = 0x0004
$VK_F8 = 0x77
$VK_F9 = 0x78

$running = $false
Write-Host "F8: 시작/정지  |  F9: 종료  |  클릭 간격: ${IntervalMs}ms"
Write-Host "현재 마우스 커서 위치를 클릭합니다."

while ($true) {
    if ([Native]::GetAsyncKeyState($VK_F9) -band 0x8000) { break }

    if ([Native]::GetAsyncKeyState($VK_F8) -band 0x8000) {
        $running = -not $running
        if ($running) { Write-Host "[시작]" } else { Write-Host "[정지]" }
        while ([Native]::GetAsyncKeyState($VK_F8) -band 0x8000) { Start-Sleep -Milliseconds 20 }
    }

    if ($running) {
        [Native]::mouse_event($LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
        [Native]::mouse_event($LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds $IntervalMs
    } else {
        Start-Sleep -Milliseconds 20
    }
}
Write-Host "종료"
