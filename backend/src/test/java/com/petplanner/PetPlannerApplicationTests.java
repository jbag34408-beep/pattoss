package com.petplanner;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;

@SpringBootTest
@Import(TestcontainersConfiguration.class)
class PetPlannerApplicationTests {

    @Test
    @DisplayName("PostgreSQL 16에 V1 마이그레이션을 적용하고 애플리케이션 컨텍스트가 뜬다")
    void contextLoads() {
    }
}
