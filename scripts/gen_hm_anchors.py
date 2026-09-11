import os, subprocess, sys
sys.path.insert(0, 'scripts')
from calc_psnr_ssim import evaluate_yuv_sequence

HM_ENC = r'HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppEncoder.exe'
HM_CFG = r'HM\cfg\encoder_lowdelay_main10.cfg'
ORIG_YUV = 'orig_foreman_128x128_10b.yuv'

results = []
for qp in [22, 27, 32, 37]:
    bin_f = f'hm_foreman_qp{qp}.bin'
    rec_f = f'hm_rec_foreman_qp{qp}.yuv'
    cmd = [HM_ENC, '-c', HM_CFG, '-i', ORIG_YUV, '-b', bin_f, '-o', rec_f, '-wdt', '128', '-hgt', '128', '-f', '5', '-fr', '30', '-q', str(qp), '--InternalBitDepth=10', '--OutputBitDepth=10', '--InputBitDepth=10']
    res = subprocess.run(cmd, capture_output=True, text=True)
    if os.path.exists(bin_f):
        size = os.path.getsize(bin_f)
        rate = size * 8.0 * 30.0 / (5.0 * 1000.0)
        stats = evaluate_yuv_sequence(ORIG_YUV, rec_f, 128, 128, 5, bit_depth=10)
        results.append((qp, size, rate, stats['psnr_y_avg']))
        print(f'HM Anchor QP={qp}: Size={size} B, Bitrate={rate:.2f} kbps, PSNR-Y={stats["psnr_y_avg"]:.2f} dB')

print('\n--- HM Reference Anchor Summary ---')
print('| QP | Size (B) | Bitrate (kbps) | PSNR-Y (dB) |')
print('|:--:|:--------:|:--------------:|:-----------:|')
for qp, sz, r, p in results:
    print(f'| {qp} | {sz} | {r:.2f} | {p:.2f} |')
