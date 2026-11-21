package com.yashasvi.hackathon.fogops.api;

import com.yashasvi.hackathon.fogops.auth.FogopsAuthFilter;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class FogopsWebConfig {

    /** The auth filter runs inside the Spring Security chain only: stop Boot from also registering it as a plain servlet filter. */
    @Bean
    FilterRegistrationBean<FogopsAuthFilter> fogopsAuthFilterRegistration(FogopsAuthFilter filter) {
        FilterRegistrationBean<FogopsAuthFilter> reg = new FilterRegistrationBean<>(filter);
        reg.setEnabled(false);
        return reg;
    }
}
