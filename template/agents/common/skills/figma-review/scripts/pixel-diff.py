#!/usr/bin/env python3
"""
pixel-diff.py — Quantify visual similarity between two PNG/JPG images.

Outputs:
  - SSIM (Structural Similarity Index, 0-1, higher = more similar)
  - pHash distance (Perceptual hash Hamming distance, lower = more similar)
  - MSE / pixel-level RMS error
  - Visual diff heatmap (optional --diff-out path)

Use to numerically compare a Figma reference PNG vs a live screenshot,
giving design-review iterations a concrete score instead of subjective
"looks close".

Examples:
  ./pixel-diff.py reference.png live.png
  ./pixel-diff.py figma-hero.png live-1440.png --diff-out diff-hero.png

Requires: pip install pillow opencv-python-headless imagehash numpy
scikit-image (SSIM degrades gracefully to "not available" without
scikit-image; the rest requires opencv/Pillow/imagehash and refuses
cleanly if they're missing).
"""
import argparse
import sys
from pathlib import Path

try:
    import cv2  # type: ignore
    import numpy as np
    from PIL import Image
    import imagehash
except ImportError as e:
    sys.exit(
        f"зависимость не установлена ({e.name}): "
        "pip install pillow opencv-python-headless imagehash numpy"
    )

try:
    from skimage.metrics import structural_similarity as ssim
    HAS_SSIM = True
except ImportError:
    HAS_SSIM = False


def load_and_align(reference: Path, live: Path):
    """Load both images, resize live to reference dimensions for fair comparison."""
    ref = cv2.imread(str(reference))
    lv = cv2.imread(str(live))
    if ref is None:
        sys.exit(f'Failed to read {reference}')
    if lv is None:
        sys.exit(f'Failed to read {live}')
    h_ref, w_ref = ref.shape[:2]
    h_lv, w_lv = lv.shape[:2]
    if (h_ref, w_ref) != (h_lv, w_lv):
        lv = cv2.resize(lv, (w_ref, h_ref), interpolation=cv2.INTER_AREA)
    return ref, lv


def compute_metrics(ref_bgr, lv_bgr):
    """Return dict of similarity metrics."""
    diff = cv2.absdiff(ref_bgr, lv_bgr).astype(np.float32)
    mse = float(np.mean(diff ** 2))
    rms = float(np.sqrt(mse))

    ssim_score = None
    if HAS_SSIM:
        gray_ref = cv2.cvtColor(ref_bgr, cv2.COLOR_BGR2GRAY)
        gray_lv = cv2.cvtColor(lv_bgr, cv2.COLOR_BGR2GRAY)
        ssim_score = float(ssim(gray_ref, gray_lv))

    ph_ref = imagehash.phash(Image.fromarray(cv2.cvtColor(ref_bgr, cv2.COLOR_BGR2RGB)))
    ph_lv = imagehash.phash(Image.fromarray(cv2.cvtColor(lv_bgr, cv2.COLOR_BGR2RGB)))
    phash_dist = int(ph_ref - ph_lv)

    h, w = ref_bgr.shape[:2]
    cell_h, cell_w = h // 3, w // 3
    region_scores = []
    for ry in range(3):
        for rx in range(3):
            y, x = ry * cell_h, rx * cell_w
            r_cell = ref_bgr[y:y + cell_h, x:x + cell_w]
            l_cell = lv_bgr[y:y + cell_h, x:x + cell_w]
            cell_mse = float(np.mean(cv2.absdiff(r_cell, l_cell).astype(np.float32) ** 2))
            region_scores.append({
                'row': ry, 'col': rx,
                'mse': cell_mse, 'rms': float(np.sqrt(cell_mse)),
            })

    return {
        'mse': mse,
        'rms': rms,
        'ssim': ssim_score,
        'phash_distance': phash_dist,
        'region_scores': region_scores,
    }


def make_diff_heatmap(ref_bgr, lv_bgr, out_path: Path):
    diff = cv2.absdiff(ref_bgr, lv_bgr)
    gray = cv2.cvtColor(diff, cv2.COLOR_BGR2GRAY)
    amp = np.clip(gray.astype(np.float32) * 3.0, 0, 255).astype(np.uint8)
    heat = cv2.applyColorMap(amp, cv2.COLORMAP_HOT)
    base = cv2.addWeighted(ref_bgr, 0.4, heat, 0.6, 0)
    cv2.imwrite(str(out_path), base)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('reference', type=Path, help='Reference image (e.g. Figma export)')
    p.add_argument('live', type=Path, help='Live screenshot to compare')
    p.add_argument('--diff-out', type=Path, help='Path to save visual diff heatmap PNG')
    p.add_argument('--format', choices=['text', 'json'], default='text')
    args = p.parse_args()

    ref, lv = load_and_align(args.reference, args.live)
    metrics = compute_metrics(ref, lv)

    if args.diff_out:
        args.diff_out.parent.mkdir(parents=True, exist_ok=True)
        make_diff_heatmap(ref, lv, args.diff_out)

    if args.format == 'json':
        import json
        print(json.dumps(metrics, indent=2))
        return

    print(f'=== Pixel diff: {args.reference.name} vs {args.live.name} ===')
    print(f'RMS error:       {metrics["rms"]:.2f}  (0 = identical, 255 = max difference)')
    print(f'MSE:             {metrics["mse"]:.2f}')
    if metrics['ssim'] is not None:
        ssim_pct = metrics['ssim'] * 100
        print(f'SSIM:            {metrics["ssim"]:.4f}  ({ssim_pct:.1f}% structural similarity)')
    else:
        print('SSIM:            not available (pip install scikit-image for this metric)')
    print(f'pHash distance:  {metrics["phash_distance"]}  (0 = identical perceptually, >10 = very different)')

    worst = sorted(metrics['region_scores'], key=lambda r: -r['rms'])[:3]
    print('\nWorst-matching 3x3 grid regions (focus area for fixes):')
    pos = {(0, 0): 'top-left', (0, 1): 'top-center', (0, 2): 'top-right',
           (1, 0): 'mid-left', (1, 1): 'mid-center', (1, 2): 'mid-right',
           (2, 0): 'bottom-left', (2, 1): 'bottom-center', (2, 2): 'bottom-right'}
    for r in worst:
        print(f'  {pos[(r["row"], r["col"])]:>13} — RMS {r["rms"]:.1f}')

    if args.diff_out:
        print(f'\nVisual diff heatmap saved: {args.diff_out}')

    print('\n=== Interpretation ===')
    if metrics['ssim'] is not None:
        s = metrics['ssim']
        if s > 0.95: status = 'near-identical'
        elif s > 0.85: status = 'very similar, minor diffs'
        elif s > 0.70: status = 'noticeable diffs (likely color/spacing)'
        elif s > 0.50: status = 'significant diffs (likely layout)'
        else: status = 'major mismatch'
        print(f'Overall: {status} (SSIM {s:.3f})')
    if metrics['phash_distance'] > 12:
        print('Perceptual hash suggests substantially different content.')


if __name__ == '__main__':
    main()
