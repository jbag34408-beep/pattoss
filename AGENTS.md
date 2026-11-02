# AGENTS.md — 펫 플래너

이 파일은 이 저장소에서 일하는 모든 AI 코딩 에이전트가 따르는 지침이다.
메인 도구는 Claude Code이며, 루트의 `CLAUDE.md`가 `@AGENTS.md`로 이 파일을 불러온다.

---

## 1. 프로젝트 한 줄 요약

하루 계획을 세우고 지킬수록 사용자가 고른 동물이 자라는 앱인토스(토스 미니앱) 서비스다.
루프: 아침 계획 → 할 일 체크 → 저녁 회고 → 경험치 정산 → 동물 성장.

전체 설계는 `concepts_brief.md`, 기능별 상세 설계는 `docs/designs/`에 있다. 작업 전에 관련 문서를 먼저 읽는다.

## 2. 응답 언어

- 사용자에게 하는 설명, 커밋 메시지 본문, 코드 주석은 한국어로 쓴다
- 코드 식별자(클래스, 메서드, 변수, DB 컬럼)는 영어로 쓴다
- 사용자에게 보이는 앱 문구는 토스 UX 라이팅(해요체)을 따른다: "계획을 세워볼까요?"

## 3. 기술 스택 (바꾸지 않는다)

| 영역 | 스택 |
| --- | --- |
| 백엔드 | Spring Boot 3, Java 21, Spring Data JPA, Gradle |
| DB | PostgreSQL 16, Flyway |
| 테스트 | JUnit 5, AssertJ, Testcontainers |
| 프론트 | Vite + React 18 + TypeScript |
| UI | TDS (`@toss/tds-mobile`) |
| 플랫폼 | 앱인토스 WebView SDK (`@apps-in-toss/web-framework`) |

새 라이브러리를 추가하려면 먼저 사용자에게 이유를 말하고 승인을 받는다.

## 4. 고정된 설계 결정 (임의로 바꾸지 않는다)

1. **경험치는 서버에서만 계산한다.** 프론트는 응답의 `gainedExp`, `pet`, `settlement`를 그리기만 한다
2. **하루의 경계는 서울 시간 새벽 4시다.** 날짜 계산은 반드시 `DayClock`을 거친다. `LocalDate.now()`를 직접 호출하지 않는다
3. **경험치는 `exp_logs`에 이벤트로 쌓는다.** `pets.total_exp`는 캐시이며 직접 더하지 않는다
4. **중복 지급은 `UNIQUE (pet_id, reason, ref_id)`로 막는다.** 제약 위반은 "이미 지급됨"으로 처리한다
5. **하루 상한은 100 EXP다** (STREAK 보너스 제외)
6. **단계는 `PetStage.of(totalExp)` 순수 함수로만 계산한다.** 경계: 100 / 600 / 1800 / 4000
7. **동물은 죽거나 퇴화하지 않는다**
8. **경험치는 광고나 결제로 얻을 수 없다**
9. **앱인토스 서버 통신(mTLS)은 백엔드에서만 한다.** 프론트는 인가 코드와 `referrer`만 넘긴다
10. **외부 URL 이동, iframe을 쓰지 않는다**

이 중 하나를 바꿔야 할 것 같으면 코드를 고치지 말고 사용자에게 먼저 알린다.

## 5. 작업 방식

### 5.0 사용하는 플러그인

| 플러그인 | 용도 | 설치 |
| --- | --- | --- |
| ait (apps-in-toss) | 앱인토스 문서 검색, 미니앱 생성·콘솔 등록, 토스 앱 테스트 푸시, 검수 요청 | `claude plugin marketplace add toss/apps-in-toss-harness` → `claude plugin install ait@apps-in-toss -y` → `/mcp`에서 apps-in-toss-console 로그인 → `/ait:welcome` |
| egm | 기능 설계와 검토 | `claude plugin marketplace add google/elephant-goldfish-model` → `claude plugin install egm@egm` |
| ponytail | 구현 시 최소 코드 규칙 | MCP 서버로 연결 |

- 앱인토스 API, SDK, 정책은 기억에 의존하지 말고 ait 플러그인으로 공식 문서를 확인한 뒤 쓴다
- **백엔드는 `backend/`의 Spring Boot + PostgreSQL 자체 서버다.** Supabase, Firebase, Cloudflare, Storage API로 서버 데이터를 대체하지 않는다
- 앱인토스 미니앱 생성(콘솔 등록 + 프론트 코드)은 ait 플러그인으로 하고, 코드는 `frontend/`에 둔다
- 기기에서 확인할 문제는 사용자에게 화면 캡처를 요청한다. 에이전트는 실제 기기 화면을 볼 수 없다
- 검수가 승인돼도 공개는 사용자가 콘솔의 '출시하기'를 눌러야 한다. 에이전트가 대신 출시하지 않는다

### 5.1 설계가 필요한 작업 (EGM)

새 기능이나 설계 결정이 필요한 변경은 EGM 흐름을 따른다.

1. `docs/designs/<기능>.md`가 없으면 `/egm:egm-draft`로 먼저 설계한다
2. 설계는 `/egm:egm-review`로 검토하고 사용자가 승인한 뒤 구현한다
3. 구현은 승인된 설계 문서의 Detailed Implementation 범위만 한다
4. 구현 중 설계와 다르게 가야 하면 멈추고 설계 문서 수정을 제안한다

작은 버그 수정, 오타, 문구 변경은 설계 없이 바로 고친다.

### 5.2 구현 원칙 (Ponytail)

- **이해 먼저**: 고치기 전에 관련 설계 문서와 기존 코드를 읽는다
- **재사용 먼저**: 저장소에 이미 있는 것, Spring/JPA/TDS가 제공하는 것을 먼저 쓴다
- **최소한의 코드**: 지금 필요한 것만 만든다. "나중에 쓸 것 같은" 인터페이스, 추상 클래스, 설정, 유틸은 만들지 않는다
- **한 번에 한 단위**: API 하나 또는 화면 하나씩 작업한다
- **설계 문서 우선**: 설계에 없는 기능을 덧붙이지 않는다

### 5.3 코드 전달 방식

- 새로 만들거나 고친 파일은 부분 수정 안내 대신 **파일 전체 코드**를 준다
- 클래스, 파일, 패키지 이름은 에이전트가 이 문서의 규칙에 맞춰 정하고 알려준다
- 설계 질문을 반복해서 되묻지 않는다. 이 문서와 설계 문서로 정할 수 있으면 정하고, 정한 내용을 알려준다
- 단, EGM `/egm:egm-draft`에서 답이 여러 개인 아키텍처 결정은 사용자에게 고르게 한다

## 6. 코드 규칙

### 6.1 백엔드

- 패키지는 기능별로 나눈다: `auth`, `plan`, `pet`, `exp`, `common` (계층별 패키지 금지)
- 기본 패키지: `com.petplanner`
- 엔티티는 setter 대신 의미 있는 메서드를 둔다: `task.toggle()`, `plan.close(reflection, feeling)`
- 컨트롤러는 요청 검증과 응답 변환만 한다. 로직은 서비스에 둔다
- 요청/응답은 `record` DTO로 만든다. 엔티티를 그대로 반환하지 않는다
- 시간은 `Instant`/`OffsetDateTime`으로 저장하고(`timestamptz`), 날짜 비교는 `DayClock`이 준 `LocalDate`로 한다
- 모든 조회·수정은 로그인 사용자의 `userId`로 소유권을 확인한다. 남의 리소스는 404
- 에러는 `BusinessException(ErrorCode)` 하나로 던지고 `@RestControllerAdvice`에서 `{"code", "message"}`로 변환한다
- 스키마 변경은 `backend/src/main/resources/db/migration/V<번호>__<설명>.sql`로만 한다. `ddl-auto`는 `validate`
- 비밀 값(mTLS 인증서, JWT 키, DB 비밀번호)은 환경변수로 받는다. 저장소에 커밋하지 않는다

### 6.2 프론트

- 화면은 `src/pages/`, 재사용 컴포넌트는 `src/components/`, 서버 호출은 `src/api/`에 둔다
- UI는 TDS 컴포넌트를 먼저 쓴다. 직접 만든 스타일은 TDS에 없는 것(동물 표시, 정산 연출)에만 쓴다
- 서버 응답 타입은 `src/api/types.ts`에 모은다
- 경험치, 단계, 날짜를 프론트에서 계산하지 않는다
- 광고를 보도록 압박하거나 속이는 문구를 쓰지 않는다

## 7. 테스트 규칙

- 경험치·단계·날짜 경계 로직을 바꾸면 반드시 테스트를 같이 쓴다
- 단위 테스트 필수 대상: `PetStage.of` 경계값, 하루 상한, `DayClock`의 03:59/04:00, 정오 계획 마감
- 통합 테스트(Testcontainers + PostgreSQL) 필수 대상: 할 일 체크/해제, 같은 요청 동시 2회, 하루 마감 정산
- 시간이 들어가는 테스트는 `Clock`을 주입해 고정한다
- 테스트 이름은 한국어 `@DisplayName`으로 의도를 적는다

## 8. 명령어

```
# 백엔드
cd backend
./gradlew test          # 테스트
./gradlew bootRun       # 로컬 실행 (로컬 PostgreSQL 필요)

# 프론트
cd frontend
npm install
npm run dev             # 개발 서버, 샌드박스 앱에서 확인
npm run build           # 앱인토스 업로드용 번들
```

## 9. 하지 말 것

- 경험치 규칙, 단계 기준값, 하루 경계를 임의로 바꾸기
- 프론트에서 경험치나 단계를 계산하기
- 엔티티를 API 응답으로 그대로 내보내기
- 테스트 없이 경험치 로직 수정하기
- 설계 문서에 없는 기능, 테이블, 엔드포인트 추가하기
- 비밀 값, 인증서, `.env`를 커밋하기
- 서버 데이터를 Supabase·Firebase·기기 Storage로 옮기기
- 검수 요청, 출시를 사용자 확인 없이 진행하기
- `user`라는 이름의 테이블 만들기 (PostgreSQL 예약어)

## 10. 참고 문서

- `concepts_brief.md`: 전체 설계
- `docs/designs/SITEMAP.md`: 기능별 설계 문서 목록
- 앱인토스 개발자 문서: https://developers-apps-in-toss.toss.im
