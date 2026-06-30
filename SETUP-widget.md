# GwaTop 홈 화면 위젯 — Xcode 셋업 가이드

코드는 모두 작성돼 있다. 아래는 Xcode GUI에서만 안전하게 할 수 있는 단계(타겟 추가, capability)다.
`project.pbxproj`를 손으로 편집하면 프로젝트가 깨질 수 있어 의도적으로 GUI 단계로 남겼다.

> ⚠️ 이 단계를 끝내기 전까지는 **앱 타겟도 빌드되지 않는다.** 앱 코드가 새 공유 파일
> (`GwaTopWidgetShared.swift`)의 `GwaTopWidgetStore` / `GwaTopWidgetBridge`를 참조하기 때문.

---

## 1. 위젯 익스텐션 타겟 추가

1. Xcode에서 `GwaTop.xcodeproj` 열기.
2. **File ▸ New ▸ Target… ▸ Widget Extension**.
3. Product Name: **`GwaTopWidget`**  (Team: F4L969R757, "Include Configuration App Intent" 체크 **해제** — 정적 위젯이라 불필요).
4. "Activate scheme?" 묻는 팝업은 **Cancel** (앱 스킴 유지).
5. Xcode가 만든 템플릿 기본 파일(`GwaTopWidget.swift`, `GwaTopWidgetBundle.swift` 등 자동 생성본)은 **삭제**한다 — 우리가 작성한 파일로 대체할 것이므로.

## 2. 작성된 소스 파일을 타겟에 연결

작성된 파일들은 이미 디스크에 있다. Xcode 프로젝트 네비게이터에서 **Add Files to "GwaTop"…** 로 추가하고, 각 파일의 **Target Membership**(우측 File Inspector)을 아래처럼 체크한다.

| 파일 | 앱 타겟(GwaTop) | 위젯 타겟(GwaTopWidget) |
|---|:---:|:---:|
| `GwaTopShared/GwaTopWidgetShared.swift` | ✅ | ✅ |
| `GwaTop/GwaTopWidgetBridge.swift` | ✅ | ⬜ |
| `GwaTopWidget/GwaTopWidgetBundle.swift` | ⬜ | ✅ |
| `GwaTopWidget/GwaTopScheduleWidget.swift` | ⬜ | ✅ |
| `GwaTopWidget/GwaTopWidgetViews.swift` | ⬜ | ✅ |
| `GwaTopWidget/GwaTopWidgetAPI.swift` | ⬜ | ✅ |

> 핵심: `GwaTopWidgetShared.swift`는 **양쪽 타겟 모두** 체크. 나머지 위젯 파일은 위젯 타겟만.

## 3. App Group capability (앱·위젯 양쪽)

두 타겟 모두 동일한 App Group을 공유해야 데이터가 오간다.

1. 프로젝트 ▸ **GwaTop** 타겟 ▸ **Signing & Capabilities** ▸ **+ Capability** ▸ **App Groups**.
2. 그룹 추가: **`group.com.minjunkwon.gwatop.dev`** 입력 후 체크.
3. **GwaTopWidget** 타겟에도 동일하게 반복 — 같은 그룹 ID 체크.

> Xcode가 각 타겟에 `*.entitlements`를 자동 생성/연결한다.
> 미리 만들어 둔 `GwaTop/GwaTop.entitlements`, `GwaTopWidget/GwaTopWidgetExtension.entitlements`는
> 동일한 그룹 ID를 담은 참고본이다. Xcode가 만든 파일을 쓰거나, 이 파일을
> `CODE_SIGN_ENTITLEMENTS`에 지정해도 된다. (그룹 ID만 일치하면 됨.)

## 4. 빌드 & 실행

1. **GwaTop** 스킴으로 앱을 한 번 실행 → 로그인하면 대시보드를 받으며 위젯 스냅샷이 App Group에 저장된다.
2. 홈 화면 길게 눌러 **+ ▸ 오늘의 과탑** 위젯 추가 → Small / Medium / Large 중 선택.
3. 위젯 갤러리 미리보기는 샘플 데이터로 뜨고, 추가 후 실제 데이터로 채워진다.

---

## 동작 방식 (하이브리드 A+B)

- **A. 스냅샷(기본):** 앱이 `GET /v1/home/dashboard`를 받을 때마다
  `GwaTopWidgetBridge.publish(dashboard:)`가 오늘 일정·임박 할 일을 App Group UserDefaults에 저장하고
  위젯 타임라인을 reload. 위젯은 앱 없이도 이 스냅샷을 즉시 그린다.
- **B. 직접 fetch(보강):** 위젯 타임라인 갱신(약 30분 주기 + 자정) 시 App Group에 미러링된
  access token으로 대시보드를 직접 한 번 호출해 최신화. 토큰 만료·네트워크 실패 시 조용히 A로 폴백.

## 크기별 구성

- **Small** — 오늘 날짜 + 남은 할 일 수 배지 + 다음 일정 한 건(D-day·시각·과목).
- **Medium** — 구글 캘린더식 좌우 분할: 좌측 날짜 카드 / 우측 오늘 일정·할 일 목록(최대 4건).
- **Large** — 미니 월간 캘린더(오늘 강조 + 일정 있는 날 점) + 오늘 목록 + 다가오는 할 일 + 주간 진척 pill.

## 알아둘 점 / 향후 개선

- **토큰 보관:** 프로토타입이라 access token을 App Group UserDefaults에 미러링한다(컨테이너 샌드박스
  보호). 운영 전환 시 `keychain-access-groups` 기반 Keychain 공유로 승격 권장.
- **과목 색:** 위젯은 `course_color` hex를 그대로 쓴다. 앱의 원색→파스텔 리매핑(`Color.gwaTopHex`)은
  적용하지 않아 일부 과목 색이 앱보다 진하게 보일 수 있다. 동일하게 맞추려면 리매핑 테이블을 공유 파일로 옮길 것.
- **위젯 탭 동작:** 현재는 탭하면 앱이 그냥 열린다. 특정 화면으로 딥링크하려면 각 행에 `Link`/`widgetURL`을 추가.
