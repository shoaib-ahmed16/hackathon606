package com.yashasvi.hackathon.fogops.api;

import lombok.extern.slf4j.Slf4j;
import org.postgresql.util.PSQLException;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;

import java.util.Map;

/** Every error reaches the UI as {"detail": "..."}; database guardrails become readable messages. */
@Slf4j
@RestControllerAdvice(basePackages = "com.yashasvi.hackathon.fogops")
public class ApiExceptionHandler {

    private static ResponseEntity<Map<String, String>> of(HttpStatus status, String detail) {
        return ResponseEntity.status(status).body(Map.of("detail", detail));
    }

    @ExceptionHandler(ApiException.class)
    ResponseEntity<Map<String, String>> api(ApiException e) {
        return of(e.getStatus(), e.getMessage());
    }

    @ExceptionHandler({MethodArgumentNotValidException.class, HttpMessageNotReadableException.class,
            MissingServletRequestParameterException.class, MethodArgumentTypeMismatchException.class})
    ResponseEntity<Map<String, String>> invalidInput(Exception e) {
        String detail = e instanceof MissingServletRequestParameterException m
                ? "Missing query parameter: " + m.getParameterName()
                : e instanceof MethodArgumentTypeMismatchException t
                ? "Invalid value for " + t.getName()
                : e instanceof MethodArgumentNotValidException v && v.getBindingResult().getFieldError() != null
                ? v.getBindingResult().getFieldError().getField() + ": " + v.getBindingResult().getFieldError().getDefaultMessage()
                : "Invalid request";
        return of(HttpStatus.UNPROCESSABLE_ENTITY, detail);
    }

    /**
     * Database guardrails and constraint failures. RAISE EXCEPTION from our triggers/functions (SQLSTATE P0001) is
     * a refusal: 403 when it is about roles/humans/guardrails, otherwise 409. Integrity and data errors are 422.
     */
    @ExceptionHandler(DataAccessException.class)
    ResponseEntity<Map<String, String>> database(DataAccessException e) {
        Throwable t = e.getMostSpecificCause();
        if (t instanceof PSQLException p) {
            String state = p.getSQLState() == null ? "" : p.getSQLState();
            String msg = p.getServerErrorMessage() != null && p.getServerErrorMessage().getMessage() != null
                    ? p.getServerErrorMessage().getMessage() : p.getMessage();
            if (state.equals("P0001")) {
                boolean forbidden = msg.startsWith("Guardrail") || msg.contains("not authorised") || msg.toLowerCase().contains("human");
                return of(forbidden ? HttpStatus.FORBIDDEN : HttpStatus.CONFLICT, msg);
            }
            if (state.startsWith("23") || state.startsWith("22")) {
                return of(HttpStatus.UNPROCESSABLE_ENTITY, msg);
            }
        }
        log.error("Database error", e);
        return of(HttpStatus.INTERNAL_SERVER_ERROR, "Database error");
    }

    @ExceptionHandler(Exception.class)
    ResponseEntity<Map<String, String>> other(Exception e) throws Exception {
        if (e instanceof org.springframework.security.access.AccessDeniedException
                || e instanceof org.springframework.security.core.AuthenticationException) {
            throw e;   // Spring Security turns these into 403/401
        }
        log.error("Unhandled error", e);
        return of(HttpStatus.INTERNAL_SERVER_ERROR, "Internal error");
    }
}
