param([switch]$SkipA1)
$tests = @('tb_adsr', 'tb_mixer', 'tb_voice_allocator', 'tb_voice', 'tb_audio_core_a2')
if (!$SkipA1) { $tests += 'tb_audio_core' }
& (Join-Path $PSScriptRoot '../../tools/verify_stage2.ps1') -Tests $tests
