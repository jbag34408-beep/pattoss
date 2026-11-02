# exp-and-pet-growth.md 종합 검토 보고서

- 대상: `docs/designs/exp-and-pet-growth.md` (Draft)
- 모드: Consolidated (자동 수정 없이 기록만 함)
- 단계: 5 Zoom Out → 6 Comprehension → 7 Critic → 8 Intermediate Zoom Out → 9 Implementation Readiness
- 날짜: 2026-11-02
- **결론: 승인 전에 사용자 결정 1건(D6)과 문서 수정이 필요하다.**

## 1. 사용자 결정이 필요한 것

### R-1 🔴 D6 신설: 체크 해제로 단계가 내려가도 되는가 (고정 결정 7과 관련)

- 출처: Z5-2, CMP-2, C-1, IZ-1, I-1 (모든 단계에서 지적)
- 문제: "stage = PetStage.of(total_exp)"이면 95까지 회수할 때 BABY→EGG가 된다. AGENTS.md 고정 결정 7은 "퇴화하지 않는다"이다.
- 선택지(Stage 8에서 둘로 줄임):
  - **(a) 추천**: "퇴화"는 처벌 장치(브리프 1.3)만 뜻한다고 해석한다.
    - 실수로 체크를 해제해 단계가 내려가는 것은 허용한다.
    - 단, `graduated_at`이 있으면 GRADUATED를 유지한다.
    - 추가 코드가 거의 없고 `PetStage.of` 순수 함수(고정 결정 6)를 지킨다.
    - 고정 결정 7의 문구를 좁게 해석하는 것이므로 승인이 필요하다.
  - (b) 단계는 "도달한 최고 단계"로 둔다(`max(현재, of(total))`).
    - 고정 결정 7 문구를 그대로 지킨다.
    - 단계가 별도 상태가 되어 고정 결정 6과 긴장 관계가 생긴다.
- (c) "경계를 넘긴 지급은 회수 안 함"은 Goal("그 할 일 지급만 정확히 회수")을 깨서 뺐다.

### R-2 D1~D5: 문서의 추천안을 그대로 받을지 확인

- D1 B, D2 A, D3 A, D4 B, D5 B
- 검토자들은 모두 추천안이 타당하다고 봤다.
- D1은 다음 문서(daily-plan-and-tasks)로 옮겨도 된다(Z5-4).

## 2. 승인 전에 고칠 것 (🟡, 문서 수정만 필요)

| ID | 내용 | 출처 |
| --- | --- | --- |
| R-3 | **잠금 순서: 모든 경로가 펫 행을 먼저 잠근다**(브리프 6.2와 같음). 호출자가 `findByIdForUpdate`로 맨 처음 펫을 읽고 소유권을 확인하면 오래된 엔티티 문제도 사라진다 | Z5-1, CMP-3, C-2, IZ-4, I-6 |
| R-4 | 회수 흐름 "1~3은 같다" → "1단계(펫 잠금) 뒤 DELETE, 7~9단계" | Z5-5, CMP-4, C-10 |
| R-5 | D2 근거 문장을 실제 누수 경로(펫을 넘나드는 TASK 회수, 사용자 기준 하루 100 깨짐)로 고친다. D2-D안은 넣지 않는다 | Z5-3, C-3, IZ-2 |
| R-6 | D2-A에 영향 한 줄을 넣는다: `POST /pets` 조건 변경, 새 알 전까지 졸업 펫이 계속 받음 | C-4, CMP-8, IZ-6 |
| R-7 | "한계" 3~4줄 절: 캐시는 다음 쓰기에서 다시 맞춰짐, `exp_logs`가 감사 기록, 펫 없음은 `IllegalStateException`, PLAN은 확정 시점 판정만 봄. 새 장치는 넣지 않는다 | C-5, C-6, IZ-3, IZ-5 |
| R-8 | 엔티티 ID 전략은 `IDENTITY` | I-2 |
| R-9 | 네이티브 쿼리 파라미터는 `String reason`. 프로젝션은 `String getReason(); long getTotal();` | I-3 |
| R-10 | 회수액은 재계산 전후 `sumTotal`의 차이로 구한다 | I-4 |
| R-11 | 테스트 Clock은 `@Primary` 빈으로 하고 `TestcontainersConfiguration`에 넣는다(컨테이너 공유) | I-5, I-15 |
| R-12 | STREAK 조건 `streakDays > 0 && % 7 == 0`과 0일 테스트 | I-7 |
| R-13 | 정산 `items`를 `ExpReason` 선언 순서로 정렬 | I-8 |
| R-14 | 테스트 데이터: `JdbcTemplate`, 누적 로그는 과거 `plan_date`, 동시성 테스트는 `@Transactional` 금지 | I-9 |
| R-15 | 동시성 테스트는 요청 합이 100을 넘게 한다(할 일 25개 또는 합계 98을 미리 넣음) | I-10 |
| R-16 | 구현 순서를 Phase 1~4로 나눈다 | I-11 |
| R-17 | 파일 번호 오류(250행 6번, 314행 9번 → 11번 `ExpLogRepository`) | CMP-1, I-12 |
| R-18 | 각 D 항목 끝에 "영향: …" 한 줄(250행 내용을 옮김) | C-9, IZ-8 |
| R-19 | 용어: "계획 마감(12:00)" / "하루 마감". 참조 표기는 "브리프 N.N"으로 통일 | C-7, C-8 |
| R-20 | SITEMAP은 이미 등록됨 → "승인 후 상태 갱신" | I-13 |
| R-21 | 385행 등 테스트 조건을 숫자로 쓴다 | I-14 |

## 3. 다듬기 (🟢)

- 문서 앞부분: C-11~C-26, Comprehension 5~7
- 구현 계획: I-16~I-24
- 모두 문장 수정이며 범위가 늘지 않는다.

## 4. 넣지 않기로 한 제안 (Stage 8 판단)

- D6 선택지 (c)
- D2-D안
- Risks 절의 모니터링·정합성 잡·재시도 장치
- 일별 합계 행 + CHECK, advisory lock 대안(C-14)
- 할 일 행을 먼저 잠그는 순서(C-2의 (2))

## 5. 추적표

| 단계 | 보고서 | 반영된 ID |
| --- | --- | --- |
| 5 | zoom_out_report.md | R-1, R-3, R-4, R-5, R-2(D1 이동) |
| 6 | comprehension_report.md | R-1, R-3, R-4, R-6, R-17, Nit |
| 7 | critic_report.md | R-1, R-3~R-7, R-18, R-19, Nit |
| 8 | intermediate_zoom_out_report.md | R-1 선택지 축소, 4절 전체 |
| 9 | implementation_readiness_report.md | R-1, R-3, R-8~R-17, R-20, R-21, Nit |

## 다음 단계

1. 사용자가 R-1(D6)과 R-2(D1~D5)를 정한다.
2. 2절의 수정을 설계 문서에 반영한다.
3. 필요하면 `/egm:egm-review`를 다시 실행한다.
4. Status를 Approved로 바꾸고 SITEMAP을 갱신한다.
5. Phase 1부터 구현한다.
