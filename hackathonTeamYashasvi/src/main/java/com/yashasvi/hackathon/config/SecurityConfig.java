package com.yashasvi.hackathon.config;

import static com.yashasvi.hackathon.config.SecurityConstants.*;
import com.yashasvi.hackathon.domain.ROLE;
import com.yashasvi.hackathon.fogops.auth.FogopsAuthFilter;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.authentication.configuration.AuthenticationConfiguration;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.www.BasicAuthenticationFilter;
import org.springframework.security.web.savedrequest.NullRequestCache;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.CorsConfigurationSource;
import org.springframework.web.cors.UrlBasedCorsConfigurationSource;

import java.util.List;

@Configuration
public class SecurityConfig {

    private final JwtTokenValidatorFilter jwtTokenValidatorFilter;
    private final FogopsAuthFilter fogopsAuthFilter;

    /** Comma separated list of allowed origins, e.g. https://shop.example.com */
    @Value("${security.cors.allowed-origins:http://localhost:3000,http://localhost:4200}")
    private List<String> allowedOrigins;

    public SecurityConfig(JwtTokenValidatorFilter jwtTokenValidatorFilter, FogopsAuthFilter fogopsAuthFilter) {
        this.jwtTokenValidatorFilter = jwtTokenValidatorFilter;
        this.fogopsAuthFilter = fogopsAuthFilter;
    }

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .cors(cors -> cors.configurationSource(corsConfigurationSource()))
                // Stateless API authenticated by a bearer token (no cookies) -> CSRF protection not required.
                .csrf(AbstractHttpConfigurer::disable)
                .requestCache(cache -> cache.requestCache(new NullRequestCache()))
                .authorizeHttpRequests(authorize -> authorize
                        .requestMatchers(HttpMethod.POST, SIGN_IN, LOGIN).permitAll()
                        // FogOps API: sign-in and health are open, everything else under /api/** needs a FogOps token
                        .requestMatchers(HttpMethod.POST, FogopsAuthFilter.LOGIN).permitAll()
                        .requestMatchers(HttpMethod.GET, "/health").permitAll()
                        // Boot's error dispatch (e.g. an unknown /api path must answer 404, not 401)
                        .requestMatchers("/error").permitAll()
                        .requestMatchers("/swagger-ui/**", "/swagger-ui.html", "/v3/api-docs/**").permitAll()
                        .requestMatchers("/actuator/health/**").permitAll()
                        .requestMatchers(HttpMethod.GET, CUSTOMERS, USER_DETAILS)
                            .hasRole(ROLE.ADMIN.getName())
                        .requestMatchers(HttpMethod.GET, CUSTOMER_BY_EMAIL)
                            .hasAnyRole(ROLE.ADMIN.getName(), ROLE.USER.getName())
                        .anyRequest().authenticated())
                // FogOps API answers an unauthenticated call with a JSON 401 (not a browser Basic-auth prompt)
                .exceptionHandling(e -> e.defaultAuthenticationEntryPointFor(
                        (req, res, ex) -> {
                            res.setStatus(401);
                            res.setContentType("application/json");
                            res.getWriter().write("{\"detail\":\"Sign in required\"}");
                        },
                        req -> FogopsAuthFilter.isFogopsPath(req.getServletPath())))
                .addFilterBefore(jwtTokenValidatorFilter, BasicAuthenticationFilter.class)
                .addFilterBefore(fogopsAuthFilter, BasicAuthenticationFilter.class)
                .addFilterAfter(new AuthorisedUserLoggingFilter(), BasicAuthenticationFilter.class)
                .httpBasic(Customizer.withDefaults());
        return http.build();
    }

    @Bean
    public CorsConfigurationSource corsConfigurationSource() {
        CorsConfiguration cfg = new CorsConfiguration();
        cfg.setAllowCredentials(true);
        cfg.setAllowedOrigins(allowedOrigins);
        cfg.setAllowedMethods(ALLOWED_METHODS);
        cfg.setAllowedHeaders(ALLOWED_HEADERS);
        cfg.setExposedHeaders(EXPOSED_HEADERS);
        cfg.setMaxAge(3600L);
        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", cfg);
        return source;
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }

    @Bean
    public AuthenticationManager authenticationManager(AuthenticationConfiguration authenticationConfiguration) throws Exception {
        return authenticationConfiguration.getAuthenticationManager();
    }
}
