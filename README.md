# Face Link

아이폰의 TrueDepth 카메라로 얼굴을 추적해 **수치만**(영상은 보내지 않는다) 같은 Wi-Fi의 아이패드 [Broadcast](https://github.com/VideiN/iPadOS-broadcasting)로 보내는 컴패니언 앱. Broadcast가 받아 아바타를 그려 방송 화면에 넣는다.

- 프로토콜: FaceLink v1. [VMC 프로토콜](https://protocol.vmc.info/english)(OSC/UDP, 포트 39539)과 호환되므로 VSeeFace처럼 VMC를 받는 프로그램에도 보낼 수 있다
- 설계와 프로토콜: [docs/face-link.md](docs/face-link.md) (Broadcast 저장소와 같은 문서)
- 지금은 만드는 중이다: ARKit 얼굴 추적과 정면 보정, 시험 송신(합성 얼굴), 보낼 곳 고르기(Bonjour, QR, 직접 입력)까지 있다. 미리보기·어둡게 모드 같은 화면은 아직 없다

## 받기와 설치

Mac 없이 GitHub Actions에서 빌드한다. 설치는 두 가지다.

- **TestFlight**: main에 푸시하면 CI가 기기용 빌드를 정식 서명해 App Store Connect에 올린다. 아이폰의 TestFlight 앱으로 설치한다 (내부 테스터는 심사 없이 받고, 한 빌드는 90일 동안 쓸 수 있다). 다른 브랜치는 Actions에서 수동 실행할 때 "TestFlight에 올리기"를 고르면 올린다 (testflight 환경이 그 브랜치를 허락해야 한다)
- **LiveContainer**: [Actions](../../actions)의 성공한 실행에서 아티팩트 `facelink-ipa-<실행 번호>`를 내려받아 설치한다. 서명 없는(가짜 서명) IPA다

설치한 앱이 어느 빌드인지는 버전(`0.1.<실행 번호>`, TestFlight와 LiveContainer 목록에 보인다)과 앱 화면 아래의 `#<실행 번호> <브랜치> <커밋>`으로 알 수 있다.

### TestFlight 설정 (포크해서 쓸 때)

`scripts/testflight.sh`가 가짜 서명 IPA를 받아 프로필이 App Store용이고 이 앱의 App ID이며 그 인증서로 만든 것인지 확인한 뒤, 이 실행만 쓰는 키체인으로 다시 서명해 `altool`로 올린다. 같은 빌드 번호가 이미 올라가 있으면(실패한 실행을 다시 돌릴 때) 다시 올리지 않는다. 다음 작업이 App Store Connect API(`scripts/asc.py`)로 처리 완료를 기다린다. 서명된 IPA는 아티팩트로 남기지 않는다.

1. 개발자 사이트에 App ID(번들 ID, `project.yml`의 `PRODUCT_BUNDLE_IDENTIFIER`)를 등록하고, Apple Distribution 인증서로 App Store용 프로필을 만든다
2. App Store Connect에 그 번들 ID로 앱을 만들고, 내부 테스트 그룹에 자기 계정을 넣는다
3. 저장소 Settings > Environments에 `testflight` 환경을 만들고(배포 브랜치는 올릴 브랜치만), 비밀값을 넣는다. 하나도 없으면 올리지 않고 넘어간다

| 비밀값 | 내용 |
|---|---|
| `APPLE_DIST_P12_BASE64`, `APPLE_DIST_P12_PASSWORD` | Apple Distribution 인증서와 개인 키(.p12, base64)와 그 비밀번호. CSR은 맥 없이 `openssl`로 만들 수 있다 |
| `APPLE_PROFILE_BASE64` | App Store용 프로필(.mobileprovision, base64) |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect API 키 (.p8 파일 내용) |

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

[MIT](LICENSE). Broadcast(GPL)의 앱 코드는 쓰지 않고, 두 앱은 프로토콜로만 연결된다. TestFlight 스크립트(`scripts/testflight.sh`, `scripts/asc.py`)는 두 저장소의 저작자가 Broadcast에서 쓴 것을 이 저장소에 MIT로 둔 것이다.
