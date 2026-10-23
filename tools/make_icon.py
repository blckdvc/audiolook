#!/usr/bin/env python3
"""Génère l'icône de LoopLook : squircle façon Finder (bicolore) avec une forme d'onde
   sombre sur la moitié claire et claire sur la moitié bleue (clin d'œil au visage du Finder).
   Produit Resources/AppIcon.iconset/*.png (puis iconutil -> AppIcon.icns côté macOS)."""
import os
import numpy as np
from PIL import Image, ImageDraw

SS = 2048          # rendu supersample
N  = 1024          # taille finale du master
MARGIN = 92 * SS // 1024

def lerp(c1, c2, t):
    return tuple(int(round(c1[i] + (c2[i] - c1[i]) * t)) for i in range(3))

def squircle_mask(size, margin, n=5.0):
    a = (size - 2 * margin) / 2.0
    c = size / 2.0
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float64)
    nx = (xx - c) / a
    ny = (yy - c) / a
    inside = (np.abs(nx) ** n + np.abs(ny) ** n) <= 1.0
    # bord adouci
    d = (np.abs(nx) ** n + np.abs(ny) ** n)
    edge = np.clip((1.02 - d) / 0.04, 0.0, 1.0)
    m = np.where(inside, 1.0, edge)
    return (m * 255).astype(np.uint8)

def two_tone(size):
    """fond bicolore : gauche clair (dégradé), droite bleu (dégradé)"""
    L_top, L_bot = (0xD6, 0xE2, 0xEE), (0xB0, 0xC4, 0xD8)
    R_top, R_bot = (0x3A, 0xA4, 0xFF), (0x0A, 0x68, 0xE6)
    img = np.zeros((size, size, 3), dtype=np.uint8)
    for y in range(size):
        t = y / (size - 1)
        img[y, :size // 2] = lerp(L_top, L_bot, t)
        img[y, size // 2:] = lerp(R_top, R_bot, t)
    return img

def waveform_layer(size, color):
    """barres verticales (forme d'onde) centrées, caps arrondis, sur fond transparent"""
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    heights = [0.17, 0.30, 0.22, 0.47, 0.33, 0.64, 0.42, 0.82, 0.54,
               0.82, 0.42, 0.64, 0.33, 0.47, 0.22, 0.30, 0.17]
    n = len(heights)
    x0, x1 = 0.205 * size, 0.795 * size
    span = x1 - x0
    slot = span / n
    bw = slot * 0.52
    mid = size / 2.0
    for i, h in enumerate(heights):
        cx = x0 + slot * (i + 0.5)
        hh = h * size * 0.5
        r = bw / 2.0
        d.rounded_rectangle([cx - bw / 2, mid - hh, cx + bw / 2, mid + hh],
                            radius=r, fill=color)
    return im

def build_master():
    size = SS
    mask = squircle_mask(size, MARGIN)                       # (size,size) uint8
    base = two_tone(size)                                    # (size,size,3)
    tile = np.dstack([base, mask]).astype(np.uint8)
    tile_img = Image.fromarray(tile, "RGBA")

    navy = waveform_layer(size, (0x0B, 0x3B, 0x66, 255))     # sombre -> moitié claire
    white = waveform_layer(size, (0xFF, 0xFF, 0xFF, 255))    # clair -> moitié bleue

    # masques moitiés
    Lm = Image.new("L", (size, size), 0)
    ImageDraw.Draw(Lm).rectangle([0, 0, size // 2 - 1, size], fill=255)
    Rm = Image.new("L", (size, size), 0)
    ImageDraw.Draw(Rm).rectangle([size // 2, 0, size, size], fill=255)

    from PIL import ImageChops
    navy.putalpha(ImageChops.multiply(navy.getchannel("A"), Lm))
    white.putalpha(ImageChops.multiply(white.getchannel("A"), Rm))

    tile_img.alpha_composite(navy)
    tile_img.alpha_composite(white)

    # applique le masque squircle en dernier (coupe tout débordement)
    a = ImageChops.multiply(tile_img.getchannel("A"), Image.fromarray(mask, "L"))
    tile_img.putalpha(a)

    return tile_img.resize((N, N), Image.LANCZOS)

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(here)
    iconset = os.path.join(repo, "Resources", "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    master = build_master()
    master.save(os.path.join(repo, "Resources", "AppIcon-1024.png"))
    sizes = {
        "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
    }
    for name, px in sizes.items():
        master.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    print("iconset écrit dans", iconset)

if __name__ == "__main__":
    main()
