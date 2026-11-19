package com.yashasvi.hackathon.exception;

import lombok.NoArgsConstructor;

@NoArgsConstructor
public class DatabaseUnknownServerError extends RuntimeException {
    public DatabaseUnknownServerError(String message) {
        super(message);
    }
}
