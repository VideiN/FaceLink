"""임시 앱 아이콘 (2026-10-25, TestFlight에 올리려면 아이콘이 있어야 해서): 남색 바탕, 흰 얼굴 윤곽(눈 둘, 입),
오른쪽으로 나가는 청록 전파 호 두 겹 (얼굴 수치를 보낸다). App Store Connect가 받는 1024x1024 불투명 PNG를 만든다.
모서리는 iOS가 둥글게 자른다.

사용법: python scripts/make-app-icon.py FaceLink/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png  (Pillow 필요)
"""

import sys

from PIL import Image, ImageDraw

out = sys.argv[1]
N = 4096  # 크게 그린 뒤 줄여 가장자리를 매끈하게
img = Image.new("RGB", (N, N))
draw = ImageDraw.Draw(img)
# 남색 세로 그라데이션 (위가 조금 밝게)
top, bottom = (30, 50, 98), (10, 16, 40)
for y in range(N):
    t = y / (N - 1)
    draw.line([(0, y), (N, y)], fill=tuple(round(top[i] * (1 - t) + bottom[i] * t) for i in range(3)))

white = (245, 247, 252)
teal = (64, 214, 200)
line = round(N * 0.04)


def dot(x, y, r, fill):
    draw.ellipse([x - r, y - r, x + r, y + r], fill=fill)


# 얼굴: 왼쪽으로 조금 비킨 세로로 긴 타원
cx, cy = N * 0.42, N * 0.5
rx, ry = N * 0.22, N * 0.27
draw.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], outline=white, width=line)
# 눈
for side in (-1, 1):
    dot(cx + side * rx * 0.42, cy - ry * 0.18, N * 0.028, white)
# 입 (웃는 호)
mouth = [cx - rx * 0.45, cy - ry * 0.05, cx + rx * 0.45, cy + ry * 0.5]
draw.arc(mouth, start=25, end=155, fill=white, width=line)
for angle_x, angle_y in ((0.906, 0.423), (-0.906, 0.423)):  # 호 끝을 둥글게 (25°, 155°)
    mx, my = (mouth[0] + mouth[2]) / 2, (mouth[1] + mouth[3]) / 2
    ax, ay = (mouth[2] - mouth[0]) / 2 - line / 2, (mouth[3] - mouth[1]) / 2 - line / 2
    dot(mx + ax * angle_x, my + ay * angle_y, line / 2, white)

# 오른쪽으로 나가는 전파 호 두 겹
ox = cx + rx * 0.55
for radius in (N * 0.24, N * 0.33):
    box = [ox - radius, cy - radius, ox + radius, cy + radius]
    draw.arc(box, start=-35, end=35, fill=teal, width=line)
    for sign in (-1, 1):  # 호 끝을 둥글게
        mid = radius - line / 2
        dot(ox + mid * 0.819, cy + sign * mid * 0.574, line / 2, teal)

icon = img.resize((1024, 1024), Image.LANCZOS)
icon.save(out, "PNG", optimize=True)
print("saved", out, icon.size, icon.mode)
