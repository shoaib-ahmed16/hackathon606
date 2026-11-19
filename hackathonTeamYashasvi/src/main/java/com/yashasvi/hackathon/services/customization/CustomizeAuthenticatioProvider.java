package com.yashasvi.hackathon.services.customization;

import com.yashasvi.hackathon.domain.UsersDetails;
import com.yashasvi.hackathon.repository.UsersDetailsRepository;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.authentication.AuthenticationProvider;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.AuthenticationException;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.util.ArrayList;
import java.util.List;


//@Component
public class CustomizeAuthenticatioProvider implements AuthenticationProvider {

    @Autowired
    private UsersDetailsRepository userRepository;

    @Autowired
    private PasswordEncoder passwordEncoder;

    @Override
    public Authentication authenticate(Authentication auth) throws AuthenticationException {
        System.out.println("Customize Authentication Provider is using..");
        String username = auth.getName();
        String password =auth.getCredentials().toString();

        UsersDetails martUser= userRepository.findByEmail(username)
                .orElseThrow(()->{
                    throw new BadCredentialsException("No user registered with this details");
                });
        if(!passwordEncoder.matches(password,martUser.getPassword())){
            throw new BadCredentialsException("No user registered with this details");
        }
        List<GrantedAuthority> authorities = new ArrayList<>();
//        authorities.add(new SimpleGrantedAuthority(martUser.getRole()));
        return new UsernamePasswordAuthenticationToken(username,password,authorities);
    }

    @Override
    public boolean supports(Class<?> authentication) {
        return UsernamePasswordAuthenticationToken.class.isAssignableFrom(authentication);
    }
}
