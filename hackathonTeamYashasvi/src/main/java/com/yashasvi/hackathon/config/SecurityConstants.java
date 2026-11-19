package com.yashasvi.hackathon.config;

import java.util.List;

public final class SecurityConstants {

    private SecurityConstants() {
    }

    // ---- API paths ----
    public static final String SECURITY_BASE = "/api/v1/security";
    public static final String SIGN_IN = "/api/v1/signIn";   // registers a new user
    public static final String LOGIN = "/api/v1/login";      // authenticates and returns a JWT
    public static final String HELLO = SECURITY_BASE + "/hello";
    public static final String CUSTOMER_BY_EMAIL = SECURITY_BASE + "/customer/{email}";
    public static final String CUSTOMERS = SECURITY_BASE + "/customers";
    public static final String USER_DETAILS = SECURITY_BASE + "/userDetails";
    public static final String CONTACT = SECURITY_BASE + "/contact";
    public static final String NOTICE = SECURITY_BASE + "/notice";
    public static final String WRITE = SECURITY_BASE + "/write";

    // ---- CORS ----
    public static final List<String> ALLOWED_METHODS = List.of("GET", "POST", "PUT", "DELETE", "OPTIONS");
    public static final List<String> ALLOWED_HEADERS = List.of("Authorization", "Content-Type", "Accept");
    public static final List<String> EXPOSED_HEADERS = List.of("Authorization");
}
