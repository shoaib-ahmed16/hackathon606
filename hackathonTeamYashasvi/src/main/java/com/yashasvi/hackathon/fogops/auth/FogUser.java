package com.yashasvi.hackathon.fogops.auth;

/** The signed-in FogOps user (a row of fogops.app_user), available to controllers through the security context. */
public record FogUser(int userId, String username, String displayName, String role) {
}
