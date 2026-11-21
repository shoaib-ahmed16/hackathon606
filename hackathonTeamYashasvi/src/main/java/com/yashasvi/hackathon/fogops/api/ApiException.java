package com.yashasvi.hackathon.fogops.api;

import org.springframework.http.HttpStatus;

/** An error the FogOps API reports to the UI as {"detail": message} with the given status. */
public class ApiException extends RuntimeException {

    private final HttpStatus status;

    public ApiException(HttpStatus status, String detail) {
        super(detail);
        this.status = status;
    }

    public HttpStatus getStatus() {
        return status;
    }
}
