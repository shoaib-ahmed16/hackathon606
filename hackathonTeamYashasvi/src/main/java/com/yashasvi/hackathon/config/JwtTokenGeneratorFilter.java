package com.yashasvi.hackathon.config;

import com.yashasvi.hackathon.dto.Constants;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import javax.crypto.SecretKey;
import java.io.IOException;
import java.util.Collection;
import java.util.Date;
import java.util.HashSet;
import java.util.Set;

@Slf4j
@Component
public class JwtTokenGeneratorFilter {

     @Value("${jwt.security.token.validity}")
     public Long TOKEN_VALIDITY;
     @Value("${jwt.security.token.secret_key}")
     public String JWT_SECRET_KEY;

    @Value("${jwt.security.token.issuer}")
    public String jwtIssuer;

    @Value("${jwt.security.token.subject}")
    public String jwtSubject;


    public String tokenGenerator(Authentication auth){
        SecretKey secretKey = Keys.hmacShaKeyFor(JWT_SECRET_KEY.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        return Jwts.builder()
                .issuer(jwtIssuer)
                .subject(jwtSubject)
                .claim(Constants.USERNAME.getValue(), auth.getName())
                .claim(Constants.AUTHORITIES.getValue(), populateAuthorities(auth.getAuthorities()))
                .issuedAt(new Date())
                .expiration(new Date(new Date().getTime()+TOKEN_VALIDITY))
                .signWith(secretKey, Jwts.SIG.HS256)
                .compact();
    }
    private   String populateAuthorities(Collection <? extends GrantedAuthority> collection){
        Set<String> authoritesSet= new HashSet<>();
        for(GrantedAuthority authority:collection){
            authoritesSet.add(authority.getAuthority());
        }
        return String.join(",",authoritesSet);
    }
}
