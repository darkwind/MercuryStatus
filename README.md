# MercuryStatus

그라비스타(Gravastar) **Mercury X Pro** 무선 마우스의 상태를 macOS 메뉴바에서 확인하고 설정을 바꾸는 앱입니다.
제조사 웹 UI 없이 배터리, 폴링레이트, DPI, 센서 설정을 바로 보고 바꿀 수 있습니다.

## 기능

| 구분 | 항목 |
|---|---|
| 보기 | 배터리(%, 충전 여부, 전압), 실측 폴링레이트 |
| 보기·변경 | 응답 속도(125–8000Hz), DPI 단계 수·현재 단계·단계별 값(50–32000), 센서 모드(LP/HP/Corded), LOD(0.7/1/2mm), 최대 성능과 유지 시간, 리플 제어, 직선 보정, 모션 싱크 |
| 보기 전용 | DPI 단계별 LED 색 |

- 메뉴바에 배터리 %가 항상 표시되고, 클릭하면 상세 창이 열립니다.
- 60초마다 자동으로 갱신되며, ↻ 버튼으로 바로 갱신할 수도 있습니다.
- 설정은 바꾸는 즉시 마우스에 쓰고, **다시 읽어 같은 값인지 확인**합니다. 다르면 빨간 오류를 표시하고, 화면에는 마우스에서 실제로 읽은 값만 보여줍니다.
- 🐞 버튼을 누르면 원시 응답과 설정 메모리 덤프를 볼 수 있습니다. 같은 내용이 `~/Library/Application Support/MercuryStatus/diagnostics.txt`에도 저장됩니다.

## 요구 사항

- macOS 14 이상, Apple Silicon
- Xcode 또는 Command Line Tools (`swiftc`)
- 2.4G 수신기(VID `0x3554`, PID `0xF54B`)로 연결된 Mercury X Pro

## 빌드와 설치

```bash
./build.sh            # build/MercuryStatus.app 생성
./build.sh install    # 빌드 후 /Applications에 설치하고 실행
```

Xcode 프로젝트 없이 `swiftc`로 빌드하고 ad-hoc 서명합니다.

### 입력 모니터링 권한

macOS는 마우스·키보드 HID 장치를 열 때 **입력 모니터링** 권한을 요구합니다. 처음 실행하면 권한 요청 창이 뜹니다.
**시스템 설정 › 개인정보 보호 및 보안 › 입력 모니터링**에서 MercuryStatus를 켜면, 앱이 2초 안에 스스로 다시 연결합니다.

> ad-hoc 서명이라 **다시 빌드할 때마다 macOS가 다른 앱으로 인식**해서 권한을 다시 허용해야 합니다.
> 목록에 예전 항목이 남아 있으면 아래 명령으로 지운 뒤 앱을 다시 실행하세요.
>
> ```bash
> tccutil reset ListenEvent com.duegosystem.MercuryStatus
> ```

### 로그인 시 자동 실행

`~/Library/LaunchAgents/com.duegosystem.MercuryStatus.plist`를 만들면 로그인할 때 앱이 실행됩니다.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.duegosystem.MercuryStatus</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>-a</string><string>/Applications/MercuryStatus.app</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.duegosystem.MercuryStatus.plist
```

해제하려면 아래 명령을 실행한 뒤 plist 파일을 지우세요.

```bash
launchctl bootout gui/$(id -u)/com.duegosystem.MercuryStatus
```

## 소스 구성

| 파일 | 역할 |
|---|---|
| `Sources/CompxDevice.swift` | IOKit HID로 수신기를 찾아 열고, 명령 패킷을 보내 응답을 기다림. 마우스 이동 리포트 시각 전달 |
| `Sources/MouseMonitor.swift` | 상태 갱신, 설정 메모리 해석(`DecodedConfig`), 설정 쓰기(`Setting`, `apply`), 실측 폴링레이트 계산, 진단 파일 기록 |
| `Sources/App.swift` | SwiftUI 메뉴바 UI |
| `build.sh` | 빌드, 서명, 설치 |

## 프로토콜

수신기는 Compx 칩셋(CX5x 계열)을 쓰며, 같은 칩을 쓰는 VXE/ATK/Redragon 마우스와 프로토콜이 같습니다.
아래 내용은 공개 프로젝트의 분석을 바탕으로, **Mercury X Pro에서 웹 UI 설정을 하나씩 바꿔 가며 메모리 덤프를 비교해 확인**한 것입니다.

### 패킷

벤더 인터페이스(Usage Page `0xFF05`)의 Output Report `0x08`, 17바이트:

```
[08] [cmd] [00] [addrHi] [addrLo] [len] [data × 10] [checksum]
```

- `checksum` = `0x55 − (앞 16바이트 합)` (mod 256)
- 응답은 Input Report `0x08`(또는 `0x09`)로 같은 cmd와 주소가 돌아옵니다.

| cmd | 의미 | 응답 |
|---|---|---|
| `0x03` | 상태 | `[6]` = 1이면 마우스 연결됨, 0이면 절전/미연결 |
| `0x04` | 전원 | `[6]` 배터리 %, `[7]` 충전 중(1), `[8..9]` 전압 mV (빅엔디언) |
| `0x07` | 메모리 쓰기 | 즉시 반영, 별도 저장 명령 없음 |
| `0x08` | 메모리 읽기 | `[6..]`에 `len` 바이트 |

### 설정 메모리

모든 값은 **레코드** 단위입니다. 레코드는 값 뒤에 체크섬 1바이트가 붙고, 전체 합이 `0x55`가 됩니다(예: 값 `01` → `01 54`).

| 주소 | 항목 | 값 |
|---|---|---|
| `0x00` | 응답 속도 | `08`=125, `04`=250, `02`=500, `01`=1000, `10`=2000, `20`=4000, `40`=8000 Hz |
| `0x02` | DPI 단계 수 | 1–8 |
| `0x04` | 현재 DPI 단계 | 0부터 |
| `0x0A` | LOD | `0`=0.7mm, `1`=1mm, `2`=2mm |
| `0x0C` | DPI 표 | 단계당 4바이트 `[X Y hi ck]`, 8단계 |
| `0x2C` | DPI 단계별 색 | 단계당 4바이트 `[R G B ck]` |
| `0xAB` | 모션 싱크 | 0/1 |
| `0xAF` | 직선 보정 | 0/1 |
| `0xB1` | 리플 제어 | 0/1 |
| `0xB5` | 최대 성능 | 0/1 |
| `0xB7` | 최대 성능 유지 시간 | 10초 단위 (`06`=1분) |
| `0xB9` | 센서 모드 | `0`=LP, `1`=HP, `2`=Corded |

**DPI 인코딩:** `hi`의 하위 니블은 X축, 상위 니블은 Y축입니다. 각 니블에서

- bit2: 값의 bit8 (값에 256을 더함)
- bit0: 단위를 50에서 100으로

`DPI = ((lo | bit2 << 8) + 1) × (bit0 ? 100 : 50)`

| DPI | 레코드 |
|---|---|
| 800 | `0f 0f 00 37` |
| 6400 | `7f 7f 00 57` |
| 20000 | `8f 8f 44 f3` |
| 32000 | `3f 3f 55 82` |

앱은 25600 이하는 50 단위, 그 위는 100 단위로 씁니다.

### 실측 폴링레이트

벤더 인터페이스와 별개인 일반 마우스 인터페이스(Usage Page `0x01`, Usage `0x02`)의 리포트 도착 간격으로 계산합니다.
마우스는 움직일 때만 리포트를 보내고 도착 시각이 조금씩 흔들리므로, **연속 16개 간격 평균의 최솟값**을 폴링 주기로 보고 가장 가까운 표준값(125–8000Hz)으로 맞춥니다.

## 확인 상태와 제약

- **덤프로 직접 확인하지 않은 값**: LOD 0.7mm(`0`), 센서 모드 Corded(`2`). 웹 UI 드롭다운 순서로 정했습니다.
- **8000Hz 실측**: 8000Hz로 설정해도 실측은 4000Hz로 나옵니다. macOS가 리포트를 묶어 전달하기 때문으로 보이며, 앱에 ⓘ 안내가 표시됩니다.
- **미지원**: DPI 색 변경, 버튼 매핑, LED 효과. 해당 메모리 구역(`0x60–0x8F`, `0xA0–0xA6`)은 아직 분석하지 않았습니다.
- **테스트 환경**: 2.4G 수신기 연결만 확인했습니다. 유선·블루투스 연결은 확인하지 않았습니다.
- 설정이 잘못 바뀌면 Gravastar 웹 UI에서 언제든 되돌릴 수 있습니다.

## 참고

- [prapooskur/vxe-battery](https://github.com/prapooskur/vxe-battery): Compx 상태/전원 명령과 체크섬
- [mateusands/open-m711pro](https://github.com/mateusands/open-m711pro): Compx 메모리 읽기/쓰기와 레코드 구조

---

© Duegosystem
