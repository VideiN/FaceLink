# Face Link

아이폰의 TrueDepth 카메라로 얼굴을 추적해 **수치만**(영상은 보내지 않는다) 같은 Wi-Fi의 아이패드 [Broadcast](https://github.com/VideiN/iPadOS-broadcasting)로 보내는 컴패니언 앱. Broadcast가 받아 아바타를 그려 방송 화면에 넣는다.

- 프로토콜: FaceLink v1. [VMC 프로토콜](https://protocol.vmc.info/english)(OSC/UDP, 포트 39539)과 호환되므로 VSeeFace처럼 VMC를 받는 프로그램에도 보낼 수 있다
- 설계와 프로토콜: [docs/face-link.md](docs/face-link.md) (Broadcast 저장소와 같은 문서)
- 지금은 만드는 중이다: 보내기와 시험 송신(합성 얼굴), 보낼 곳 고르기(Bonjour, QR, 직접 입력)까지 있고 ARKit 얼굴 추적은 아직 없다

## 받기와 설치

Mac 없이 GitHub Actions에서 빌드한다. [Actions](../../actions)의 성공한 실행에서 아티팩트 `facelink-ipa-<실행 번호>`를 내려받아 IPA를 LiveContainer 등으로 설치한다. 서명 없는(가짜 서명) IPA다.

설치한 앱이 어느 빌드인지는 LiveContainer 목록의 버전(`0.1.<실행 번호>`)과 앱 화면 아래의 `#<실행 번호> <브랜치> <커밋>`으로 알 수 있다.

## PC에서 받아 보기

Broadcast 없이도 PC(Windows 등)에서 아이폰이 보내는 값을 볼 수 있다. 파이썬 3만 있으면 된다.

```
python scripts/facelink_receiver.py
```

- 처음 실행하면 Windows 방화벽이 Python의 네트워크 접근을 물어본다. 개인 네트워크에서 허용한다
- 시작하면 이 PC의 주소(`192.168.x.x:39539`)와 QR로 만들 `facelink://` 주소를 찍는다. 아이폰 앱의 "보낼 곳 › 직접 입력"에 주소를 넣는다
- 받는 동안 1초마다 fps, 머리 방향, 입, 눈 감음, 형식 오류 수를 한 줄씩 찍는다. Ctrl+C로 끝내면 요약을 보여 준다
- `--calibrate-after 3`을 붙이면 3초 뒤 "정면 맞추기"(`/FaceLink/Calibrate`)를 보낸다. 나머지 옵션은 `--help`

## 요구 사항

- Face ID가 있는 아이폰 (TrueDepth 카메라), iOS 26 이상
- 아이패드와 같은 Wi-Fi

## 라이선스

[MIT](LICENSE). Broadcast(GPL)의 코드는 쓰지 않고, 두 앱은 프로토콜로만 연결된다.
