package com.yashasvi.hackathon.config;

import static com.yashasvi.hackathon.config.SecurityConstants.*;
import com.yashasvi.hackathon.dto.Constants;
import io.jsonwebtoken.Claims;
import io.jsonwebtoken.JwtException;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.authority.AuthorityUtils;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import javax.crypto.SecretKey;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

@Slf4j
@Component
public class JwtTokenValidatorFilter extends OncePerRequestFilter {

    @Value("${jwt.security.token.secret_key}")
    public String JWT_SECRET_KEY;


    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain filterChain) throws ServletException, IOException {
        String header = req.getHeader(Constants.AUTHORIZATION.getValue());
        if (header != null && header.startsWith(Constants.TOKEN_PREFIX.getValue())) {
            String authToken = header.substring(Constants.TOKEN_PREFIX.getValue().length()).trim();
            try {
                SecretKey key = Keys.hmacShaKeyFor(JWT_SECRET_KEY.getBytes(StandardCharsets.UTF_8));
                Claims claims = Jwts.parser().verifyWith(key).build().parseSignedClaims(authToken).getPayload();
                String username = String.valueOf(claims.get(Constants.USERNAME.getValue()));
                String authorities = String.valueOf(claims.get(Constants.AUTHORITIES.getValue()));
                Authentication auth = new UsernamePasswordAuthenticationToken(username, null,
                        AuthorityUtils.commaSeparatedStringToAuthorityList(authorities));
                SecurityContextHolder.getContext().setAuthentication(auth);
            } catch (JwtException | IllegalArgumentException e) {
                log.warn("Invalid JWT rejected: {}", e.getMessage());
                SecurityContextHolder.clearContext();
                res.sendError(HttpServletResponse.SC_UNAUTHORIZED, "Invalid or expired token");
                return;
            }
        }
        filterChain.doFilter(req, res);
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        return request.getServletPath().equals(LOGIN)
                || request.getServletPath().equals(SIGN_IN);
    }
}
