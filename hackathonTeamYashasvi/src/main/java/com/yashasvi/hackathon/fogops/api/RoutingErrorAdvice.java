package com.yashasvi.hackathon.fogops.api;

import com.yashasvi.hackathon.fogops.auth.FogopsAuthFilter;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.HttpRequestMethodNotSupportedException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.servlet.resource.NoResourceFoundException;

import java.util.Map;

/**
 * Unknown path / wrong method under the FogOps API answers {"detail": ...} like every other error.
 * (Requests have no controller here, so this advice cannot be limited by package; other paths keep Boot's default.)
 */
@RestControllerAdvice
public class RoutingErrorAdvice {

    @ExceptionHandler(NoResourceFoundException.class)
    ResponseEntity<Map<String, String>> notFound(NoResourceFoundException e, HttpServletRequest req) throws Exception {
        if (!FogopsAuthFilter.isFogopsPath(req.getServletPath())) {
            throw e;
        }
        return ResponseEntity.status(HttpStatus.NOT_FOUND).body(Map.of("detail", "Not Found"));
    }

    @ExceptionHandler(HttpRequestMethodNotSupportedException.class)
    ResponseEntity<Map<String, String>> method(HttpRequestMethodNotSupportedException e, HttpServletRequest req) throws Exception {
        if (!FogopsAuthFilter.isFogopsPath(req.getServletPath())) {
            throw e;
        }
        return ResponseEntity.status(HttpStatus.METHOD_NOT_ALLOWED).body(Map.of("detail", "Method Not Allowed"));
    }
}
