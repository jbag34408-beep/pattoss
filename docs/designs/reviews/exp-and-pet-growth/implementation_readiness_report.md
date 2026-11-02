# Stage 9 — Implementation Readiness 검토 보고서

- 대상: `docs/designs/exp-and-pet-growth.md` 248~406행 (Detailed Implementation Plan)
- 검토자: egm-implementation-readiness, egm-codebase-details (implementation-readiness-standard), egm-style
- 날짜: 2026-11-02
- 판정: **아직 구현할 수 없음.** 그대로 구현하면 첫 실행에서 깨지는 곳(I-2, I-3, I-5)과 구현자가 정해야 하는 곳이 남아 있다.

중복은 하나로 합쳤고, 괄호 안에 제기한 검토자를 적었다(IR = implementation-readiness, CD = codebase-details, ST = style).

## 🔴 Blocker

### I-1. 단계 하락이 정해지지 않았다 (IR 1, CD 10)

- 296행 `applyTotalExp`는 `stage = PetStage.of(total)`을, 389행 불변식은 회수 시 단계 하락을 전제한다. 고정 결정 7과 충돌하고, D2에는 이 선택지가 없다.
- Stage 5~8의 C-1과 같은 문제다. D6 결정을 내려야 296·386·389행이 정해진다.
- 졸업 뒤 회수 테스트("3,999 → 졸업 → TASK 회수 → 기대 단계와 `graduated_at` 유지")를 19번에 추가한다.

## 🟡 Major

### I-2. 엔티티 ID 생성 전략이 없다 (CD 1)

- `@GeneratedValue`(AUTO)만 붙이면 Hibernate 6이 `*_seq` 시퀀스를 기대하고, `validate`에서 기동이 실패한다.
- 권고: `GenerationType.IDENTITY`를 명시한다(쓰기는 네이티브이므로 생략해도 된다).

### I-3. 네이티브 쿼리의 enum 바인딩과 프로젝션 모양이 없다 (IR 3, CD 2, CD 5)

- enum을 그대로 넘기면 ORDINAL로 바인딩되어 `varchar` 컬럼에서 실패한다.
- 권고: 파라미터는 `String reason`(`reason.name()`)으로 한다. 프로젝션은 `ReasonTotal { String getReason(); long getTotal(); }`, SQL 별칭은 `AS reason`/`AS total`로 둔다. `SUM`은 `bigint`이므로 `long`으로 받고 서비스에서 `int`와 `ExpReason.valueOf`로 바꾼다.

### I-4. 회수액을 구할 방법이 없다 (CD 3)

- `deleteGrant`는 삭제한 행 수를 돌려준다. 음수 `gainedExp`를 만들 금액이 없다.
- 권고: 재계산 전후 `sumTotal`의 차이로 구한다(추천). 다른 방법은 삭제 전 `SELECT amount`다.

### I-5. 테스트용 고정 `Clock` 덮어쓰기가 그대로는 실패한다 (IR 4, CD 6)

- 빈 덮어쓰기가 금지되어 `BeanDefinitionOverrideException`이 나거나, 빈이 2개가 되어 `NoUniqueBeanDefinitionException`이 난다.
- 권고: `@Bean @Primary Clock`을 쓴다. `ExpService`에서 Clock이 쓰이는 곳은 `graduatedAt`뿐이라는 점도 적는다.

### I-6. 영속성 컨텍스트에 오래된 `Pet`이 남을 수 있다 (CD 4)

- 호출자가 소유권 확인을 위해 `Pet`을 먼저 읽으면, `FOR UPDATE`를 실행해도 이미 관리 중인 인스턴스가 새로 고쳐지지 않는다. 그러면 `stageChanged`와 `graduatedAt` 판정이 오래된 값으로 된다.
- 권고: "`ExpService`가 펫을 잠그고 읽는 첫 지점이다. 호출자는 그 전에 `Pet`을 로드하지 않는다"를 명시하거나 `refresh(pet, PESSIMISTIC_WRITE)`를 쓴다. Stage 8의 "펫 먼저 잠금" 규칙과 합치면, 호출자가 맨 처음 `findByIdForUpdate`로 소유권까지 확인하는 형태가 가장 단순하다.

### I-7. STREAK가 0일에도 지급된다 (IR 2, CD 9)

- 권고: `streakDays > 0 && streakDays % 7 == 0`으로 쓰고, 0·6·7·14일 테스트를 넣는다.

### I-8. 정산 `items`의 순서가 정해지지 않았다 (IR 6, CD 5)

- 권고: Java에서 `ExpReason` 선언 순서(`ordinal`)로 정렬한다. 384행 테스트에서 순서도 검증한다.

### I-9. 테스트 데이터를 넣는 방법이 없다 (IR 7, CD 8)

- `total_exp`는 로그 합계로 덮어쓰이므로 `pets.total_exp`만 넣으면 안 된다. 누적용 로그는 **과거 `plan_date`**로 넣어야 한다. 오늘 날짜로 넣으면 상한 때문에 졸업 테스트가 실패한다.
- 권고: `JdbcTemplate` + `RETURNING id`로 넣고, 정리는 `DELETE FROM users`(CASCADE)로 한다. 동시성 테스트에는 `@Transactional`을 쓰지 않는다. 스레드는 `ExecutorService` + `CountDownLatch`로 돌린다.

### I-10. 동시성 테스트가 상한을 검증하지 못한다 (CD 7)

- 20개 × 5 = 100이라 잠금이 없어도 통과한다.
- 권고: 할 일을 25개로 늘리거나, 오늘 합계 98을 미리 넣는다.

### I-11. 단계(Phase)와 체크포인트가 없다 (IR 5, CD 12)

- `validate` 때문에 순서가 중요하다.
- 권고 순서:
  - Phase 1: V1 + 테스트 인프라
  - Phase 2: Clock/DayClock/PetStage + 단위 테스트
  - Phase 3: 엔티티/리포지토리/서비스 + 통합 테스트
  - Phase 4: SITEMAP
- 단계마다 테스트가 통과해야 다음으로 넘어간다.

### I-12. 파일 번호 참조가 틀렸다 (IR 8, CD 11, ST 1·2)

- 250행 "6번"과 314행 "9번"은 둘 다 11번 `ExpLogRepository`가 맞다. 번호 대신 파일명으로 참조하는 방법도 있다.

### I-13. SITEMAP은 이미 등록되어 있다 (CD 13)

- 권고: 20번을 "승인 후 상태 칸 갱신"으로 바꾼다.

### I-14. 385행 테스트 조건이 숫자가 아니다 (ST 3)

- 권고 예: "오늘 합계 90에서 정산(BONUS_RATE 요청 15) → BONUS_RATE 10, STREAK 50은 합계 100 이후에도 지급".

## 🟢 Nit

| ID | 출처 | 내용 |
| --- | --- | --- |
| I-15 | IR 9, CD 14 | 353행 "모든 통합 테스트가 같은 컨테이너"는 틀렸다. Clock 설정이 다르면 컨텍스트가 하나 더 뜬다. Clock 덮어쓰기를 `TestcontainersConfiguration`에 넣으면 공유된다 |
| I-16 | IR 10 | 테스트 파일마다 한국어 `@DisplayName` 규칙(AGENTS.md 7장)을 적는다 |
| I-17 | IR 11 | `settle` 두 번 호출 시 두 번째 지급이 0인지 확인하는 멱등 테스트를 추가한다 |
| I-18 | IR 12, CD 18 | 397행에 Windows 명령 `.\gradlew.bat build`와 Docker 필요를 적는다 |
| I-19 | IR 13 | 로그 `created_at`은 DB `now()`이고 고정 Clock과 무관하다(의도임을 명시) |
| I-20 | CD 15 | `ExpLog`에 `@Immutable`을 붙인다. 대안으로 `JdbcClient`를 쓰면 파일 2개가 줄어든다(선택) |
| I-21 | CD 16 | 잠금 타임아웃을 두지 않는 것은 의도라고 한 줄 적는다 |
| I-22 | CD 19 | `org.testcontainers:junit-jupiter`가 더는 쓰이지 않으면 유지할지 정한다 |
| I-23 | CD 20, ST 8 | "패키지 공개" → "package-private" |
| I-24 | ST 4~16 | 축약어("경계 4시간"), 참조 표기 통일, 항목 형식(Why/Type 누락), "insert" → "삽입", 363행 말줄임표, 368행 시각 표기, 377행 `.class`, 384·386행 화살표 의미, 399행 "E2E" 레이블, 400행 "경고 없음" 확인 방법 |

## 정확함을 확인한 항목

경로·패키지와 골격 일치, `@Enumerated(STRING)`↔VARCHAR, `Instant`↔TIMESTAMPTZ, `@Modifying` 반환 행 수, `ON CONFLICT` 0 반환, `@ServiceConnection` 패턴, 금액 상수와 메서드 시그니처, `PetStage`/`DayClock` 경계 테스트.

## 확인하지 않은 것

코드를 실행하지 않았다. I-2, I-3, I-5는 Spring Boot 3.5/Hibernate 6의 알려진 기본 동작을 근거로 판단했다.
