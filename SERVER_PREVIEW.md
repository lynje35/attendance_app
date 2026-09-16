# 실제 직원 Flutter 앱 — 새 서버 연결 테스트

운영 기준은 현재 로컬 working tree다. 일반 `lib/main.dart` 실행은 기존 Apps Script를 사용한다.
별도 `lib/main_server_preview.dart` 실행만 새 서버로 연결하며 PC의 `127.0.0.1:8789` 웹에서만 허용한다.

## 실행

직원 프로젝트에서 빌드:

```powershell
flutter build web --no-pub --target lib/main_server_preview.dart --base-href /employee-app/ --output build/server-preview-web --pwa-strategy none
```

`C:\Users\lynje\development\projects\attendance_server`에서 이미 초기화한 로컬 DB로 실행:

```powershell
node node_modules/wrangler/bin/wrangler.js dev --local --config wrangler.employee-preview.jsonc --persist-to .wrangler/employee-preview --port 8789
```

- 실제 Flutter 테스트: http://127.0.0.1:8789/employee-app/
- 기존 API 확인용 HTML: http://127.0.0.1:8789/employee-test
- 가상 매장: 테스트 매장. 가상 직원: 미출근 테스트 / 근무중 테스트. 초기 비밀번호: 1234.
- 테스트 중 변경한 비밀번호와 출퇴근 상태는 로컬 DB에 유지된다. 초기 자료를 다시 넣지 않는다.
- 운영 Firebase, Android APK, 원격 직원 설정과 실제 직원 자료에는 적용하지 않는다.

## 연결 범위

- `employee_server_preview.dart`: 기존 앱 요청을 새 서버가 허용하는 항목으로 전달한다.
- `main.dart`: 테스트 연결이 설정됐을 때만 공통 API와 기존 pending 저장/삭제 지점에서 연결 코드를 호출한다.
- 서버용 요청 ID를 비밀번호 없이 저장하고 재전송에도 같은 ID를 사용한다. 퇴근은 최초 요청의 근무 기록 ID에 고정한다.
- 늦은 상태 응답이 최신 퇴근 대상 기록을 덮어쓰지 않도록 순서를 확인한다.
- 중복 요청 응답 뒤에는 현재 상태를 다시 조회한다.
- 기존 12초 제한, 자동로그인, 캐시, 5분 pending 복구, 출퇴근 UI를 사용한다.
- 스프레드시트 후처리 `maintenance`는 테스트 연결에서만 생략한다. 새 서버는 기록·감사 이력·요청 결과를 같은 트랜잭션으로 저장한다.

## 실행한 검사

- `flutter analyze --no-pub lib`: 통과.
- `flutter test --no-pub test/employee_server_preview_test.dart`: 7개 통과.
- 별도 Flutter Web 빌드: 통과.
- 전체 analyze: 기존 `test/widget_test.dart`의 `MyApp` 참조 오류가 남아 있다. 이번 범위 밖이라 수정하지 않았다.

아직 운영 전환이나 Android/iOS 연결 검증을 완료한 단계는 아니다.
